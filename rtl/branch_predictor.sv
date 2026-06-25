// ============================================================================
// branch_predictor.sv
// ----------------------------------------------------------------------------
// gshare conditional predictor + Branch Target Buffer.
//
//   * Global History Register (GHR): two copies are kept.
//       - ghr_spec : updated speculatively at fetch (shift in the predicted
//                    direction of every conditional branch we predict).
//       - ghr_arch : updated in program order at commit (shift in the *actual*
//                    direction).  On a misprediction flush the speculative copy
//                    is restored from the architectural copy, so wrong-path
//                    history is never permanently absorbed.
//   * Pattern History Table (PHT): 2^GHR_BITS 2-bit saturating counters indexed
//     by  (pc>>2) XOR ghr  -- the gshare hash.
//   * BTB: direct-mapped, stores {valid,tag,target,is_cond} so fetch knows both
//     that a PC is a control instruction and where it goes.
//
// Prediction is combinational off the fetch PC.  The exact gshare index used is
// exported as `pred_index` and carried with the instruction down to commit, so
// the *same* PHT entry that produced a prediction is the one trained later --
// independent of how the GHR has since moved.
// ============================================================================
import riscv_ooo_pkg::*;

module branch_predictor (
    input  logic        clk,
    input  logic        reset,

    // ----- Predict (combinational, at fetch) --------------------------------
    input  logic [31:0] pc,
    input  logic        fetch_fire,        // a valid instruction is accepted
    output logic        predicted_taken,
    output logic [31:0] predicted_target,
    output logic [GHR_BITS-1:0] pred_index, // gshare index this prediction used

    // ----- Update (at commit, in program order) -----------------------------
    input  logic        upd_valid,
    input  logic        upd_is_control,     // any branch/jal/jalr
    input  logic        upd_is_cond,        // conditional branch only
    input  logic        upd_taken,          // resolved direction
    input  logic [31:0] upd_pc,
    input  logic [31:0] upd_target,
    input  logic [GHR_BITS-1:0] upd_index,

    // ----- Recovery ---------------------------------------------------------
    input  logic        flush               // restore speculative GHR
);

  // ----- Tables -------------------------------------------------------------
  logic [1:0]  pht [PHT_ENTRIES];
  logic        btb_valid  [BTB_ENTRIES];
  logic [31-BTB_IDX_BITS-2:0] btb_tag [BTB_ENTRIES]; // upper PC bits
  logic [31:0] btb_target [BTB_ENTRIES];
  logic        btb_cond   [BTB_ENTRIES];

  logic [GHR_BITS-1:0] ghr_spec;
  logic [GHR_BITS-1:0] ghr_arch;

  // ----- Prediction (combinational) -----------------------------------------
  wire [BTB_IDX_BITS-1:0] btb_idx     = pc[BTB_IDX_BITS+1:2];
  wire [31-BTB_IDX_BITS-2:0] pc_tag    = pc[31:BTB_IDX_BITS+2];
  wire btb_hit  = btb_valid[btb_idx] && (btb_tag[btb_idx] == pc_tag);
  wire btb_is_cond = btb_cond[btb_idx];

  assign pred_index = pc[GHR_BITS+1:2] ^ ghr_spec;
  wire   cond_taken = pht[pred_index][1];     // counter MSB

  always_comb begin
    if (btb_hit) begin
      // Unconditional control transfers are always taken; conditional ones
      // defer to the gshare counter.
      predicted_taken  = btb_is_cond ? cond_taken : 1'b1;
      predicted_target = btb_target[btb_idx];
    end else begin
      predicted_taken  = 1'b0;
      predicted_target = pc + 32'd4;
    end
  end

  // Did we just predict a conditional branch taken/not-taken this cycle?  Only
  // those shift the speculative history.
  wire spec_shift = fetch_fire && btb_hit && btb_is_cond;

  // Architectural GHR advances on every committed conditional branch.
  wire [GHR_BITS-1:0] ghr_arch_next =
      (upd_valid && upd_is_cond) ? {ghr_arch[GHR_BITS-2:0], upd_taken} : ghr_arch;

  // ----- Table initialisation (Verilator disallows NBA array init in loops) -
  initial begin
    for (int k = 0; k < PHT_ENTRIES; k++) pht[k] = 2'b01;     // weakly not-taken
    for (int k = 0; k < BTB_ENTRIES; k++) btb_valid[k] = 1'b0;
  end

  // ----- Sequential update --------------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      ghr_spec <= '0;
      ghr_arch <= '0;
    end else begin
      ghr_arch <= ghr_arch_next;

      // Speculative GHR: flush restore wins over a same-cycle fetch shift.
      if (flush)            ghr_spec <= ghr_arch_next;
      else if (spec_shift)  ghr_spec <= {ghr_spec[GHR_BITS-2:0], predicted_taken};

      // Train PHT on committed conditional branches (exact predicting entry).
      if (upd_valid && upd_is_cond)
        pht[upd_index] <= upd_taken ? ctr_inc(pht[upd_index]) : ctr_dec(pht[upd_index]);

      // Install/refresh BTB for any committed control instruction so its target
      // (and conditional-ness) is known next time it is fetched.
      if (upd_valid && upd_is_control) begin
        btb_valid [upd_pc[BTB_IDX_BITS+1:2]] <= 1'b1;
        btb_tag   [upd_pc[BTB_IDX_BITS+1:2]] <= upd_pc[31:BTB_IDX_BITS+2];
        btb_target[upd_pc[BTB_IDX_BITS+1:2]] <= upd_target;
        btb_cond  [upd_pc[BTB_IDX_BITS+1:2]] <= upd_is_cond;
      end
    end
  end

endmodule
