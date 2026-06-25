// ============================================================================
// physical_regfile.sv
// ----------------------------------------------------------------------------
// Unified physical register file (values live here; there is no separate
// architectural file).  Each physical register carries a value and a "ready"
// bit tracking whether its producer has broadcast yet.
//
// Three access groups:
//   * write      : the common data bus writes a value and sets ready.
//   * allocate   : a freshly renamed destination clears its ready bit.
//   * dispatch   : combinational ready lookup (with same-cycle CDB bypass) used
//                  to initialise a reservation-station entry's ready bits.
//   * issue      : combinational value read for the operands of the issued uop.
//
// Physical register p0 is hard-wired to zero / always ready (architectural x0).
// ============================================================================
import riscv_ooo_pkg::*;

module physical_regfile (
    input  logic        clk,
    input  logic        reset,

    // Allocate: clear ready for a newly renamed destination.
    input  logic                 alloc_valid,
    input  logic [PREG_BITS-1:0] alloc_prd,

    // Common data bus write.
    input  logic                 cdb_valid,
    input  logic [PREG_BITS-1:0] cdb_tag,
    input  logic [31:0]          cdb_value,

    // Dispatch-time ready lookup (with CDB bypass).
    input  logic [PREG_BITS-1:0] drs1,
    input  logic [PREG_BITS-1:0] drs2,
    output logic                 dready1,
    output logic                 dready2,

    // Issue-time value read.
    input  logic [PREG_BITS-1:0] irs1,
    input  logic [PREG_BITS-1:0] irs2,
    output logic [31:0]          ivalue1,
    output logic [31:0]          ivalue2
);

  logic [31:0] regfile [PHYS_REGS];
  logic        ready   [PHYS_REGS];

  always_ff @(posedge clk) begin
    if (reset) begin
      for (int i = 0; i < PHYS_REGS; i++) begin
        regfile[i] <= 32'd0;
        ready[i]   <= (i < ARCH_REGS);  // boot registers hold a defined 0
      end
    end else begin
      // Allocation clears readiness first; a real producer sets it later.
      if (alloc_valid && (alloc_prd != 0))
        ready[alloc_prd] <= 1'b0;
      // CDB write wins on the (impossible) tie and is the authoritative update.
      if (cdb_valid && (cdb_tag != 0)) begin
        regfile[cdb_tag] <= cdb_value;
        ready[cdb_tag]   <= 1'b1;
      end
      regfile[0] <= 32'd0;             // p0 stays zero
      ready[0]   <= 1'b1;
    end
  end

  // ----- Dispatch-time ready (x0 always ready, CDB same-cycle bypass) --------
  assign dready1 = (drs1 == 0) || ready[drs1] || (cdb_valid && (cdb_tag == drs1));
  assign dready2 = (drs2 == 0) || ready[drs2] || (cdb_valid && (cdb_tag == drs2));

  // ----- Issue-time values --------------------------------------------------
  assign ivalue1 = (irs1 == 0) ? 32'd0 : regfile[irs1];
  assign ivalue2 = (irs2 == 0) ? 32'd0 : regfile[irs2];

endmodule
