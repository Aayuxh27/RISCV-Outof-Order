// ============================================================================
// rename_unit.sv
// ----------------------------------------------------------------------------
// Register renaming for the single-issue core: speculative RAT, free list, and
// a committed (architectural) map used for recovery.
//
//   * rat[]      speculative arch -> phys map, updated at dispatch.
//   * arat[]     committed arch -> phys map, updated at commit (in order).
//   * free_bm    free-list bitmap; allocation takes the lowest free physical
//                register, commit returns the *previous* mapping of the
//                committed architectural register.
//
// Recovery is squash-at-retire: when a mispredicted branch reaches the head and
// commits, the architectural map is by construction exact, so the speculative
// state is simply reloaded from it -- rat <= arat and free_bm <= ~(in-use-by-
// arat).  No per-branch checkpoints are needed.  Eliminates WAR/WAW hazards by
// giving every writer a fresh physical register, and RAW hazards by tracking the
// producing physical register through the reservation station.
//
// Physical register p0 is permanently the home of architectural x0: it is in
// arat from reset, never freed, and always reads as zero in the regfile.
// ============================================================================
import riscv_ooo_pkg::*;

module rename_unit (
    input  logic        clk,
    input  logic        reset,

    // ----- From decode (current instruction) --------------------------------
    input  logic [4:0]  rs1,
    input  logic [4:0]  rs2,
    input  logic [4:0]  rd,
    input  logic        writes_reg,

    // ----- Handshake --------------------------------------------------------
    input  logic        dispatch_fire,    // this uop is renamed/dispatched now
    input  logic        flush,            // misprediction recovery

    // ----- Renamed sources / destination (combinational) --------------------
    output logic [PREG_BITS-1:0] prs1,
    output logic [PREG_BITS-1:0] prs2,
    output logic [PREG_BITS-1:0] prd,      // newly allocated physical dest
    output logic [PREG_BITS-1:0] old_prd,  // previous mapping of rd (freed later)
    output logic        can_alloc,         // a free reg exists (or none needed)

    // ----- From commit (in program order) -----------------------------------
    input  logic        commit_valid,
    input  logic        commit_writes_reg,
    input  logic [4:0]  commit_arch_rd,
    input  logic [PREG_BITS-1:0] commit_new_preg,
    input  logic [PREG_BITS-1:0] commit_old_preg
);

  logic [PREG_BITS-1:0] rat  [ARCH_REGS];
  logic [PREG_BITS-1:0] arat [ARCH_REGS];
  logic [PHYS_REGS-1:0] free_bm;      // 1 = available
  logic [PHYS_REGS-1:0] arat_busy;    // 1 = referenced by committed map


  // ----- Free-list allocation: lowest set bit -------------------------------
  logic                 found;
  logic [PREG_BITS-1:0] alloc_idx;
  always_comb begin
    found     = 1'b0;
    alloc_idx = '0;
    for (int i = 0; i < PHYS_REGS; i++)
      if (free_bm[i] && !found) begin
        found     = 1'b1;
        alloc_idx = i[PREG_BITS-1:0];
      end
  end

  assign can_alloc = !writes_reg || found;
  assign prd       = alloc_idx;
  assign old_prd   = rat[rd];
  assign prs1      = rat[rs1];
  assign prs2      = rat[rs2];

  // ----- Committed-map next state (applied every cycle) ---------------------
  logic [PREG_BITS-1:0] arat_next [ARCH_REGS];
  logic [PHYS_REGS-1:0] arat_busy_next;
  always_comb begin
    for (int i = 0; i < ARCH_REGS; i++) arat_next[i] = arat[i];
    arat_busy_next = arat_busy;
    if (commit_valid && commit_writes_reg) begin
      arat_next[commit_arch_rd]       = commit_new_preg;
      arat_busy_next[commit_new_preg] = 1'b1;
      arat_busy_next[commit_old_preg] = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      for (int i = 0; i < ARCH_REGS; i++) begin
        rat[i]  <= i[PREG_BITS-1:0];
        arat[i] <= i[PREG_BITS-1:0];
      end
      // p0..p31 are the boot mapping (busy); p32..p63 are free.
      for (int i = 0; i < PHYS_REGS; i++) begin
        free_bm[i]   <= (i >= ARCH_REGS);
        arat_busy[i] <= (i <  ARCH_REGS);
      end
    end else begin
      // Architectural map always advances with commit.
      for (int i = 0; i < ARCH_REGS; i++) arat[i] <= arat_next[i];
      arat_busy <= arat_busy_next;

      if (flush) begin
        // Reload speculative state from the (now exact) committed state.
        for (int i = 0; i < ARCH_REGS; i++) rat[i] <= arat_next[i];
        free_bm <= ~arat_busy_next;
      end else begin
        // Dispatch allocation.
        if (dispatch_fire && writes_reg) begin
          rat[rd]            <= alloc_idx;
          free_bm[alloc_idx] <= 1'b0;
        end
        // Commit reclamation of the superseded physical register.
        if (commit_valid && commit_writes_reg)
          free_bm[commit_old_preg] <= 1'b1;
      end
    end
  end

endmodule
