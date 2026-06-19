module ooo_top(
    input clk,
    input reset
);

//////////////////////////////////////////////////
// FETCH
//////////////////////////////////////////////////

wire [31:0] pc;
wire [31:0] inst0;
wire [31:0] inst1;

fetch_unit fetch_inst(
    .clk(clk),
    .reset(reset),
    .pc(pc),
    .inst0(inst0),
    .inst1(inst1)
);

//////////////////////////////////////////////////
// DECODE
//////////////////////////////////////////////////

wire valid0;
wire valid1;

wire [3:0] opcode0;
wire [3:0] opcode1;

wire [4:0] rs1_0;
wire [4:0] rs2_0;
wire [4:0] rd_0;

wire [4:0] rs1_1;
wire [4:0] rs2_1;
wire [4:0] rd_1;

decode_unit decode_inst(
    .inst0(inst0),
    .inst1(inst1),

    .valid0(valid0),
    .valid1(valid1),

    .opcode0(opcode0),
    .opcode1(opcode1),

    .rs1_0(rs1_0),
    .rs2_0(rs2_0),
    .rd_0(rd_0),

    .rs1_1(rs1_1),
    .rs2_1(rs2_1),
    .rd_1(rd_1)
);

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
    .valid1(valid1),

    .rs1_0(rs1_0),
    .rs2_0(rs2_0),
    .rd_0(rd_0),

    .rs1_1(rs1_1),
    .rs2_1(rs2_1),
    .rd_1(rd_1),

    .prs1_0(prs1_0),
    .prs2_0(prs2_0),
    .prs1_1(prs1_1),
    .prs2_1(prs2_1),

    .prd_0(prd_0),
    .prd_1(prd_1)
);

//////////////////////////////////////////////////
// PHYSICAL REGISTER FILE
//////////////////////////////////////////////////

wire [31:0] rs1_val0;
wire [31:0] rs2_val0;
wire [31:0] rs1_val1;
wire [31:0] rs2_val1;

wire ready1_0;
wire ready2_0;
wire ready1_1;
wire ready2_1;

wire broadcast_valid;
wire [5:0] broadcast_tag;
wire [31:0] broadcast_value;

physical_regfile regfile_inst(
    .clk(clk),
    .reset(reset),

    .prs1_0(prs1_0),
    .prs2_0(prs2_0),

    .rs1_val0(rs1_val0),
    .rs2_val0(rs2_val0),

    .ready1_0(ready1_0),
    .ready2_0(ready2_0),

    .prs1_1(prs1_1),
    .prs2_1(prs2_1),

    .rs1_val1(rs1_val1),
    .rs2_val1(rs2_val1),

    .ready1_1(ready1_1),
    .ready2_1(ready2_1),

    .broadcast_valid(broadcast_valid),
    .broadcast_tag(broadcast_tag),
    .broadcast_value(broadcast_value)
);

//////////////////////////////////////////////////
// ISSUE QUEUE OUTPUT WIRES
//////////////////////////////////////////////////

wire [7:0] iq_valid;
wire [7:0] iq_ready1;
wire [7:0] iq_ready2;

wire [3:0] iq_opcode [7:0];
wire [5:0] iq_prs1   [7:0];
wire [5:0] iq_prs2   [7:0];
wire [5:0] iq_pd     [7:0];

//////////////////////////////////////////////////
// SCHEDULER OUTPUT WIRES
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

wire [2:0] issue0_index;
wire [2:0] issue1_index;

//////////////////////////////////////////////////
// ISSUE QUEUE
//////////////////////////////////////////////////

issue_queue iq_inst(
    .clk(clk),
    .reset(reset),

    .valid0(valid0),
    .opcode0(opcode0),
    .prs1_0(prs1_0),
    .prs2_0(prs2_0),
    .pd0(prd_0),
    .ready1_0(ready1_0),
    .ready2_0(ready2_0),

    .broadcast_valid(broadcast_valid),
    .broadcast_tag(broadcast_tag),

    .issue0_valid(issue0_valid),
    .issue0_index(issue0_index),

    .issue1_valid(issue1_valid),
    .issue1_index(issue1_index),

    .valid(iq_valid),
    .ready1(iq_ready1),
    .ready2(iq_ready2),

    .opcode(iq_opcode),
    .prs1(iq_prs1),
    .prs2(iq_prs2),
    .pd(iq_pd)
);

//////////////////////////////////////////////////
// SCHEDULER
//////////////////////////////////////////////////

scheduler sched_inst(
    .clk(clk),
    .reset(reset),

    .valid(iq_valid),
    .ready1(iq_ready1),
    .ready2(iq_ready2),

    .opcode(iq_opcode),
    .prs1(iq_prs1),
    .prs2(iq_prs2),
    .pd(iq_pd),

    .issue0_valid(issue0_valid),
    .issue0_opcode(issue0_opcode),
    .issue0_prs1(issue0_prs1),
    .issue0_prs2(issue0_prs2),
    .issue0_pd(issue0_pd),
    .issue0_index(issue0_index),

    .issue1_valid(issue1_valid),
    .issue1_opcode(issue1_opcode),
    .issue1_prs1(issue1_prs1),
    .issue1_prs2(issue1_prs2),
    .issue1_pd(issue1_pd),
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
    .issue0_prs1(issue0_prs1),
    .issue0_prs2(issue0_prs2),
    .issue0_pd(issue0_pd),

    .rs1_val0(rs1_val0),
    .rs2_val0(rs2_val0),

    .issue1_valid(issue1_valid),
    .issue1_opcode(issue1_opcode),
    .issue1_prs1(issue1_prs1),
    .issue1_prs2(issue1_prs2),
    .issue1_pd(issue1_pd),

    .rs1_val1(rs1_val1),
    .rs2_val1(rs2_val1),

    .broadcast_valid(broadcast_valid),
    .broadcast_tag(broadcast_tag),
    .broadcast_value(broadcast_value)
);

endmodule
