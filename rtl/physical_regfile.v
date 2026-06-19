module physical_regfile
#(
    parameter PHYS_REGS = 64
)
(
    input clk,
    input reset,

    ////////////////////////////////////////////////
    // READ PORTS (slot 0)
    ////////////////////////////////////////////////

    input [5:0] prs1_0,
    input [5:0] prs2_0,

    output reg [31:0] rs1_val0,
    output reg [31:0] rs2_val0,

    output reg ready1_0,
    output reg ready2_0,

    ////////////////////////////////////////////////
    // READ PORTS (slot 1)
    ////////////////////////////////////////////////

    input [5:0] prs1_1,
    input [5:0] prs2_1,

    output reg [31:0] rs1_val1,
    output reg [31:0] rs2_val1,

    output reg ready1_1,
    output reg ready2_1,

    ////////////////////////////////////////////////
    // BROADCAST WRITEBACK (CDB)
    ////////////////////////////////////////////////

    input broadcast_valid,
    input [5:0] broadcast_tag,
    input [31:0] broadcast_value
);

//////////////////////////////////////////////////
// PHYSICAL REGISTER STORAGE
//////////////////////////////////////////////////

reg [31:0] regfile [0:PHYS_REGS-1];
reg ready [0:PHYS_REGS-1];

integer i;

//////////////////////////////////////////////////
// RESET + WRITEBACK
//////////////////////////////////////////////////

always @(posedge clk or posedge reset)
begin

    if(reset)
    begin

        for(i=0;i<PHYS_REGS;i=i+1)
        begin
            regfile[i] <= 0;
            ready[i]   <= 1;
        end

    end
    else
    begin

        ////////////////////////////////////////////////
        // WRITEBACK FROM EXECUTION
        ////////////////////////////////////////////////

        if(broadcast_valid)
        begin
            regfile[broadcast_tag] <= broadcast_value;
            ready[broadcast_tag]   <= 1;
        end

    end

end

//////////////////////////////////////////////////
// READ PORTS
//////////////////////////////////////////////////

always @(*)
begin

    ////////////////////////////////////////////////
    // SLOT 0
    ////////////////////////////////////////////////

    rs1_val0 = regfile[prs1_0];
    rs2_val0 = regfile[prs2_0];

    ready1_0 = ready[prs1_0];
    ready2_0 = ready[prs2_0];

    ////////////////////////////////////////////////
    // SLOT 1
    ////////////////////////////////////////////////

    rs1_val1 = regfile[prs1_1];
    rs2_val1 = regfile[prs2_1];

    ready1_1 = ready[prs1_1];
    ready2_1 = ready[prs2_1];

end

endmodule
