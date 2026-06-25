module ooo_top(
    input clk,
    input reset
);

//////////////////////////////////////////////////
// RECOVERY WIRES -- declared early; fetch_unit, dispatch_unit, rat,
// issue_queue and reorder_buffer all consume these
//////////////////////////////////////////////////

wire misprediction_valid;
wire [31:0] misprediction_pc;

wire final_redirect_valid;
wire [31:0] final_redirect_pc;

wire rat_stall;
wire ckpt_conflict;

//////////////////////////////////////////////////
// FETCH
//////////////////////////////////////////////////

wire [31:0] pc;
wire [31:0] inst0;
wire [31:0] inst1;

fetch_unit fetch_inst(
    .clk(clk),
    .reset(reset),

    .misprediction_valid(misprediction_valid),
    .misprediction_pc(misprediction_pc),

    .redirect_valid(final_redirect_valid),
    .redirect_pc(final_redirect_pc),

    .stall(rat_stall),

    .pc(pc),
    .inst0(inst0),
    .inst1(inst1)
);

//////////////////////////////////////////////////
// DECODE
//////////////////////////////////////////////////

wire valid0;
wire valid1_raw;

wire [3:0] opcode0;
wire [3:0] opcode1;

wire [4:0] rs1_0;
wire [4:0] rs2_0;
wire [4:0] rd_0;

wire [4:0] rs1_1;
wire [4:0] rs2_1;
wire [4:0] rd_1;

wire use_imm0;
wire [31:0] imm0;

wire use_imm1;
wire [31:0] imm1;

wire is_branch0;
wire [2:0] branch_cond0;
wire [31:0] branch_target0;
wire [31:0] branch_pc0;

wire is_branch1;
wire [2:0] branch_cond1;
wire [31:0] branch_target1;
wire [31:0] branch_pc1;

decode_unit decode_inst(
    .pc(pc),
    .inst0(inst0),
    .inst1(inst1),

    .valid0(valid0),
    .valid1(valid1_raw),

    .opcode0(opcode0),
    .opcode1(opcode1),

    .rs1_0(rs1_0),
    .rs2_0(rs2_0),
    .rd_0(rd_0),

    .rs1_1(rs1_1),
    .rs2_1(rs2_1),
    .rd_1(rd_1),

    .use_imm0(use_imm0),
    .imm0(imm0),

    .use_imm1(use_imm1),
    .imm1(imm1),

    .is_branch0(is_branch0),
    .branch_cond0(branch_cond0),
    .branch_target0(branch_target0),
    .branch_pc0(branch_pc0),

    .is_branch1(is_branch1),
    .branch_cond1(branch_cond1),
    .branch_target1(branch_target1),
    .branch_pc1(branch_pc1)
);

//////////////////////////////////////////////////
// BRANCH PREDICTOR
//////////////////////////////////////////////////

wire predicted_taken0;
wire predicted_taken1;

wire bp_redirect_valid;
wire [31:0] bp_redirect_pc;
wire bp_squash_slot1;

wire branch_resolved_valid;
wire branch_mispredicted;
wire [31:0] branch_correct_target;
wire [31:0] branch_update_pc;
wire branch_update_taken;

branch_predict_unit bp_inst(
    .clk(clk),
    .reset(reset),

    .pc(pc),

    .is_branch0(is_branch0),
    .branch_target0(branch_target0),

    .is_branch1(is_branch1),
    .branch_target1(branch_target1),

    .predicted_taken0(predicted_taken0),
    .predicted_taken1(predicted_taken1),

    .redirect_valid(bp_redirect_valid),
    .redirect_pc(bp_redirect_pc),
    .squash_slot1(bp_squash_slot1),

    .update_valid(branch_resolved_valid),
    .update_pc(branch_update_pc),
    .update_taken(branch_update_taken)
);

//////////////////////////////////////////////////
// SLOT 1 GATING + RECOVERY SIGNAL COMBINING
//////////////////////////////////////////////////
// valid1_bp: gated once by the predictor (a taken slot-0 branch makes
// slot 1 wrong-path) -- this is what rat.v sees, since it computes its
// own ckpt_conflict from it. valid1: gated a second time by that very
// ckpt_conflict output -- this is what everything past the RAT
// (dispatch_unit and onward) sees, so a slot 1 that lost the single
// checkpoint to slot 0 never gets renamed OR dispatched.

wire valid1_bp = valid1_raw && !bp_squash_slot1;
wire valid1    = valid1_bp && !ckpt_conflict;

assign misprediction_valid = branch_resolved_valid && branch_mispredicted;
wire   branch_correct_valid = branch_resolved_valid && !branch_mispredicted;

assign misprediction_pc = branch_correct_target;

assign final_redirect_valid = bp_redirect_valid || ckpt_conflict;
assign final_redirect_pc    = ckpt_conflict ? (pc + 32'd4) : bp_redirect_pc;

//////////////////////////////////////////////////
// RAT
//////////////////////////////////////////////////

wire [5:0] prs1_0;
wire [5:0] prs2_0;
wire [5:0] prs1_1;
wire [5:0] prs2_1;

wire [5:0] prd_0;
wire [5:0] prd_1;

rat rat_inst(
    .clk(clk),
    .reset(reset),

    .valid0(valid0),
    .valid1(valid1_bp),

    .rs1_0(rs1_0),
    .rs2_0(rs2_0),
    .rd_0(rd_0),

    .rs1_1(rs1_1),
    .rs2_1(rs2_1),
    .rd_1(rd_1),

    .is_branch0(is_branch0),
    .is_branch1(is_branch1),

    .misprediction_valid(misprediction_valid),
    .branch_correct_valid(branch_correct_valid),

    .prs1_0(prs1_0),
    .prs2_0(prs2_0),
    .prs1_1(prs1_1),
    .prs2_1(prs2_1),

    .prd_0(prd_0),
    .prd_1(prd_1),

    .stall(rat_stall),
    .ckpt_conflict(ckpt_conflict)
);

//////////////////////////////////////////////////
// EXECUTION (CDB) WIRES -- declared early since both the
// physical regfile and the issue queue snoop them
//////////////////////////////////////////////////

wire broadcast0_valid;
wire [5:0] broadcast0_tag;
wire [31:0] broadcast0_value;

wire broadcast1_valid;
wire [5:0] broadcast1_tag;
wire [31:0] broadcast1_value;

//////////////////////////////////////////////////
// SCHEDULER OUTPUT WIRES -- declared early; slot 0/1 issue-time
// source tags are needed by the physical regfile's issue-time
// read ports below
//////////////////////////////////////////////////

wire issue0_valid;
wire issue1_valid;

wire [3:0] issue0_opcode;
wire [3:0] issue1_opcode;

wire [5:0] issue0_prs1;
wire [5:0] issue0_prs2;
wire [5:0] issue1_prs1;
wire [5:0] issue1_prs2;

wire [5:0] issue0_pd;
wire [5:0] issue1_pd;

wire issue0_use_imm;
wire issue1_use_imm;

wire [31:0] issue0_imm;
wire [31:0] issue1_imm;

wire issue0_is_branch;
wire issue1_is_branch;

wire issue0_predicted_taken;
wire issue1_predicted_taken;

wire [2:0] issue0_branch_cond;
wire [2:0] issue1_branch_cond;

wire [31:0] issue0_branch_target;
wire [31:0] issue1_branch_target;

wire [31:0] issue0_branch_pc;
wire [31:0] issue1_branch_pc;

wire [2:0] issue0_index;
wire [2:0] issue1_index;

//////////////////////////////////////////////////
// PHYSICAL REGISTER FILE
//////////////////////////////////////////////////

wire ready1_0;
wire ready2_0;
wire ready1_1;
wire ready2_1;

wire [31:0] issue0_rs1_val;
wire [31:0] issue0_rs2_val;
wire [31:0] issue1_rs1_val;
wire [31:0] issue1_rs2_val;

physical_regfile regfile_inst(
    .clk(clk),
    .reset(reset),

    .prs1_0(prs1_0),
    .prs2_0(prs2_0),
    .ready1_0(ready1_0),
    .ready2_0(ready2_0),

    .prs1_1(prs1_1),
    .prs2_1(prs2_1),
    .ready1_1(ready1_1),
    .ready2_1(ready2_1),

    .issue0_prs1(issue0_prs1),
    .issue0_prs2(issue0_prs2),
    .issue0_rs1_val(issue0_rs1_val),
    .issue0_rs2_val(issue0_rs2_val),

    .issue1_prs1(issue1_prs1),
    .issue1_prs2(issue1_prs2),
    .issue1_rs1_val(issue1_rs1_val),
    .issue1_rs2_val(issue1_rs2_val),

    .prd_0(prd_0),
    .prd_1(prd_1),

    .broadcast0_valid(broadcast0_valid),
    .broadcast0_tag(broadcast0_tag),
    .broadcast0_value(broadcast0_value),

    .broadcast1_valid(broadcast1_valid),
    .broadcast1_tag(broadcast1_tag),
    .broadcast1_value(broadcast1_value)
);

//////////////////////////////////////////////////
// DISPATCH
//////////////////////////////////////////////////

wire iq_valid0;
wire [3:0] iq_opcode0;
wire [5:0] iq_prs1_0;
wire [5:0] iq_prs2_0;
wire [5:0] iq_pd0;
wire iq_use_imm0;
wire [31:0] iq_imm0;
wire iq_ready1_0;
wire iq_ready2_0;
wire iq_is_branch0;
wire [2:0] iq_branch_cond0;
wire [31:0] iq_branch_target0;
wire [31:0] iq_branch_pc0;
wire iq_predicted_taken0;

wire iq_valid1;
wire [3:0] iq_opcode1;
wire [5:0] iq_prs1_1;
wire [5:0] iq_prs2_1;
wire [5:0] iq_pd1;
wire iq_use_imm1;
wire [31:0] iq_imm1;
wire iq_ready1_1;
wire iq_ready2_1;
wire iq_is_branch1;
wire [2:0] iq_branch_cond1;
wire [31:0] iq_branch_target1;
wire [31:0] iq_branch_pc1;
wire iq_predicted_taken1;

wire rob_dispatch0;
wire rob_dispatch1;

dispatch_unit dispatch_inst(
    .stall(rat_stall),
    .misprediction_valid(misprediction_valid),

    .valid0(valid0),
    .opcode0(opcode0),
    .prs1_0(prs1_0),
    .prs2_0(prs2_0),
    .prd_0(prd_0),
    .use_imm0(use_imm0),
    .imm0(imm0),
    .ready1_0(ready1_0),
    .ready2_0(ready2_0),
    .is_branch0(is_branch0),
    .branch_cond0(branch_cond0),
    .branch_target0(branch_target0),
    .branch_pc0(branch_pc0),
    .predicted_taken0(predicted_taken0),

    .valid1(valid1),
    .opcode1(opcode1),
    .prs1_1(prs1_1),
    .prs2_1(prs2_1),
    .prd_1(prd_1),
    .use_imm1(use_imm1),
    .imm1(imm1),
    .ready1_1(ready1_1),
    .ready2_1(ready2_1),
    .is_branch1(is_branch1),
    .branch_cond1(branch_cond1),
    .branch_target1(branch_target1),
    .branch_pc1(branch_pc1),
    .predicted_taken1(predicted_taken1),

    .iq_valid0(iq_valid0),
    .iq_opcode0(iq_opcode0),
    .iq_prs1_0(iq_prs1_0),
    .iq_prs2_0(iq_prs2_0),
    .iq_pd0(iq_pd0),
    .iq_use_imm0(iq_use_imm0),
    .iq_imm0(iq_imm0),
    .iq_ready1_0(iq_ready1_0),
    .iq_ready2_0(iq_ready2_0),
    .iq_is_branch0(iq_is_branch0),
    .iq_branch_cond0(iq_branch_cond0),
    .iq_branch_target0(iq_branch_target0),
    .iq_branch_pc0(iq_branch_pc0),
    .iq_predicted_taken0(iq_predicted_taken0),

    .iq_valid1(iq_valid1),
    .iq_opcode1(iq_opcode1),
    .iq_prs1_1(iq_prs1_1),
    .iq_prs2_1(iq_prs2_1),
    .iq_pd1(iq_pd1),
    .iq_use_imm1(iq_use_imm1),
    .iq_imm1(iq_imm1),
    .iq_ready1_1(iq_ready1_1),
    .iq_ready2_1(iq_ready2_1),
    .iq_is_branch1(iq_is_branch1),
    .iq_branch_cond1(iq_branch_cond1),
    .iq_branch_target1(iq_branch_target1),
    .iq_branch_pc1(iq_branch_pc1),
    .iq_predicted_taken1(iq_predicted_taken1),

    .rob_dispatch0(rob_dispatch0),
    .rob_dispatch1(rob_dispatch1)
);

//////////////////////////////////////////////////
// ISSUE QUEUE OUTPUT WIRES
//////////////////////////////////////////////////

wire [7:0] iqs_valid;
wire [7:0] iqs_ready1;
wire [7:0] iqs_ready2;
wire [7:0] iqs_use_imm;
wire [7:0] iqs_is_branch;
wire [7:0] iqs_predicted_taken;

wire [3:0] iqs_opcode [7:0];
wire [5:0] iqs_prs1   [7:0];
wire [5:0] iqs_prs2   [7:0];
wire [5:0] iqs_pd     [7:0];
wire [31:0] iqs_imm   [7:0];
wire [2:0] iqs_branch_cond   [7:0];
wire [31:0] iqs_branch_target [7:0];
wire [31:0] iqs_branch_pc     [7:0];

//////////////////////////////////////////////////
// ISSUE QUEUE
//////////////////////////////////////////////////

issue_queue iq_inst(
    .clk(clk),
    .reset(reset),

    .misprediction_valid(misprediction_valid),

    .valid0(iq_valid0),
    .opcode0(iq_opcode0),
    .prs1_0(iq_prs1_0),
    .prs2_0(iq_prs2_0),
    .pd0(iq_pd0),
    .use_imm0(iq_use_imm0),
    .imm0(iq_imm0),
    .ready1_0(iq_ready1_0),
    .ready2_0(iq_ready2_0),
    .is_branch0(iq_is_branch0),
    .branch_cond0(iq_branch_cond0),
    .branch_target0(iq_branch_target0),
    .branch_pc0(iq_branch_pc0),
    .predicted_taken0(iq_predicted_taken0),

    .valid1(iq_valid1),
    .opcode1(iq_opcode1),
    .prs1_1(iq_prs1_1),
    .prs2_1(iq_prs2_1),
    .pd1(iq_pd1),
    .use_imm1(iq_use_imm1),
    .imm1(iq_imm1),
    .ready1_1(iq_ready1_1),
    .ready2_1(iq_ready2_1),
    .is_branch1(iq_is_branch1),
    .branch_cond1(iq_branch_cond1),
    .branch_target1(iq_branch_target1),
    .branch_pc1(iq_branch_pc1),
    .predicted_taken1(iq_predicted_taken1),

    .broadcast0_valid(broadcast0_valid),
    .broadcast0_tag(broadcast0_tag),

    .broadcast1_valid(broadcast1_valid),
    .broadcast1_tag(broadcast1_tag),

    .issue0_valid(issue0_valid),
    .issue0_index(issue0_index),

    .issue1_valid(issue1_valid),
    .issue1_index(issue1_index),

    .valid(iqs_valid),
    .ready1(iqs_ready1),
    .ready2(iqs_ready2),
    .use_imm(iqs_use_imm),
    .is_branch(iqs_is_branch),
    .predicted_taken(iqs_predicted_taken),

    .opcode(iqs_opcode),
    .prs1(iqs_prs1),
    .prs2(iqs_prs2),
    .pd(iqs_pd),
    .imm(iqs_imm),
    .branch_cond(iqs_branch_cond),
    .branch_target(iqs_branch_target),
    .branch_pc(iqs_branch_pc)
);

//////////////////////////////////////////////////
// SCHEDULER
//////////////////////////////////////////////////

scheduler sched_inst(
    .clk(clk),
    .reset(reset),

    .valid(iqs_valid),
    .ready1(iqs_ready1),
    .ready2(iqs_ready2),
    .use_imm(iqs_use_imm),
    .is_branch(iqs_is_branch),
    .predicted_taken(iqs_predicted_taken),

    .opcode(iqs_opcode),
    .prs1(iqs_prs1),
    .prs2(iqs_prs2),
    .pd(iqs_pd),
    .imm(iqs_imm),
    .branch_cond(iqs_branch_cond),
    .branch_target(iqs_branch_target),
    .branch_pc(iqs_branch_pc),

    .issue0_valid(issue0_valid),
    .issue0_opcode(issue0_opcode),
    .issue0_prs1(issue0_prs1),
    .issue0_prs2(issue0_prs2),
    .issue0_pd(issue0_pd),
    .issue0_use_imm(issue0_use_imm),
    .issue0_imm(issue0_imm),
    .issue0_is_branch(issue0_is_branch),
    .issue0_predicted_taken(issue0_predicted_taken),
    .issue0_branch_cond(issue0_branch_cond),
    .issue0_branch_target(issue0_branch_target),
    .issue0_branch_pc(issue0_branch_pc),
    .issue0_index(issue0_index),

    .issue1_valid(issue1_valid),
    .issue1_opcode(issue1_opcode),
    .issue1_prs1(issue1_prs1),
    .issue1_prs2(issue1_prs2),
    .issue1_pd(issue1_pd),
    .issue1_use_imm(issue1_use_imm),
    .issue1_imm(issue1_imm),
    .issue1_is_branch(issue1_is_branch),
    .issue1_predicted_taken(issue1_predicted_taken),
    .issue1_branch_cond(issue1_branch_cond),
    .issue1_branch_target(issue1_branch_target),
    .issue1_branch_pc(issue1_branch_pc),
    .issue1_index(issue1_index)
);

//////////////////////////////////////////////////
// EXECUTION
//////////////////////////////////////////////////

execution_units exec_inst(
    .clk(clk),
    .reset(reset),

    .issue0_valid(issue0_valid),
    .issue0_opcode(issue0_opcode),
    .issue0_pd(issue0_pd),
    .issue0_use_imm(issue0_use_imm),
    .issue0_imm(issue0_imm),
    .issue0_is_branch(issue0_is_branch),
    .issue0_predicted_taken(issue0_predicted_taken),
    .issue0_branch_cond(issue0_branch_cond),
    .issue0_branch_target(issue0_branch_target),
    .issue0_branch_pc(issue0_branch_pc),
    .rs1_val0(issue0_rs1_val),
    .rs2_val0(issue0_rs2_val),

    .issue1_valid(issue1_valid),
    .issue1_opcode(issue1_opcode),
    .issue1_pd(issue1_pd),
    .issue1_use_imm(issue1_use_imm),
    .issue1_imm(issue1_imm),
    .issue1_is_branch(issue1_is_branch),
    .issue1_predicted_taken(issue1_predicted_taken),
    .issue1_branch_cond(issue1_branch_cond),
    .issue1_branch_target(issue1_branch_target),
    .issue1_branch_pc(issue1_branch_pc),
    .rs1_val1(issue1_rs1_val),
    .rs2_val1(issue1_rs2_val),

    .broadcast0_valid(broadcast0_valid),
    .broadcast0_tag(broadcast0_tag),
    .broadcast0_value(broadcast0_value),

    .broadcast1_valid(broadcast1_valid),
    .broadcast1_tag(broadcast1_tag),
    .broadcast1_value(broadcast1_value),

    .branch_resolved_valid(branch_resolved_valid),
    .branch_mispredicted(branch_mispredicted),
    .branch_correct_target(branch_correct_target),
    .branch_update_pc(branch_update_pc),
    .branch_update_taken(branch_update_taken)
);

//////////////////////////////////////////////////
// REORDER BUFFER
//////////////////////////////////////////////////

wire [4:0] rob_index0;
wire [4:0] rob_index1;

wire commit0_valid;
wire [5:0] commit0_tag;

wire commit1_valid;
wire [5:0] commit1_tag;

reorder_buffer rob_inst(
    .clk(clk),
    .reset(reset),

    .dispatch0_valid(rob_dispatch0),
    .dispatch1_valid(rob_dispatch1),

    .prd_0(prd_0),
    .prd_1(prd_1),

    .is_branch0(is_branch0),
    .is_branch1(is_branch1),

    .rob_index0(rob_index0),
    .rob_index1(rob_index1),

    .broadcast0_valid(broadcast0_valid),
    .broadcast0_tag(broadcast0_tag),

    .broadcast1_valid(broadcast1_valid),
    .broadcast1_tag(broadcast1_tag),

    .branch_resolved_valid(branch_resolved_valid),
    .misprediction_valid(misprediction_valid),

    .commit0_valid(commit0_valid),
    .commit0_tag(commit0_tag),

    .commit1_valid(commit1_valid),
    .commit1_tag(commit1_tag)
);

//////////////////////////////////////////////////
// COMMIT
//////////////////////////////////////////////////

wire commit_done;
wire [7:0] retired_count;

commit_unit commit_inst(
    .clk(clk),
    .reset(reset),

    .commit0_valid(commit0_valid),
    .commit0_tag(commit0_tag),

    .commit1_valid(commit1_valid),
    .commit1_tag(commit1_tag),

    .commit_done(commit_done),
    .retired_count(retired_count)
);

endmodule
