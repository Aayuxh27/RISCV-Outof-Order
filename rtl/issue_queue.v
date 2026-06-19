module issue_queue
#(
    parameter ISSUEQ_SIZE = 8
)
(
    input clk,
    input reset,

    ////////////////////////////////////////////////
    // DISPATCH INPUT
    ////////////////////////////////////////////////

    input valid0,
    input [3:0] opcode0,
    input [5:0] prs1_0,
    input [5:0] prs2_0,
    input [5:0] pd0,
    input ready1_0,
    input ready2_0,

    ////////////////////////////////////////////////
    // BROADCAST FROM EXECUTION
    ////////////////////////////////////////////////

    input broadcast_valid,
    input [5:0] broadcast_tag,

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

    output reg [3:0] opcode [ISSUEQ_SIZE-1:0],
    output reg [5:0] prs1   [ISSUEQ_SIZE-1:0],
    output reg [5:0] prs2   [ISSUEQ_SIZE-1:0],
    output reg [5:0] pd     [ISSUEQ_SIZE-1:0]
);

integer i;
integer free_index;

//////////////////////////////////////////////////
// MAIN LOGIC
//////////////////////////////////////////////////

always @(posedge clk or posedge reset)
begin

    if(reset)
    begin

        for(i=0;i<ISSUEQ_SIZE;i=i+1)
        begin
            valid[i]  <= 0;
            ready1[i] <= 0;
            ready2[i] <= 0;

            opcode[i] <= 0;
            prs1[i]   <= 0;
            prs2[i]   <= 0;
            pd[i]     <= 0;
        end

    end
    else
    begin

        ////////////////////////////////////////////////
        // BROADCAST WAKEUP
        ////////////////////////////////////////////////

        if(broadcast_valid)
        begin

            for(i=0;i<ISSUEQ_SIZE;i=i+1)
            begin

                if(valid[i] && !ready1[i] && prs1[i]==broadcast_tag)
                    ready1[i] <= 1;

                if(valid[i] && !ready2[i] && prs2[i]==broadcast_tag)
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
        // DISPATCH NEW ENTRY
        ////////////////////////////////////////////////

        if(valid0)
        begin

            free_index = -1;

            for(i=0;i<ISSUEQ_SIZE;i=i+1)
            begin
                if(!valid[i] && free_index==-1)
                    free_index = i;
            end

            if(free_index!=-1)
            begin

                valid[free_index]  <= 1;

                opcode[free_index] <= opcode0;

                prs1[free_index] <= prs1_0;
                prs2[free_index] <= prs2_0;

                pd[free_index] <= pd0;

                ready1[free_index] <= ready1_0;
                ready2[free_index] <= ready2_0;

            end

        end

    end

end

endmodule
