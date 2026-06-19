module dispatch_unit
(
    input clk,
    input reset,

//////////////////////////////////////////////////
// DECODE INPUT
//////////////////////////////////////////////////

    input valid0,
    input [3:0] opcode0,
    input [4:0] rs1_0,
    input [4:0] rs2_0,
    input [4:0] rd_0,

    input valid1,
    input [3:0] opcode1,
    input [4:0] rs1_1,
    input [4:0] rs2_1,
    input [4:0] rd_1,

//////////////////////////////////////////////////
// RENAME (RAT) INPUT
//////////////////////////////////////////////////

    input [5:0] prs1_0,
    input [5:0] prs2_0,
    input [5:0] prd_0,

    input [5:0] prs1_1,
    input [5:0] prs2_1,
    input [5:0] prd_1,

//////////////////////////////////////////////////
// REGFILE READY INPUT
//////////////////////////////////////////////////

    input ready1_0,
    input ready2_0,

    input ready1_1,
    input ready2_1,

//////////////////////////////////////////////////
// ISSUE QUEUE OUTPUT
//////////////////////////////////////////////////

    output reg iq_valid0,

    output reg [3:0] iq_opcode0,
    output reg [5:0] iq_prs1_0,
    output reg [5:0] iq_prs2_0,
    output reg [5:0] iq_pd0,

    output reg iq_ready1_0,
    output reg iq_ready2_0,

//////////////////////////////////////////////////
// ROB ALLOCATION
//////////////////////////////////////////////////

    output reg rob_dispatch0,
    output reg rob_dispatch1
);

//////////////////////////////////////////////////
// DISPATCH LOGIC
//////////////////////////////////////////////////

always @(*)
begin

//////////////////////////////////////////////////
// DEFAULTS
//////////////////////////////////////////////////

    iq_valid0 = 0;

    iq_opcode0 = 0;
    iq_prs1_0 = 0;
    iq_prs2_0 = 0;
    iq_pd0 = 0;

    iq_ready1_0 = 0;
    iq_ready2_0 = 0;

    rob_dispatch0 = 0;
    rob_dispatch1 = 0;

//////////////////////////////////////////////////
// DISPATCH INSTRUCTION 0
//////////////////////////////////////////////////

    if(valid0)
    begin

        iq_valid0 = 1;

        iq_opcode0 = opcode0;

        iq_prs1_0 = prs1_0;
        iq_prs2_0 = prs2_0;

        iq_pd0 = prd_0;

        iq_ready1_0 = ready1_0;
        iq_ready2_0 = ready2_0;

        rob_dispatch0 = 1;

    end

//////////////////////////////////////////////////
// DISPATCH INSTRUCTION 1
//////////////////////////////////////////////////

    if(valid1)
    begin
        rob_dispatch1 = 1;
    end

end

endmodule
