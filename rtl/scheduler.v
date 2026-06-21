module scheduler
#(
    parameter ISSUEQ_SIZE = 8
)
(
    input clk,
    input reset,

    ////////////////////////////////////////////////
    // ISSUE QUEUE INPUTS
    ////////////////////////////////////////////////

    input [ISSUEQ_SIZE-1:0] valid,
    input [ISSUEQ_SIZE-1:0] ready1,
    input [ISSUEQ_SIZE-1:0] ready2,
    input [ISSUEQ_SIZE-1:0] use_imm,

    input [3:0] opcode [ISSUEQ_SIZE-1:0],
    input [5:0] prs1   [ISSUEQ_SIZE-1:0],
    input [5:0] prs2   [ISSUEQ_SIZE-1:0],
    input [5:0] pd     [ISSUEQ_SIZE-1:0],
    input [31:0] imm   [ISSUEQ_SIZE-1:0],

    ////////////////////////////////////////////////
    // ISSUE SLOT 0
    ////////////////////////////////////////////////

    output reg issue0_valid,
    output reg [3:0] issue0_opcode,
    output reg [5:0] issue0_prs1,
    output reg [5:0] issue0_prs2,
    output reg [5:0] issue0_pd,
    output reg issue0_use_imm,
    output reg [31:0] issue0_imm,
    output reg [$clog2(ISSUEQ_SIZE)-1:0] issue0_index,

    ////////////////////////////////////////////////
    // ISSUE SLOT 1
    ////////////////////////////////////////////////

    output reg issue1_valid,
    output reg [3:0] issue1_opcode,
    output reg [5:0] issue1_prs1,
    output reg [5:0] issue1_prs2,
    output reg [5:0] issue1_pd,
    output reg issue1_use_imm,
    output reg [31:0] issue1_imm,
    output reg [$clog2(ISSUEQ_SIZE)-1:0] issue1_index
);

integer i;

//////////////////////////////////////////////////
// SCHEDULER LOGIC
//////////////////////////////////////////////////

always @(*)
begin

    ////////////////////////////////////////////////
    // DEFAULTS
    ////////////////////////////////////////////////

    issue0_valid = 0;
    issue1_valid = 0;

    issue0_opcode = 0;
    issue1_opcode = 0;

    issue0_prs1 = 0;
    issue0_prs2 = 0;
    issue1_prs1 = 0;
    issue1_prs2 = 0;

    issue0_pd = 0;
    issue1_pd = 0;

    issue0_use_imm = 0;
    issue1_use_imm = 0;

    issue0_imm = 0;
    issue1_imm = 0;

    issue0_index = 0;
    issue1_index = 0;

    ////////////////////////////////////////////////
    // FIND OLDEST READY INSTRUCTION
    ////////////////////////////////////////////////

    for(i=0;i<ISSUEQ_SIZE;i=i+1)
    begin
        if(valid[i] && ready1[i] && ready2[i] && !issue0_valid)
        begin
            issue0_valid = 1;

            issue0_opcode  = opcode[i];
            issue0_prs1    = prs1[i];
            issue0_prs2    = prs2[i];
            issue0_pd      = pd[i];
            issue0_use_imm = use_imm[i];
            issue0_imm     = imm[i];

            issue0_index  = i;
        end
    end

    ////////////////////////////////////////////////
    // FIND SECOND READY INSTRUCTION
    ////////////////////////////////////////////////

    for(i=0;i<ISSUEQ_SIZE;i=i+1)
    begin
        if(valid[i] && ready1[i] && ready2[i] &&
           issue0_valid && (i!=issue0_index) &&
           !issue1_valid)
        begin

            issue1_valid = 1;

            issue1_opcode  = opcode[i];
            issue1_prs1    = prs1[i];
            issue1_prs2    = prs2[i];
            issue1_pd      = pd[i];
            issue1_use_imm = use_imm[i];
            issue1_imm     = imm[i];

            issue1_index  = i;

        end
    end

end

endmodule
