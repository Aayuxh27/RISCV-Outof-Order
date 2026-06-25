// ============================================================================
// reservation_station.sv
// ----------------------------------------------------------------------------
// Tomasulo-style reservation station for the single-issue core.
//
//   * allocate : one uop per cycle drops in with its operand ready bits seeded
//                from the dispatch-time regfile lookup.
//   * wakeup   : every cycle the common data bus tag is compared against both
//                source tags of every waiting entry; a match sets that operand
//                ready (one-cycle wakeup latency -- a dependent issues the cycle
//                after its producer broadcasts).
//   * select   : the oldest entry (smallest dispatch age) with both operands
//                ready is issued; its slot frees the same cycle.
//
// Out-of-order issue happens here: a younger entry whose operands are ready can
// issue ahead of an older one still waiting on a producer.
// ============================================================================
import riscv_ooo_pkg::*;

module reservation_station (
    input  logic        clk,
    input  logic        reset,
    input  logic        flush,

    // ----- Allocate (dispatch) ----------------------------------------------
    input  logic        alloc_valid,
    input  uop_e        alloc_uop,
    input  alu_e        alloc_alu_op,
    input  logic [2:0]  alloc_br_cond,
    input  logic [2:0]  alloc_mem_func,
    input  logic [PREG_BITS-1:0] alloc_prs1,
    input  logic [PREG_BITS-1:0] alloc_prs2,
    input  logic [PREG_BITS-1:0] alloc_prd,
    input  logic        alloc_uses_imm,
    input  logic [31:0] alloc_imm,
    input  logic [31:0] alloc_pc,
    input  logic        alloc_pred_taken,
    input  logic [31:0] alloc_pred_target,
    input  logic [GHR_BITS-1:0] alloc_pred_index,
    input  logic [ROB_BITS-1:0] alloc_rob_idx,
    input  logic [3:0]  alloc_lsq_idx,
    input  logic        alloc_ready1,
    input  logic        alloc_ready2,
    input  logic [31:0] alloc_age,

    output logic        full,
    output logic [5:0]  occupancy,

    // ----- Wakeup (common data bus) -----------------------------------------
    input  logic        cdb_valid,
    input  logic [PREG_BITS-1:0] cdb_tag,

    // ----- Issue (combinational select, consumed same cycle) ----------------
    output logic        issue_valid,
    output uop_e        issue_uop,
    output alu_e        issue_alu_op,
    output logic [2:0]  issue_br_cond,
    output logic [2:0]  issue_mem_func,
    output logic [PREG_BITS-1:0] issue_prs1,
    output logic [PREG_BITS-1:0] issue_prs2,
    output logic [PREG_BITS-1:0] issue_prd,
    output logic        issue_uses_imm,
    output logic [31:0] issue_imm,
    output logic [31:0] issue_pc,
    output logic        issue_pred_taken,
    output logic [31:0] issue_pred_target,
    output logic [GHR_BITS-1:0] issue_pred_index,
    output logic [ROB_BITS-1:0] issue_rob_idx,
    output logic [3:0]  issue_lsq_idx
);

  // ----- Entry storage ------------------------------------------------------
  logic        valid    [RS_SIZE];
  logic        ready1   [RS_SIZE];
  logic        ready2   [RS_SIZE];
  uop_e        e_uop    [RS_SIZE];
  alu_e        e_alu    [RS_SIZE];
  logic [2:0]  e_brc    [RS_SIZE];
  logic [2:0]  e_memf   [RS_SIZE];
  logic [PREG_BITS-1:0] e_prs1 [RS_SIZE];
  logic [PREG_BITS-1:0] e_prs2 [RS_SIZE];
  logic [PREG_BITS-1:0] e_prd  [RS_SIZE];
  logic        e_uimm   [RS_SIZE];
  logic [31:0] e_imm    [RS_SIZE];
  logic [31:0] e_pc     [RS_SIZE];
  logic        e_ptak   [RS_SIZE];
  logic [31:0] e_ptgt   [RS_SIZE];
  logic [GHR_BITS-1:0] e_pidx [RS_SIZE];
  logic [ROB_BITS-1:0] e_rob  [RS_SIZE];
  logic [3:0]  e_lsq    [RS_SIZE];
  logic [31:0] e_age    [RS_SIZE];


  // ----- Free-slot pick for allocation --------------------------------------
  logic                free_found;
  logic [RS_BITS-1:0]  free_idx;
  always_comb begin
    free_found = 1'b0;
    free_idx   = '0;
    for (int i = 0; i < RS_SIZE; i++)
      if (!valid[i] && !free_found) begin
        free_found = 1'b1;
        free_idx   = i[RS_BITS-1:0];
      end
  end
  assign full = !free_found;

  always_comb begin
    occupancy = '0;
    for (int i = 0; i < RS_SIZE; i++) occupancy = occupancy + {5'd0, valid[i]};
  end

  // ----- Oldest-ready select ------------------------------------------------
  logic               sel_found;
  logic [RS_BITS-1:0] sel_idx;
  always_comb begin
    sel_found = 1'b0;
    sel_idx   = '0;
    for (int i = 0; i < RS_SIZE; i++) begin
      if (valid[i] && ready1[i] && ready2[i]) begin
        if (!sel_found || (e_age[i] < e_age[sel_idx])) begin
          sel_found = 1'b1;
          sel_idx   = i[RS_BITS-1:0];
        end
      end
    end
  end

  assign issue_valid       = sel_found;
  assign issue_uop         = e_uop[sel_idx];
  assign issue_alu_op      = e_alu[sel_idx];
  assign issue_br_cond     = e_brc[sel_idx];
  assign issue_mem_func    = e_memf[sel_idx];
  assign issue_prs1        = e_prs1[sel_idx];
  assign issue_prs2        = e_prs2[sel_idx];
  assign issue_prd         = e_prd[sel_idx];
  assign issue_uses_imm    = e_uimm[sel_idx];
  assign issue_imm         = e_imm[sel_idx];
  assign issue_pc          = e_pc[sel_idx];
  assign issue_pred_taken  = e_ptak[sel_idx];
  assign issue_pred_target = e_ptgt[sel_idx];
  assign issue_pred_index  = e_pidx[sel_idx];
  assign issue_rob_idx     = e_rob[sel_idx];
  assign issue_lsq_idx     = e_lsq[sel_idx];

  // ----- Sequential update --------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset || flush) begin
      for (int i = 0; i < RS_SIZE; i++) valid[i] <= 1'b0;
    end else begin
      // Wakeup: set ready bits on a tag match.
      if (cdb_valid) begin
        for (int i = 0; i < RS_SIZE; i++) begin
          if (valid[i] && (e_prs1[i] == cdb_tag)) ready1[i] <= 1'b1;
          if (valid[i] && (e_prs2[i] == cdb_tag)) ready2[i] <= 1'b1;
        end
      end

      // Issue: free the selected slot.
      if (sel_found) valid[sel_idx] <= 1'b0;

      // Allocate: drop the new uop in (cannot collide with the freed slot only
      // if the freed slot is the chosen free slot -- the free-slot search runs
      // over the pre-issue valid bits, so use a separate write last to win).
      if (alloc_valid && free_found) begin
        valid [free_idx] <= 1'b1;
        ready1[free_idx] <= alloc_ready1 || (cdb_valid && (alloc_prs1 == cdb_tag));
        ready2[free_idx] <= alloc_ready2 || (cdb_valid && (alloc_prs2 == cdb_tag));
        e_uop [free_idx] <= alloc_uop;
        e_alu [free_idx] <= alloc_alu_op;
        e_brc [free_idx] <= alloc_br_cond;
        e_memf[free_idx] <= alloc_mem_func;
        e_prs1[free_idx] <= alloc_prs1;
        e_prs2[free_idx] <= alloc_prs2;
        e_prd [free_idx] <= alloc_prd;
        e_uimm[free_idx] <= alloc_uses_imm;
        e_imm [free_idx] <= alloc_imm;
        e_pc  [free_idx] <= alloc_pc;
        e_ptak[free_idx] <= alloc_pred_taken;
        e_ptgt[free_idx] <= alloc_pred_target;
        e_pidx[free_idx] <= alloc_pred_index;
        e_rob [free_idx] <= alloc_rob_idx;
        e_lsq [free_idx] <= alloc_lsq_idx;
        e_age [free_idx] <= alloc_age;
      end
    end
  end

endmodule
