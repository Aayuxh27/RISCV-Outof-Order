// ============================================================================
// reorder_buffer.sv
// ----------------------------------------------------------------------------
// In-order reorder buffer providing precise state.  Entries are allocated at
// dispatch (tail), completed out of order by the execution units / LSQ, and
// retired in order from the head once done.
//
// Each entry carries everything commit needs: the rename bookkeeping (arch dest,
// new and superseded physical registers), the result value (for the DPI golden
// check), the PC/instruction word, and the resolved control-flow outcome used to
// drive predictor training and misprediction recovery.
// ============================================================================
import riscv_ooo_pkg::*;

module reorder_buffer (
    input  logic        clk,
    input  logic        reset,
    input  logic        flush,

    // ----- Allocate (dispatch) ----------------------------------------------
    input  logic        alloc_valid,
    input  logic        alloc_done,        // ready to retire immediately (NOP/illegal)
    input  logic        alloc_writes_reg,
    input  logic [4:0]  alloc_arch_rd,
    input  logic [PREG_BITS-1:0] alloc_new_preg,
    input  logic [PREG_BITS-1:0] alloc_old_preg,
    input  uop_e        alloc_uop,
    input  logic        alloc_is_control,
    input  logic        alloc_is_cond,
    input  logic        alloc_exception,
    input  logic [31:0] alloc_pc,
    input  logic [31:0] alloc_inst,
    input  logic [GHR_BITS-1:0] alloc_pred_index,
    output logic [ROB_BITS-1:0] alloc_rob_idx,
    output logic        rob_full,

    // ----- Completion port A: execution units -------------------------------
    input  logic        cmpl_exec_valid,
    input  logic [ROB_BITS-1:0] cmpl_exec_idx,
    input  logic [31:0] cmpl_exec_value,
    input  logic        cmpl_exec_mispred,
    input  logic        cmpl_exec_taken,
    input  logic [31:0] cmpl_exec_target,

    // ----- Completion port B: load data -------------------------------------
    input  logic        cmpl_load_valid,
    input  logic [ROB_BITS-1:0] cmpl_load_idx,
    input  logic [31:0] cmpl_load_value,

    // ----- Commit (head) ----------------------------------------------------
    output logic        commit_valid,
    output logic        commit_writes_reg,
    output logic [4:0]  commit_arch_rd,
    output logic [PREG_BITS-1:0] commit_new_preg,
    output logic [PREG_BITS-1:0] commit_old_preg,
    output uop_e        commit_uop,
    output logic        commit_is_control,
    output logic        commit_is_cond,
    output logic        commit_mispred,
    output logic        commit_taken,
    output logic [31:0] commit_target,
    output logic [GHR_BITS-1:0] commit_pred_index,
    output logic [31:0] commit_pc,
    output logic [31:0] commit_inst,
    output logic [31:0] commit_value,
    output logic        commit_exception,

    output logic [ROB_BITS:0] rob_count
);

  logic        v_valid   [ROB_SIZE];
  logic        v_done    [ROB_SIZE];
  logic        v_wr      [ROB_SIZE];
  logic [4:0]  v_ard     [ROB_SIZE];
  logic [PREG_BITS-1:0] v_new [ROB_SIZE];
  logic [PREG_BITS-1:0] v_old [ROB_SIZE];
  uop_e        v_uop     [ROB_SIZE];
  logic        v_ctrl    [ROB_SIZE];
  logic        v_cond    [ROB_SIZE];
  logic        v_exc     [ROB_SIZE];
  logic [31:0] v_pc      [ROB_SIZE];
  logic [31:0] v_inst    [ROB_SIZE];
  logic [31:0] v_value   [ROB_SIZE];
  logic        v_mispred [ROB_SIZE];
  logic        v_taken   [ROB_SIZE];
  logic [31:0] v_target  [ROB_SIZE];
  logic [GHR_BITS-1:0] v_pidx [ROB_SIZE];

  logic [ROB_BITS-1:0] head, tail;

  assign alloc_rob_idx = tail;
  assign rob_full      = (rob_count == ROB_SIZE[ROB_BITS:0]);

  // ----- Commit view of the head entry --------------------------------------
  assign commit_valid      = v_valid[head] && v_done[head];
  assign commit_writes_reg = v_wr[head];
  assign commit_arch_rd    = v_ard[head];
  assign commit_new_preg   = v_new[head];
  assign commit_old_preg   = v_old[head];
  assign commit_uop        = v_uop[head];
  assign commit_is_control = v_ctrl[head];
  assign commit_is_cond    = v_cond[head];
  assign commit_mispred    = v_mispred[head];
  assign commit_taken      = v_taken[head];
  assign commit_target     = v_target[head];
  assign commit_pred_index = v_pidx[head];
  assign commit_pc         = v_pc[head];
  assign commit_inst       = v_inst[head];
  assign commit_value      = v_value[head];
  assign commit_exception  = v_exc[head];

  always_ff @(posedge clk) begin
    if (reset || flush) begin
      for (int i = 0; i < ROB_SIZE; i++) v_valid[i] <= 1'b0;
      head <= '0;
      tail <= '0;
      rob_count <= '0;
    end else begin
      // Completion writes (out of order).
      if (cmpl_exec_valid) begin
        v_done   [cmpl_exec_idx] <= 1'b1;
        v_value  [cmpl_exec_idx] <= cmpl_exec_value;
        v_mispred[cmpl_exec_idx] <= cmpl_exec_mispred;
        v_taken  [cmpl_exec_idx] <= cmpl_exec_taken;
        v_target [cmpl_exec_idx] <= cmpl_exec_target;
      end
      if (cmpl_load_valid) begin
        v_done [cmpl_load_idx] <= 1'b1;
        v_value[cmpl_load_idx] <= cmpl_load_value;
      end

      // Allocate at the tail.
      if (alloc_valid) begin
        v_valid  [tail] <= 1'b1;
        v_done   [tail] <= alloc_done;
        v_wr     [tail] <= alloc_writes_reg;
        v_ard    [tail] <= alloc_arch_rd;
        v_new    [tail] <= alloc_new_preg;
        v_old    [tail] <= alloc_old_preg;
        v_uop    [tail] <= alloc_uop;
        v_ctrl   [tail] <= alloc_is_control;
        v_cond   [tail] <= alloc_is_cond;
        v_exc    [tail] <= alloc_exception;
        v_pc     [tail] <= alloc_pc;
        v_inst   [tail] <= alloc_inst;
        v_pidx   [tail] <= alloc_pred_index;
        v_mispred[tail] <= 1'b0;
        v_taken  [tail] <= 1'b0;
        v_target [tail] <= 32'd0;
        tail            <= tail + 1'b1;
      end

      // Retire at the head.
      if (commit_valid) begin
        v_valid[head] <= 1'b0;
        head          <= head + 1'b1;
      end

      // Occupancy update (commit and alloc can both happen).
      rob_count <= rob_count
                 - {{ROB_BITS{1'b0}}, (commit_valid ? 1'b1 : 1'b0)}
                 + {{ROB_BITS{1'b0}}, (alloc_valid  ? 1'b1 : 1'b0)};
    end
  end

endmodule
