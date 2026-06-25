module branch_predict_unit
#(
    parameter TABLE_BITS = 6 // 64-entry table
)
(
    input clk,
    input reset,

    ////////////////////////////////////////////////
    // FETCH-TIME LOOKUP (SAME CYCLE AS DECODE)
    ////////////////////////////////////////////////

    input [31:0] pc, // base PC of this fetch group (slot0's own PC)

    input is_branch0,
    input [31:0] branch_target0,

    input is_branch1,
    input [31:0] branch_target1,

    output predicted_taken0,
    output predicted_taken1,

    output redirect_valid,
    output [31:0] redirect_pc,
    output squash_slot1,

    ////////////////////////////////////////////////
    // RESOLUTION-TIME UPDATE (FROM EXECUTION)
    ////////////////////////////////////////////////

    input update_valid,
    input [31:0] update_pc,
    input update_taken
);

//////////////////////////////////////////////////
// BIMODAL TABLE: 2-BIT SATURATING COUNTERS
//////////////////////////////////////////////////
// Reset to weakly-taken (2'b10), not weakly-not-taken: most branches
// this kind of cold predictor actually helps with are loop branches,
// which are taken far more often than not, so defaulting to taken
// minimizes cold-start mispredictions. This core has no loops (no
// JAL/JALR), so that benefit isn't demonstrated by the bundled test
// program, but it's still the right default for any future branch.

reg [1:0] table_ [0:(1<<TABLE_BITS)-1];
integer i;

wire [31:0] pc1 = pc + 32'd4;

wire [TABLE_BITS-1:0] idx0       = pc[TABLE_BITS+1:2];
wire [TABLE_BITS-1:0] idx1       = pc1[TABLE_BITS+1:2];
wire [TABLE_BITS-1:0] idx_update = update_pc[TABLE_BITS+1:2];

always @(posedge clk or posedge reset)
begin

    if(reset)
    begin
        for(i=0;i<(1<<TABLE_BITS);i=i+1)
            table_[i] <= 2'b10;
    end
    else if(update_valid)
    begin
        if(update_taken)
        begin
            if(table_[idx_update] != 2'b11)
                table_[idx_update] <= table_[idx_update] + 2'd1;
        end
        else
        begin
            if(table_[idx_update] != 2'b00)
                table_[idx_update] <= table_[idx_update] - 2'd1;
        end
    end

end

//////////////////////////////////////////////////
// PREDICTION + REDIRECT (SLOT 0 HAS PRIORITY)
//////////////////////////////////////////////////
// If slot 0 is predicted taken, slot 1 (sequentially after it in the
// same fetch group) is on the wrong path by definition and must be
// squashed -- it never should have been fetched down this path. Only
// if slot 0 does NOT redirect does slot 1's own prediction matter.

assign predicted_taken0 = table_[idx0][1];
assign predicted_taken1 = table_[idx1][1];

wire slot0_redirect = is_branch0 && predicted_taken0;
wire slot1_redirect = is_branch1 && predicted_taken1;

assign squash_slot1   = slot0_redirect;
assign redirect_valid = slot0_redirect || slot1_redirect;
assign redirect_pc    = slot0_redirect ? branch_target0 : branch_target1;

endmodule
