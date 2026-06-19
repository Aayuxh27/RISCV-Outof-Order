module reorder_buffer
#(
    parameter ROB_SIZE = 32
)
(
    input clk,
    input reset,

//////////////////////////////////////////////////
// DISPATCH ALLOCATION
//////////////////////////////////////////////////

    input dispatch0_valid,
    input dispatch1_valid,

    input [5:0] prd_0,
    input [5:0] prd_1,

    output reg [4:0] rob_index0,
    output reg [4:0] rob_index1,

//////////////////////////////////////////////////
// EXECUTION WRITEBACK
//////////////////////////////////////////////////

    input broadcast_valid,
    input [5:0] broadcast_tag,

//////////////////////////////////////////////////
// COMMIT OUTPUT
//////////////////////////////////////////////////

    output reg commit_valid,
    output reg [5:0] commit_tag
);

//////////////////////////////////////////////////
// ROB STORAGE
//////////////////////////////////////////////////

reg valid [0:ROB_SIZE-1];
reg ready [0:ROB_SIZE-1];
reg [5:0] tag [0:ROB_SIZE-1];

//////////////////////////////////////////////////
// HEAD / TAIL POINTERS
//////////////////////////////////////////////////

reg [4:0] head;
reg [4:0] tail;

integer i;

//////////////////////////////////////////////////
// MAIN LOGIC
//////////////////////////////////////////////////

always @(posedge clk or posedge reset)
begin

    if(reset)
    begin

        for(i=0;i<ROB_SIZE;i=i+1)
        begin
            valid[i] <= 0;
            ready[i] <= 0;
            tag[i]   <= 0;
        end

        head <= 0;
        tail <= 0;

        commit_valid <= 0;
        commit_tag   <= 0;

    end
    else
    begin

//////////////////////////////////////////////////
// DISPATCH ALLOCATE
//////////////////////////////////////////////////

        if(dispatch0_valid)
        begin

            valid[tail] <= 1;
            ready[tail] <= 0;
            tag[tail]   <= prd_0;

            rob_index0 <= tail;

            tail <= tail + 1;

        end

        if(dispatch1_valid)
        begin

            valid[tail] <= 1;
            ready[tail] <= 0;
            tag[tail]   <= prd_1;

            rob_index1 <= tail;

            tail <= tail + 1;

        end

//////////////////////////////////////////////////
// EXECUTION WRITEBACK
//////////////////////////////////////////////////

        if(broadcast_valid)
        begin

            for(i=0;i<ROB_SIZE;i=i+1)
            begin

                if(valid[i] && tag[i] == broadcast_tag)
                    ready[i] <= 1;

            end

        end

//////////////////////////////////////////////////
// COMMIT
//////////////////////////////////////////////////

        commit_valid <= 0;

        if(valid[head] && ready[head])
        begin

            commit_valid <= 1;
            commit_tag   <= tag[head];

            valid[head] <= 0;

            head <= head + 1;

        end

    end

end

endmodule
