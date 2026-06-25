module dispatch_unit
(
//////////////////////////////////////////////////
// GLOBAL SQUASH
//////////////////////////////////////////////////
// Both sources discard whatever is currently in this cycle's
// dispatch: `stall` means the front end is blocked waiting on a
// rename checkpoint (rat.v), `misprediction_valid` means everything
// here is wrong-path, just discovered by a branch resolving this
// same cycle. Either way, nothing this cycle should reach the issue
// queue or ROB.

    input stall,
    input misprediction_valid,

//////////////////////////////////////////////////
// SLOT 0 (DECODE + RENAME + REGFILE READY)
//////////////////////////////////////////////////

    input valid0,
    input [3:0] opcode0,
    input [5:0] prs1_0,
    input [5:0] prs2_0,
    input [5:0] prd_0,
    input use_imm0,
    input [31:0] imm0,
    input ready1_0,
    input ready2_0,

    input is_branch0,
    input [2:0] branch_cond0,
    input [31:0] branch_target0,
    input [31:0] branch_pc0,
    input predicted_taken0,

    input is_load0,
    input is_store0,
    input [2:0] lsq_index0,

//////////////////////////////////////////////////
// SLOT 1
//////////////////////////////////////////////////

    input valid1,
    input [3:0] opcode1,
    input [5:0] prs1_1,
    input [5:0] prs2_1,
    input [5:0] prd_1,
    input use_imm1,
    input [31:0] imm1,
    input ready1_1,
    input ready2_1,

    input is_branch1,
    input [2:0] branch_cond1,
    input [31:0] branch_target1,
    input [31:0] branch_pc1,
    input predicted_taken1,

    input is_load1,
    input is_store1,
    input [2:0] lsq_index1,

//////////////////////////////////////////////////
// ISSUE QUEUE OUTPUT (BOTH SLOTS)
//////////////////////////////////////////////////

    output iq_valid0,
    output [3:0] iq_opcode0,
    output [5:0] iq_prs1_0,
    output [5:0] iq_prs2_0,
    output [5:0] iq_pd0,
    output iq_use_imm0,
    output [31:0] iq_imm0,
    output iq_ready1_0,
    output iq_ready2_0,
    output iq_is_branch0,
    output [2:0] iq_branch_cond0,
    output [31:0] iq_branch_target0,
    output [31:0] iq_branch_pc0,
    output iq_predicted_taken0,
    output iq_is_mem_op0,
    output [2:0] iq_lsq_index0,

    output iq_valid1,
    output [3:0] iq_opcode1,
    output [5:0] iq_prs1_1,
    output [5:0] iq_prs2_1,
    output [5:0] iq_pd1,
    output iq_use_imm1,
    output [31:0] iq_imm1,
    output iq_ready1_1,
    output iq_ready2_1,
    output iq_is_branch1,
    output [2:0] iq_branch_cond1,
    output [31:0] iq_branch_target1,
    output [31:0] iq_branch_pc1,
    output iq_predicted_taken1,
    output iq_is_mem_op1,
    output [2:0] iq_lsq_index1,

//////////////////////////////////////////////////
// ROB ALLOCATION
//////////////////////////////////////////////////

    output rob_dispatch0,
    output rob_dispatch1,
    output rob_is_store0,
    output rob_is_store1,
    output [2:0] rob_lsq_index0,
    output [2:0] rob_lsq_index1
);

//////////////////////////////////////////////////
// DISPATCH LOGIC (PURELY COMBINATIONAL)
//////////////////////////////////////////////////
// An instruction's destination register used to be its only possible
// architectural effect, so prd==0 (destination x0) meant "nothing left
// to do, drop it." Branches and stores break that assumption -- neither
// has a destination at all (B-type and S-type have no rd field), but
// both have a real effect: a branch updates the predictor and retires
// through the ROB, a store writes memory at commit. The filter below
// keeps anything with a real destination, OR that is a branch or
// store, and then squashes everything if this cycle turned out to be
// wrong-path or blocked on a checkpoint.

wire squash = stall || misprediction_valid;

assign iq_valid0 = valid0 && (prd_0 != 6'd0 || is_branch0 || is_store0) && !squash;
assign iq_valid1 = valid1 && (prd_1 != 6'd0 || is_branch1 || is_store1) && !squash;

assign iq_opcode0  = opcode0;
assign iq_prs1_0   = prs1_0;
assign iq_prs2_0   = prs2_0;
assign iq_pd0      = prd_0;
assign iq_use_imm0 = use_imm0;
assign iq_imm0     = imm0;
assign iq_ready1_0 = ready1_0;
// A store's rs2 is real data, not an ALU operand standing in for an
// immediate -- the use_imm shortcut below only holds when rs2 was
// forced to the always-ready x0/p0 tag (ALU-immediate ops, loads),
// which decode_unit.v does NOT do for stores.
assign iq_ready2_0 = is_store0 ? ready2_0 : (use_imm0 || ready2_0);

assign iq_is_branch0      = is_branch0;
assign iq_branch_cond0    = branch_cond0;
assign iq_branch_target0  = branch_target0;
assign iq_branch_pc0      = branch_pc0;
assign iq_predicted_taken0 = predicted_taken0;
assign iq_is_mem_op0      = is_load0 || is_store0;
assign iq_lsq_index0      = lsq_index0;

assign iq_opcode1  = opcode1;
assign iq_prs1_1   = prs1_1;
assign iq_prs2_1   = prs2_1;
assign iq_pd1      = prd_1;
assign iq_use_imm1 = use_imm1;
assign iq_imm1     = imm1;
assign iq_ready1_1 = ready1_1;
assign iq_ready2_1 = is_store1 ? ready2_1 : (use_imm1 || ready2_1);

assign iq_is_branch1      = is_branch1;
assign iq_branch_cond1    = branch_cond1;
assign iq_branch_target1  = branch_target1;
assign iq_branch_pc1      = branch_pc1;
assign iq_predicted_taken1 = predicted_taken1;
assign iq_is_mem_op1      = is_load1 || is_store1;
assign iq_lsq_index1      = lsq_index1;

assign rob_dispatch0 = iq_valid0;
assign rob_dispatch1 = iq_valid1;

assign rob_is_store0  = is_store0;
assign rob_is_store1  = is_store1;
assign rob_lsq_index0 = lsq_index0;
assign rob_lsq_index1 = lsq_index1;

endmodule
