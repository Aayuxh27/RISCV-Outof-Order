module dispatch_unit
(
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

    output iq_valid1,
    output [3:0] iq_opcode1,
    output [5:0] iq_prs1_1,
    output [5:0] iq_prs2_1,
    output [5:0] iq_pd1,
    output iq_use_imm1,
    output [31:0] iq_imm1,
    output iq_ready1_1,
    output iq_ready2_1,

//////////////////////////////////////////////////
// ROB ALLOCATION
//////////////////////////////////////////////////

    output rob_dispatch0,
    output rob_dispatch1
);

//////////////////////////////////////////////////
// DISPATCH LOGIC (PURELY COMBINATIONAL)
//////////////////////////////////////////////////
// This core has no branches or memory ops, so an instruction's
// destination register is its only architectural effect. An
// instruction renamed with prd==0 (i.e. its architectural destination
// is x0) therefore has nothing left to do, so it is dropped here
// instead of being let into the issue queue / ROB, where it could
// otherwise alias with x0's permanently-zero physical tag.

assign iq_valid0 = valid0 && (prd_0 != 6'd0);
assign iq_valid1 = valid1 && (prd_1 != 6'd0);

assign iq_opcode0  = opcode0;
assign iq_prs1_0   = prs1_0;
assign iq_prs2_0   = prs2_0;
assign iq_pd0      = prd_0;
assign iq_use_imm0 = use_imm0;
assign iq_imm0     = imm0;
assign iq_ready1_0 = ready1_0;
assign iq_ready2_0 = use_imm0 || ready2_0; // immediate operand needs no regfile read

assign iq_opcode1  = opcode1;
assign iq_prs1_1   = prs1_1;
assign iq_prs2_1   = prs2_1;
assign iq_pd1      = prd_1;
assign iq_use_imm1 = use_imm1;
assign iq_imm1     = imm1;
assign iq_ready1_1 = ready1_1;
assign iq_ready2_1 = use_imm1 || ready2_1;

assign rob_dispatch0 = iq_valid0;
assign rob_dispatch1 = iq_valid1;

endmodule
