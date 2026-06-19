module commit_unit(

    input clk,
    input reset,

    input commit_valid,
    input [5:0] prd_commit,

    output reg commit_done

);

always @(posedge clk or posedge reset)
begin

    if(reset)
    begin
        commit_done <= 0;
    end
    else
    begin

        if(commit_valid)
        begin
            commit_done <= 1;
        end
        else
        begin
            commit_done <= 0;
        end

    end

end

endmodule
