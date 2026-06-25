module commit_unit
#(
    parameter CNT_WIDTH = 8
)
(
    input clk,
    input reset,

    input commit0_valid,
    input [5:0] commit0_tag,

    input commit1_valid,
    input [5:0] commit1_tag,

    output reg commit_done,
    output reg [CNT_WIDTH-1:0] retired_count
);

//////////////////////////////////////////////////
// RETIREMENT TRACKING
//////////////////////////////////////////////////
// commit_done pulses whenever the ROB retires anything this cycle;
// retired_count gives the waveform/testbench a running total so "did
// every dispatched instruction eventually retire" is a single number
// to check instead of having to eyeball individual commit pulses.

always @(posedge clk or posedge reset)
begin

    if(reset)
    begin
        commit_done   <= 0;
        retired_count <= 0;
    end
    else
    begin
        commit_done   <= commit0_valid || commit1_valid;
        retired_count <= retired_count + commit0_valid + commit1_valid;
    end

end

endmodule
