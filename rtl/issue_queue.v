module issue_queue
#(
    parameter ISSUEQ_SIZE = 8
)
(
    input clk,
    input reset,

    ////////////////////////////////////////////////
    // DISPATCH INPUT (BOTH SLOTS, SAME CYCLE)
    ////////////////////////////////////////////////

    input valid0,
    input [3:0] opcode0,
    input [5:0] prs1_0,
    input [5:0] prs2_0,
    input [5:0] pd0,
    input use_imm0,
    input [31:0] imm0,
    input ready1_0,
    input ready2_0,

    input valid1,
    input [3:0] opcode1,
    input [5:0] prs1_1,
    input [5:0] prs2_1,
    input [5:0] pd1,
    input use_imm1,
    input [31:0] imm1,
    input ready1_1,
    input ready2_1,

    ////////////////////////////////////////////////
    // BROADCAST FROM EXECUTION (2 CDB PORTS)
    ////////////////////////////////////////////////

    input broadcast0_valid,
    input [5:0] broadcast0_tag,

    input broadcast1_valid,
    input [5:0] broadcast1_tag,

    ////////////////////////////////////////////////
    // ISSUE FEEDBACK (REMOVE ENTRY)
    ////////////////////////////////////////////////

    input issue0_valid,
    input [$clog2(ISSUEQ_SIZE)-1:0] issue0_index,

    input issue1_valid,
    input [$clog2(ISSUEQ_SIZE)-1:0] issue1_index,

    ////////////////////////////////////////////////
    // OUTPUT TO SCHEDULER
    ////////////////////////////////////////////////

    output reg [ISSUEQ_SIZE-1:0] valid,
    output reg [ISSUEQ_SIZE-1:0] ready1,
    output reg [ISSUEQ_SIZE-1:0] ready2,
    output reg [ISSUEQ_SIZE-1:0] use_imm,

    output reg [3:0] opcode [ISSUEQ_SIZE-1:0],
    output reg [5:0] prs1   [ISSUEQ_SIZE-1:0],
    output reg [5:0] prs2   [ISSUEQ_SIZE-1:0],
    output reg [5:0] pd     [ISSUEQ_SIZE-1:0],
    output reg [31:0] imm   [ISSUEQ_SIZE-1:0]
);

integer i;
integer free_index0;
integer free_index1;

//////////////////////////////////////////////////
// MAIN LOGIC
//////////////////////////////////////////////////

always @(posedge clk or posedge reset)
begin

    if(reset)
    begin

        for(i=0;i<ISSUEQ_SIZE;i=i+1)
        begin
            valid[i]   <= 0;
            ready1[i]  <= 0;
            ready2[i]  <= 0;
            use_imm[i] <= 0;

            opcode[i] <= 0;
            prs1[i]   <= 0;
            prs2[i]   <= 0;
            pd[i]     <= 0;
            imm[i]    <= 0;
        end

    end
    else
    begin

        ////////////////////////////////////////////////
        // BROADCAST WAKEUP (2 CDB PORTS)
        ////////////////////////////////////////////////

        if(broadcast0_valid)
        begin
            for(i=0;i<ISSUEQ_SIZE;i=i+1)
            begin
                if(valid[i] && !ready1[i] && prs1[i]==broadcast0_tag)
                    ready1[i] <= 1;

                if(valid[i] && !ready2[i] && prs2[i]==broadcast0_tag)
                    ready2[i] <= 1;
            end
        end

        if(broadcast1_valid)
        begin
            for(i=0;i<ISSUEQ_SIZE;i=i+1)
            begin
                if(valid[i] && !ready1[i] && prs1[i]==broadcast1_tag)
                    ready1[i] <= 1;

                if(valid[i] && !ready2[i] && prs2[i]==broadcast1_tag)
                    ready2[i] <= 1;
            end
        end

        ////////////////////////////////////////////////
        // REMOVE ISSUED ENTRIES
        ////////////////////////////////////////////////

        if(issue0_valid)
            valid[issue0_index] <= 0;

        if(issue1_valid)
            valid[issue1_index] <= 0;

        ////////////////////////////////////////////////
        // DISPATCH NEW ENTRIES (SLOT 0, THEN SLOT 1)
        ////////////////////////////////////////////////
        // Both slots dispatch in the same cycle, so slot 1's search must
        // exclude whatever free slot slot 0 just claimed -- otherwise two
        // simultaneously-valid instructions could be written into the
        // same entry and one would silently vanish.

        free_index0 = -1;
        for(i=0;i<ISSUEQ_SIZE;i=i+1)
        begin
            if(!valid[i] && free_index0==-1)
                free_index0 = i;
        end

        if(valid0 && free_index0!=-1)
        begin
            valid[free_index0]   <= 1;
            opcode[free_index0]  <= opcode0;
            prs1[free_index0]    <= prs1_0;
            prs2[free_index0]    <= prs2_0;
            pd[free_index0]      <= pd0;
            use_imm[free_index0] <= use_imm0;
            imm[free_index0]     <= imm0;
            ready1[free_index0]  <= ready1_0;
            ready2[free_index0]  <= ready2_0;
        end

        free_index1 = -1;
        for(i=0;i<ISSUEQ_SIZE;i=i+1)
        begin
            if(!valid[i] && i!=free_index0 && free_index1==-1)
                free_index1 = i;
        end

        if(valid1 && free_index1!=-1)
        begin
            valid[free_index1]   <= 1;
            opcode[free_index1]  <= opcode1;
            prs1[free_index1]    <= prs1_1;
            prs2[free_index1]    <= prs2_1;
            pd[free_index1]      <= pd1;
            use_imm[free_index1] <= use_imm1;
            imm[free_index1]     <= imm1;
            ready1[free_index1]  <= ready1_1;
            ready2[free_index1]  <= ready2_1;
        end

    end

end

endmodule
