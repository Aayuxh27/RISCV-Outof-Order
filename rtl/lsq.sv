// ============================================================================
// lsq.sv
// ----------------------------------------------------------------------------
// Load/Store Queue + data memory for the single-issue core.
//
// Both queues are in-order FIFOs allocated at dispatch (so FIFO order == program
// order) and freed at commit.  Each entry carries a monotonic dispatch sequence
// number used for age comparison between loads and stores.
//
// Stores:
//   * address+data computed at issue (AGU); the store then waits in the SQ.
//   * memory is written ONLY at commit, in order -> architectural memory is
//     always exact and wrong-path stores never touch it.
//
// Loads (conservative disambiguation, executed out of order in "phase B"):
//   A load may complete only when every older store either (a) has a known
//   address that does not overlap it, or (b) exactly matches it with ready data
//   (forward).  Any older store with an unknown address, a partial overlap, or a
//   matching address whose data is not yet ready blocks the load until that
//   store resolves/commits.  This gives correct store-to-load forwarding and
//   memory ordering without needing speculative load replay.
//
// Data memory is a flat word array sharing the program image (loaded from the
// same +MEM=<file> as instruction memory), with byte/half read-modify-write for
// sub-word stores.
// ============================================================================
import riscv_ooo_pkg::*;

module lsq (
    input  logic        clk,
    input  logic        reset,
    input  logic        flush,

    // ----- Allocate (dispatch) ----------------------------------------------
    input  logic        alloc_load,
    input  logic        alloc_store,
    input  logic [31:0] alloc_seq,
    input  logic [ROB_BITS-1:0] alloc_rob_idx,
    input  logic [PREG_BITS-1:0] alloc_prd,
    input  logic [2:0]  alloc_mem_func,
    output logic [3:0]  alloc_lq_idx,
    output logic [3:0]  alloc_sq_idx,
    output logic        lq_full,
    output logic        sq_full,

    // ----- AGU (issue) ------------------------------------------------------
    input  logic        agu_load_valid,
    input  logic [3:0]  agu_load_idx,
    input  logic [31:0] agu_load_addr,
    input  logic        agu_store_valid,
    input  logic [3:0]  agu_store_idx,
    input  logic [31:0] agu_store_addr,
    input  logic [31:0] agu_store_data,

    // ----- Load completion (phase B, shares the CDB) ------------------------
    input  logic        cdb_busy,           // ALU drove the CDB this cycle
    output logic        load_done_valid,
    output logic [PREG_BITS-1:0] load_done_tag,
    output logic [31:0] load_done_value,
    output logic [ROB_BITS-1:0]  load_done_rob_idx,
    input  logic        load_grant,         // top accepted the load onto the CDB

    // ----- Commit -----------------------------------------------------------
    input  logic        commit_store,       // pop SQ head, write memory
    input  logic        commit_load,        // pop LQ head

    // ----- Occupancy (stats) ------------------------------------------------
    output logic [LQ_BITS:0] lq_count,
    output logic [SQ_BITS:0] sq_count
);

  localparam int DMEM_WORDS = MEM_BYTES / 4;
  logic [31:0] dmem [DMEM_WORDS];

  string memfile;
  initial begin
    for (int k = 0; k < DMEM_WORDS; k++) dmem[k] = 32'd0;
    if ($value$plusargs("MEM=%s", memfile))
      $readmemh(memfile, dmem);
  end

  // ----- Queue storage ------------------------------------------------------
  logic        lq_valid     [LQ_SIZE];
  logic        lq_addr_rdy  [LQ_SIZE];
  logic        lq_done      [LQ_SIZE];
  logic [31:0] lq_addr      [LQ_SIZE];
  logic [2:0]  lq_func      [LQ_SIZE];
  logic [PREG_BITS-1:0] lq_prd [LQ_SIZE];
  logic [ROB_BITS-1:0]  lq_rob [LQ_SIZE];
  logic [31:0] lq_seq       [LQ_SIZE];

  logic        sq_valid     [SQ_SIZE];
  logic        sq_addr_rdy  [SQ_SIZE];
  logic        sq_data_rdy  [SQ_SIZE];
  logic [31:0] sq_addr      [SQ_SIZE];
  logic [31:0] sq_data      [SQ_SIZE];
  logic [2:0]  sq_func      [SQ_SIZE];
  logic [31:0] sq_seq       [SQ_SIZE];

  logic [LQ_BITS-1:0] lq_head, lq_tail;
  logic [SQ_BITS-1:0] sq_head, sq_tail;

  assign alloc_lq_idx = {1'b0, lq_tail};
  assign alloc_sq_idx = {1'b0, sq_tail};
  assign lq_full = (lq_count == LQ_SIZE[LQ_BITS:0]);
  assign sq_full = (sq_count == SQ_SIZE[SQ_BITS:0]);

  // ----- Helpers ------------------------------------------------------------
  function automatic logic [2:0] size_bytes(input logic [2:0] f);
    case (f)
      MEM_B, MEM_BU: size_bytes = 3'd1;
      MEM_H, MEM_HU: size_bytes = 3'd2;
      default:       size_bytes = 3'd4;
    endcase
  endfunction

  // Format a loaded word (already at byte offset `off`) per the load funct3.
  function automatic logic [31:0] fmt_load(input logic [2:0] f, input logic [31:0] word, input logic [1:0] off);
    logic [31:0] s;
    s = word >> ({3'd0, off} * 8);
    case (f)
      MEM_B : fmt_load = {{24{s[7]}},  s[7:0]};
      MEM_H : fmt_load = {{16{s[15]}}, s[15:0]};
      MEM_BU: fmt_load = {24'd0,       s[7:0]};
      MEM_HU: fmt_load = {16'd0,       s[15:0]};
      default: fmt_load = s;
    endcase
  endfunction

  // ----- Phase-B load completion search -------------------------------------
  logic               cand_can  [LQ_SIZE];
  logic [31:0]        cand_val  [LQ_SIZE];

  always_comb begin
    for (int i = 0; i < LQ_SIZE; i++) begin
      automatic logic        blocked   = 1'b0;
      automatic logic        fwd_found = 1'b0;
      automatic logic [31:0] fwd_seq   = 32'd0;
      automatic logic [31:0] fwd_data  = 32'd0;
      automatic logic [31:0] la        = lq_addr[i];
      automatic logic [2:0]  lsz       = size_bytes(lq_func[i]);
      cand_can[i] = 1'b0;
      cand_val[i] = 32'd0;
      if (lq_valid[i] && lq_addr_rdy[i] && !lq_done[i]) begin
        for (int j = 0; j < SQ_SIZE; j++) begin
          // Expressions are inlined (no per-iteration temporaries) so the
          // combinational block has no partially-assigned signals to latch.
          if (sq_valid[j] && (sq_seq[j] < lq_seq[i])) begin // older store
            if (!sq_addr_rdy[j]) begin
              blocked = 1'b1;                                // unknown alias
            end else if ((sq_addr[j] < (la + {29'd0, lsz})) &&
                         (la < (sq_addr[j] + {29'd0, size_bytes(sq_func[j])}))) begin // overlap
              if ((sq_addr[j] == la) && (size_bytes(sq_func[j]) == lsz) && sq_data_rdy[j]) begin
                // exact match with ready data => youngest wins the forward
                if (!fwd_found || (sq_seq[j] > fwd_seq)) begin
                  fwd_found = 1'b1;
                  fwd_seq   = sq_seq[j];
                  fwd_data  = sq_data[j];
                end
              end else begin
                blocked = 1'b1;                              // partial / not-ready
              end
            end
          end
        end
        if (!blocked) begin
          cand_can[i] = 1'b1;
          cand_val[i] = fwd_found ? fmt_load(lq_func[i], fwd_data, 2'd0)
                                  : fmt_load(lq_func[i], dmem[la[MEM_ADDR_BITS-1:2]], la[1:0]);
        end
      end
    end
  end

  // Pick the oldest completable load.
  logic               sel_found;
  logic [LQ_BITS-1:0] sel_idx;
  always_comb begin
    sel_found = 1'b0;
    sel_idx   = '0;
    for (int i = 0; i < LQ_SIZE; i++)
      if (cand_can[i]) begin
        if (!sel_found || (lq_seq[i] < lq_seq[sel_idx])) begin
          sel_found = 1'b1;
          sel_idx   = i[LQ_BITS-1:0];
        end
      end
  end

  assign load_done_valid   = sel_found && !cdb_busy;
  assign load_done_tag     = lq_prd[sel_idx];
  assign load_done_value   = cand_val[sel_idx];
  assign load_done_rob_idx = lq_rob[sel_idx];

  // ----- Sequential state ---------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset || flush) begin
      for (int i = 0; i < LQ_SIZE; i++) lq_valid[i] <= 1'b0;
      for (int i = 0; i < SQ_SIZE; i++) sq_valid[i] <= 1'b0;
      lq_head <= '0; lq_tail <= '0; lq_count <= '0;
      sq_head <= '0; sq_tail <= '0; sq_count <= '0;
    end else begin
      // -------- Allocate --------
      if (alloc_load) begin
        lq_valid   [lq_tail] <= 1'b1;
        lq_addr_rdy[lq_tail] <= 1'b0;
        lq_done    [lq_tail] <= 1'b0;
        lq_func    [lq_tail] <= alloc_mem_func;
        lq_prd     [lq_tail] <= alloc_prd;
        lq_rob     [lq_tail] <= alloc_rob_idx;
        lq_seq     [lq_tail] <= alloc_seq;
        lq_tail              <= lq_tail + 1'b1;
      end
      if (alloc_store) begin
        sq_valid   [sq_tail] <= 1'b1;
        sq_addr_rdy[sq_tail] <= 1'b0;
        sq_data_rdy[sq_tail] <= 1'b0;
        sq_func    [sq_tail] <= alloc_mem_func;
        sq_seq     [sq_tail] <= alloc_seq;
        sq_tail              <= sq_tail + 1'b1;
      end

      // -------- AGU writes --------
      if (agu_load_valid) begin
        lq_addr   [agu_load_idx[LQ_BITS-1:0]] <= agu_load_addr;
        lq_addr_rdy[agu_load_idx[LQ_BITS-1:0]] <= 1'b1;
      end
      if (agu_store_valid) begin
        sq_addr    [agu_store_idx[SQ_BITS-1:0]] <= agu_store_addr;
        sq_data    [agu_store_idx[SQ_BITS-1:0]] <= agu_store_data;
        sq_addr_rdy[agu_store_idx[SQ_BITS-1:0]] <= 1'b1;
        sq_data_rdy[agu_store_idx[SQ_BITS-1:0]] <= 1'b1;
      end

      // -------- Load completion (mark done when granted onto CDB) --------
      if (load_grant && sel_found)
        lq_done[sel_idx] <= 1'b1;

      // -------- Commit: store writes memory, queues pop in order --------
      if (commit_store) begin
        // read-modify-write the addressed word with the store's bytes
        if (size_bytes(sq_func[sq_head]) == 3'd1)
          dmem[sq_addr[sq_head][MEM_ADDR_BITS-1:2]][ {sq_addr[sq_head][1:0], 3'd0} +: 8 ]
              <= sq_data[sq_head][7:0];
        else if (size_bytes(sq_func[sq_head]) == 3'd2)
          dmem[sq_addr[sq_head][MEM_ADDR_BITS-1:2]][ {sq_addr[sq_head][1], 4'd0} +: 16 ]
              <= sq_data[sq_head][15:0];
        else
          dmem[sq_addr[sq_head][MEM_ADDR_BITS-1:2]] <= sq_data[sq_head];

        sq_valid[sq_head] <= 1'b0;
        sq_head           <= sq_head + 1'b1;
        sq_count          <= sq_count - 1'b1 + {{SQ_BITS{1'b0}}, alloc_store};
      end else begin
        sq_count <= sq_count + {{SQ_BITS{1'b0}}, alloc_store};
      end

      if (commit_load) begin
        lq_valid[lq_head] <= 1'b0;
        lq_head           <= lq_head + 1'b1;
        lq_count          <= lq_count - 1'b1 + {{LQ_BITS{1'b0}}, alloc_load};
      end else begin
        lq_count <= lq_count + {{LQ_BITS{1'b0}}, alloc_load};
      end
    end
  end

endmodule
