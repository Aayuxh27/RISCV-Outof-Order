module reorder_buffer
#(
    parameter ROB_SIZE = 32
)
(
    input clk,
    input reset,

//////////////////////////////////////////////////
// DISPATCH ALLOCATION (BOTH SLOTS, SAME CYCLE)
//////////////////////////////////////////////////

    input dispatch0_valid,
    input dispatch1_valid,

    input [5:0] prd_0,
    input [5:0] prd_1,

    output reg [4:0] rob_index0,
    output reg [4:0] rob_index1,

//////////////////////////////////////////////////
// EXECUTION WRITEBACK (2 CDB PORTS)
//////////////////////////////////////////////////

    input broadcast0_valid,
    input [5:0] broadcast0_tag,

    input broadcast1_valid,
    input [5:0] broadcast1_tag,

//////////////////////////////////////////////////
// COMMIT OUTPUT (UP TO 2 PER CYCLE)
//////////////////////////////////////////////////

    output reg commit0_valid,
    output reg [5:0] commit0_tag,

    output reg commit1_valid,
    output reg [5:0] commit1_tag
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

        rob_index0 <= 0;
        rob_index1 <= 0;

        commit0_valid <= 0;
        commit0_tag   <= 0;
        commit1_valid <= 0;
        commit1_tag   <= 0;

    end
    else
    begin

//////////////////////////////////////////////////
// DISPATCH ALLOCATE
//////////////////////////////////////////////////
// dispatch1 must offset by dispatch0_valid, exactly like the RAT does
// for prd_1 -- otherwise two same-cycle allocations both target index
// `tail` and the tail pointer only advances by one, silently dropping
// one of the two entries and corrupting the ring buffer.

        if(dispatch0_valid)
        begin
            valid[tail] <= 1;
            ready[tail] <= 0;
            tag[tail]   <= prd_0;

            rob_index0 <= tail;
        end

        if(dispatch1_valid)
        begin
            valid[tail + dispatch0_valid] <= 1;
            ready[tail + dispatch0_valid] <= 0;
            tag[tail + dispatch0_valid]   <= prd_1;

            rob_index1 <= tail + dispatch0_valid;
        end

        tail <= tail + dispatch0_valid + dispatch1_valid;

//////////////////////////////////////////////////
// EXECUTION WRITEBACK
//////////////////////////////////////////////////

        if(broadcast0_valid)
        begin
            for(i=0;i<ROB_SIZE;i=i+1)
                if(valid[i] && tag[i] == broadcast0_tag)
                    ready[i] <= 1;
        end

        if(broadcast1_valid)
        begin
            for(i=0;i<ROB_SIZE;i=i+1)
                if(valid[i] && tag[i] == broadcast1_tag)
                    ready[i] <= 1;
        end

//////////////////////////////////////////////////
// COMMIT (UP TO 2 IN ORDER, FROM THE HEAD)
//////////////////////////////////////////////////

        commit0_valid <= 0;
        commit1_valid <= 0;

        if(valid[head] && ready[head])
        begin

            commit0_valid <= 1;
            commit0_tag   <= tag[head];

            valid[head] <= 0;

            if(valid[head+1] && ready[head+1])
            begin
                commit1_valid <= 1;
                commit1_tag   <= tag[head+1];

                valid[head+1] <= 0;

                head <= head + 2;
            end
            else
            begin
                head <= head + 1;
            end

        end

    end

end

endmodule
