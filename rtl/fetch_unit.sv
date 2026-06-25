// ============================================================================
// fetch_unit.sv
// ----------------------------------------------------------------------------
// Single-issue fetch: a program counter, a read-only instruction memory, and
// the redirect/stall logic that steers speculative fetch.
//
//   * next PC = redirect target          (on a commit-time misprediction flush)
//             = current PC               (when the back-end stalls the front-end)
//             = predicted next PC         (speculative path from the predictor)
//
// The instruction memory is loaded with the same hex image the C++ golden model
// uses (plusarg +MEM=<file>), so RTL fetch and the reference model always see an
// identical program.
// ============================================================================
import riscv_ooo_pkg::*;

module fetch_unit (
    input  logic        clk,
    input  logic        reset,

    input  logic        stall,            // back-end cannot accept a uop
    input  logic        redirect_valid,   // misprediction flush
    input  logic [31:0] redirect_pc,

    // Prediction for the *current* PC (combinational, from branch_predictor).
    input  logic        predicted_taken,
    input  logic [31:0] predicted_target,

    output logic [31:0] pc,
    output logic [31:0] inst,
    output logic        fetch_valid
);

  localparam int IMEM_WORDS = MEM_BYTES / 4;

  logic [31:0] imem [IMEM_WORDS];

  // Load the program image.  +MEM=<path> overrides the default location.
  string memfile;
  initial begin
    for (int k = 0; k < IMEM_WORDS; k++) imem[k] = 32'h0000_0013; // NOP (addi x0,x0,0)
    if ($value$plusargs("MEM=%s", memfile))
      $readmemh(memfile, imem);
  end

  // ----- Program counter ----------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset)
      pc <= RESET_PC;
    else if (redirect_valid)
      pc <= redirect_pc;
    else if (stall)
      pc <= pc;
    else
      pc <= predicted_taken ? predicted_target : (pc + 32'd4);
  end

  assign inst        = imem[pc[MEM_ADDR_BITS-1:2]];
  assign fetch_valid = !reset;

endmodule
