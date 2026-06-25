// ============================================================================
// ooo_core.sv
// ----------------------------------------------------------------------------
// Top-level single-issue out-of-order RV32I core.  Ties the front-end
// (fetch / predict / decode / rename) to the Tomasulo back-end (RS / execute /
// LSQ / ROB) and the in-order commit stage.
//
// Recovery model: squash-at-retire.  A mispredicted control instruction is
// marked in its ROB entry when it executes, but the flush is taken only when it
// reaches the head and commits.  At that instant the architectural state is by
// construction exact, so recovery is a single-cycle full squash of every
// younger in-flight structure plus a fetch redirect -- no per-branch
// checkpoints.
//
// Verification: at every retirement the committed PC / instruction / destination
// register / value are handed to the C++ golden model through DPI-C, which
// re-executes the same instruction and flags any architectural divergence.
// ============================================================================
import riscv_ooo_pkg::*;

module ooo_core (
    input  logic        clk,
    input  logic        reset,

    // ----- Status to the C++ harness ----------------------------------------
    output logic        halt,
    output logic [2:0]  halt_code,    // 1=done(j .) 2=trap 3=dpi-mismatch

    // ----- Performance counters (read by the harness for CSV export) --------
    output logic [63:0] stat_cycles,
    output logic [63:0] stat_committed,
    output logic [31:0] stat_bp_total,
    output logic [31:0] stat_bp_mispred,
    output logic [63:0] stat_rob_occ_sum,
    output logic [63:0] stat_rs_occ_sum,
    output logic [63:0] stat_lq_occ_sum,
    output logic [63:0] stat_sq_occ_sum
);

  // ----- DPI golden-model commit check --------------------------------------
  import "DPI-C" function int gm_commit(
      input int pc,
      input int inst,
      input int rd,          // -1 if the instruction writes no register
      input int value,
      input int writes_reg);

  // ==========================================================================
  // Recovery / commit signals (declared early; many blocks consume them)
  // ==========================================================================
  logic        flush;
  logic [31:0] redirect_pc;

  // ==========================================================================
  // FETCH + PREDICT
  // ==========================================================================
  logic [31:0] pc, inst;
  logic        fetch_valid;
  logic        fe_stall;

  logic        predicted_taken;
  logic [31:0] predicted_target;
  logic [GHR_BITS-1:0] pred_index;

  logic        dispatch_fire;        // a uop is accepted into the back-end

  fetch_unit u_fetch (
      .clk(clk), .reset(reset),
      .stall(fe_stall),
      .redirect_valid(flush), .redirect_pc(redirect_pc),
      .predicted_taken(predicted_taken), .predicted_target(predicted_target),
      .pc(pc), .inst(inst), .fetch_valid(fetch_valid));

  // ==========================================================================
  // DECODE
  // ==========================================================================
  logic        d_valid;
  uop_e        d_uop;
  alu_e        d_alu;
  logic [4:0]  d_rs1, d_rs2, d_rd;
  logic        d_writes_reg;
  logic [31:0] d_imm;
  logic        d_uses_imm;
  logic [2:0]  d_br_cond, d_mem_func;

  decode_unit u_decode (
      .inst(inst), .pc(pc),
      .valid(d_valid), .uop_type(d_uop), .alu_op(d_alu),
      .rs1(d_rs1), .rs2(d_rs2), .rd(d_rd), .writes_reg(d_writes_reg),
      .imm(d_imm), .uses_imm(d_uses_imm),
      .br_cond(d_br_cond), .mem_func(d_mem_func));

  wire d_is_load    = (d_uop == UOP_LOAD);
  wire d_is_store   = (d_uop == UOP_STORE);
  wire d_is_control = (d_uop == UOP_BRANCH) || (d_uop == UOP_JAL) || (d_uop == UOP_JALR);
  wire d_is_cond    = (d_uop == UOP_BRANCH);
  wire d_needs_rs   = (d_uop != UOP_NOP);
  wire d_exception  = !d_valid;

  branch_predictor u_bpred (
      .clk(clk), .reset(reset),
      .pc(pc), .fetch_fire(dispatch_fire),
      .predicted_taken(predicted_taken), .predicted_target(predicted_target),
      .pred_index(pred_index),
      .upd_valid(commit_valid), .upd_is_control(commit_is_control),
      .upd_is_cond(commit_is_cond), .upd_taken(commit_taken),
      .upd_pc(commit_pc), .upd_target(commit_target), .upd_index(commit_pred_index),
      .flush(flush));

  // ==========================================================================
  // RENAME
  // ==========================================================================
  logic [PREG_BITS-1:0] prs1, prs2, prd, old_prd;
  logic        rename_can_alloc;

  rename_unit u_rename (
      .clk(clk), .reset(reset),
      .rs1(d_rs1), .rs2(d_rs2), .rd(d_rd), .writes_reg(d_writes_reg),
      .dispatch_fire(dispatch_fire), .flush(flush),
      .prs1(prs1), .prs2(prs2), .prd(prd), .old_prd(old_prd),
      .can_alloc(rename_can_alloc),
      .commit_valid(commit_valid), .commit_writes_reg(commit_writes_reg),
      .commit_arch_rd(commit_arch_rd), .commit_new_preg(commit_new_preg),
      .commit_old_preg(commit_old_preg));

  // ==========================================================================
  // Common data bus + structural status (declared early)
  // ==========================================================================
  logic        cdb_valid;
  logic [PREG_BITS-1:0] cdb_tag;
  logic [31:0] cdb_value;

  logic        rob_full, rs_full, lq_full, sq_full;
  logic [3:0]  alloc_lq_idx, alloc_sq_idx;
  logic [ROB_BITS-1:0] alloc_rob_idx;

  // ----- Dispatch handshake -------------------------------------------------
  wire struct_ok = !rob_full
                 && (!d_needs_rs || !rs_full)
                 && (!d_is_load  || !lq_full)
                 && (!d_is_store || !sq_full)
                 && rename_can_alloc;
  assign dispatch_fire = fetch_valid && struct_ok && !flush;
  assign fe_stall      = fetch_valid && !struct_ok;

  // Monotonic dispatch sequence number (RS age + LSQ memory-order key).
  logic [31:0] seq;
  always_ff @(posedge clk) begin
    if (reset) seq <= 32'd0;
    else if (dispatch_fire) seq <= seq + 32'd1;
  end

  // ==========================================================================
  // PHYSICAL REGISTER FILE
  // ==========================================================================
  logic dready1, dready2;
  logic [31:0] issue_rs1_val, issue_rs2_val;

  // Issue wires declared early for the regfile issue-read ports.
  logic        issue_valid;
  uop_e        issue_uop;
  alu_e        issue_alu_op;
  logic [2:0]  issue_br_cond, issue_mem_func;
  logic [PREG_BITS-1:0] issue_prs1, issue_prs2, issue_prd;
  logic        issue_uses_imm;
  logic [31:0] issue_imm, issue_pc;
  logic        issue_pred_taken;
  logic [31:0] issue_pred_target;
  logic [GHR_BITS-1:0] issue_pred_index;
  logic [ROB_BITS-1:0] issue_rob_idx;
  logic [3:0]  issue_lsq_idx;

  physical_regfile u_prf (
      .clk(clk), .reset(reset),
      .alloc_valid(dispatch_fire && d_writes_reg), .alloc_prd(prd),
      .cdb_valid(cdb_valid), .cdb_tag(cdb_tag), .cdb_value(cdb_value),
      .drs1(prs1), .drs2(prs2), .dready1(dready1), .dready2(dready2),
      .irs1(issue_prs1), .irs2(issue_prs2),
      .ivalue1(issue_rs1_val), .ivalue2(issue_rs2_val));

  // ==========================================================================
  // RESERVATION STATION
  // ==========================================================================
  logic [5:0] rs_occupancy;

  reservation_station u_rs (
      .clk(clk), .reset(reset), .flush(flush),
      .alloc_valid(dispatch_fire && d_needs_rs),
      .alloc_uop(d_uop), .alloc_alu_op(d_alu),
      .alloc_br_cond(d_br_cond), .alloc_mem_func(d_mem_func),
      .alloc_prs1(prs1), .alloc_prs2(prs2), .alloc_prd(prd),
      .alloc_uses_imm(d_uses_imm), .alloc_imm(d_imm), .alloc_pc(pc),
      .alloc_pred_taken(predicted_taken), .alloc_pred_target(predicted_target),
      .alloc_pred_index(pred_index),
      .alloc_rob_idx(alloc_rob_idx), .alloc_lsq_idx(d_is_load ? alloc_lq_idx : alloc_sq_idx),
      .alloc_ready1(dready1), .alloc_ready2(dready2), .alloc_age(seq),
      .full(rs_full), .occupancy(rs_occupancy),
      .cdb_valid(cdb_valid), .cdb_tag(cdb_tag),
      .issue_valid(issue_valid), .issue_uop(issue_uop), .issue_alu_op(issue_alu_op),
      .issue_br_cond(issue_br_cond), .issue_mem_func(issue_mem_func),
      .issue_prs1(issue_prs1), .issue_prs2(issue_prs2), .issue_prd(issue_prd),
      .issue_uses_imm(issue_uses_imm), .issue_imm(issue_imm), .issue_pc(issue_pc),
      .issue_pred_taken(issue_pred_taken), .issue_pred_target(issue_pred_target),
      .issue_pred_index(issue_pred_index),
      .issue_rob_idx(issue_rob_idx), .issue_lsq_idx(issue_lsq_idx));

  // ==========================================================================
  // EXECUTE
  // ==========================================================================
  logic [31:0] ex_result, ex_agu_addr, ex_store_data, ex_target;
  logic        ex_produces_value, ex_is_control, ex_is_cond, ex_taken, ex_mispred;

  execute_unit u_exec (
      .uop(issue_uop), .alu_op(issue_alu_op), .br_cond(issue_br_cond),
      .uses_imm(issue_uses_imm), .imm(issue_imm), .pc(issue_pc),
      .rs1_val(issue_rs1_val), .rs2_val(issue_rs2_val),
      .pred_taken(issue_pred_taken), .pred_target(issue_pred_target),
      .result(ex_result), .produces_value(ex_produces_value),
      .agu_addr(ex_agu_addr), .store_data(ex_store_data),
      .is_control(ex_is_control), .is_cond(ex_is_cond),
      .actual_taken(ex_taken), .actual_target(ex_target),
      .mispredicted(ex_mispred));

  wire issue_is_load  = issue_valid && (issue_uop == UOP_LOAD);
  wire issue_is_store = issue_valid && (issue_uop == UOP_STORE);

  // ----- Common data bus arbitration: ALU result wins; load retries ---------
  wire alu_cdb_valid = issue_valid && ex_produces_value && (issue_prd != 0);

  logic        load_done_valid;
  logic [PREG_BITS-1:0] load_done_tag;
  logic [31:0] load_done_value;
  logic [ROB_BITS-1:0] load_done_rob_idx;
  wire         load_grant = load_done_valid; // already gated on !cdb_busy in LSQ

  assign cdb_valid = alu_cdb_valid || load_done_valid;
  assign cdb_tag   = alu_cdb_valid ? issue_prd  : load_done_tag;
  assign cdb_value = alu_cdb_valid ? ex_result  : load_done_value;

  // ==========================================================================
  // LOAD / STORE QUEUE + DATA MEMORY
  // ==========================================================================
  logic [LQ_BITS:0] lq_count;
  logic [SQ_BITS:0] sq_count;

  lsq u_lsq (
      .clk(clk), .reset(reset), .flush(flush),
      .alloc_load(dispatch_fire && d_is_load),
      .alloc_store(dispatch_fire && d_is_store),
      .alloc_seq(seq), .alloc_rob_idx(alloc_rob_idx), .alloc_prd(prd),
      .alloc_mem_func(d_mem_func),
      .alloc_lq_idx(alloc_lq_idx), .alloc_sq_idx(alloc_sq_idx),
      .lq_full(lq_full), .sq_full(sq_full),
      .agu_load_valid(issue_is_load), .agu_load_idx(issue_lsq_idx), .agu_load_addr(ex_agu_addr),
      .agu_store_valid(issue_is_store), .agu_store_idx(issue_lsq_idx),
      .agu_store_addr(ex_agu_addr), .agu_store_data(ex_store_data),
      .cdb_busy(alu_cdb_valid),
      .load_done_valid(load_done_valid), .load_done_tag(load_done_tag),
      .load_done_value(load_done_value), .load_done_rob_idx(load_done_rob_idx),
      .load_grant(load_grant),
      .commit_store(commit_valid && (commit_uop == UOP_STORE)),
      .commit_load(commit_valid && (commit_uop == UOP_LOAD)),
      .lq_count(lq_count), .sq_count(sq_count));

  // ==========================================================================
  // REORDER BUFFER
  // ==========================================================================
  logic        commit_valid, commit_writes_reg, commit_is_control, commit_is_cond;
  logic        commit_mispred, commit_taken, commit_exception;
  logic [4:0]  commit_arch_rd;
  logic [PREG_BITS-1:0] commit_new_preg, commit_old_preg;
  uop_e        commit_uop;
  logic [31:0] commit_target, commit_pc, commit_inst, commit_value;
  logic [GHR_BITS-1:0] commit_pred_index;
  logic [ROB_BITS:0] rob_count;

  reorder_buffer u_rob (
      .clk(clk), .reset(reset), .flush(flush),
      .alloc_valid(dispatch_fire),
      .alloc_done(d_uop == UOP_NOP),
      .alloc_writes_reg(d_writes_reg), .alloc_arch_rd(d_rd),
      .alloc_new_preg(prd), .alloc_old_preg(old_prd),
      .alloc_uop(d_uop), .alloc_is_control(d_is_control), .alloc_is_cond(d_is_cond),
      .alloc_exception(d_exception), .alloc_pc(pc), .alloc_inst(inst),
      .alloc_pred_index(pred_index),
      .alloc_rob_idx(alloc_rob_idx), .rob_full(rob_full),
      .cmpl_exec_valid(issue_valid && (issue_uop != UOP_LOAD)),
      .cmpl_exec_idx(issue_rob_idx), .cmpl_exec_value(ex_result),
      .cmpl_exec_mispred(ex_mispred), .cmpl_exec_taken(ex_taken),
      .cmpl_exec_target(ex_target),
      .cmpl_load_valid(load_grant), .cmpl_load_idx(load_done_rob_idx),
      .cmpl_load_value(load_done_value),
      .commit_valid(commit_valid), .commit_writes_reg(commit_writes_reg),
      .commit_arch_rd(commit_arch_rd), .commit_new_preg(commit_new_preg),
      .commit_old_preg(commit_old_preg), .commit_uop(commit_uop),
      .commit_is_control(commit_is_control), .commit_is_cond(commit_is_cond),
      .commit_mispred(commit_mispred), .commit_taken(commit_taken),
      .commit_target(commit_target), .commit_pred_index(commit_pred_index),
      .commit_pc(commit_pc), .commit_inst(commit_inst), .commit_value(commit_value),
      .commit_exception(commit_exception), .rob_count(rob_count));

  // ==========================================================================
  // COMMIT / RECOVERY / VERIFICATION / STATS
  // ==========================================================================
  assign flush       = commit_valid && commit_mispred;
  assign redirect_pc = commit_target;

  // Halt is sticky once asserted.
  always_ff @(posedge clk) begin
    if (reset) begin
      halt      <= 1'b0;
      halt_code <= 3'd0;
    end else if (!halt && commit_valid) begin
      if (commit_exception) begin
        halt      <= 1'b1;
        halt_code <= 3'd2;                    // illegal instruction trap
      end else begin
        // Co-simulate this retirement against the golden model.
        automatic int rc = gm_commit(commit_pc, commit_inst,
                                     commit_writes_reg ? {27'd0, commit_arch_rd} : -1,
                                     commit_value, commit_writes_reg ? 1 : 0);
        if (rc != 0) begin
          halt      <= 1'b1;
          halt_code <= 3'd3;                  // architectural mismatch
        end else if (commit_inst == HALT_INST) begin
          halt      <= 1'b1;
          halt_code <= 3'd1;                  // normal "j ." termination
        end
      end
    end
  end

  // ----- Performance counters ----------------------------------------------
  always_ff @(posedge clk) begin
    if (reset) begin
      stat_cycles      <= 64'd0;
      stat_committed   <= 64'd0;
      stat_bp_total    <= 32'd0;
      stat_bp_mispred  <= 32'd0;
      stat_rob_occ_sum <= 64'd0;
      stat_rs_occ_sum  <= 64'd0;
      stat_lq_occ_sum  <= 64'd0;
      stat_sq_occ_sum  <= 64'd0;
    end else if (!halt) begin
      stat_cycles      <= stat_cycles + 64'd1;
      stat_rob_occ_sum <= stat_rob_occ_sum + {{(64-($bits(rob_count))){1'b0}}, rob_count};
      stat_rs_occ_sum  <= stat_rs_occ_sum  + {58'd0, rs_occupancy};
      stat_lq_occ_sum  <= stat_lq_occ_sum  + {{(64-($bits(lq_count))){1'b0}}, lq_count};
      stat_sq_occ_sum  <= stat_sq_occ_sum  + {{(64-($bits(sq_count))){1'b0}}, sq_count};
      if (commit_valid) begin
        stat_committed <= stat_committed + 64'd1;
        if (commit_is_control) begin
          stat_bp_total <= stat_bp_total + 32'd1;
          if (commit_mispred) stat_bp_mispred <= stat_bp_mispred + 32'd1;
        end
      end
    end
  end

endmodule
