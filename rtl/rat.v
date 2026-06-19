module rat
#(
    parameter ARCH_REGS = 32,
    parameter PHYS_REGS = 64
)
(
    input clk,
    input reset,

    // decode inputs
    input valid0,
    input valid1,

    input [4:0] rs1_0,
    input [4:0] rs2_0,
    input [4:0] rd_0,

    input [4:0] rs1_1,
    input [4:0] rs2_1,
    input [4:0] rd_1,

    // physical source registers
    output reg [5:0] prs1_0,
    output reg [5:0] prs2_0,
    output reg [5:0] prs1_1,
    output reg [5:0] prs2_1,

    // physical destination registers
    output reg [5:0] prd_0,
    output reg [5:0] prd_1
);

//////////////////////////////////////////////////
// RAT TABLE & POINTER
//////////////////////////////////////////////////
reg [5:0] map_table [0:ARCH_REGS-1];
reg [5:0] free_ptr;
integer i;

//////////////////////////////////////////////////
// ALLOCATION LOGIC
//////////////////////////////////////////////////
// Evaluate whether each instruction actually requests a destination register
wire alloc0 = valid0 && (rd_0 != 0);
wire alloc1 = valid1 && (rd_1 != 0);
wire [1:0] alloc_count = alloc0 + alloc1;

//////////////////////////////////////////////////
// RESET + RENAME
//////////////////////////////////////////////////
always @(posedge clk or posedge reset) begin
    if(reset) begin
        // Initial mapping: xN → pN
        for(i=0; i<ARCH_REGS; i=i+1) begin
            map_table[i] <= i;
        end
        free_ptr <= ARCH_REGS;
        prd_0 <= 0;
        prd_1 <= 0;
    end 
    else begin
        // 1. Advance the pointer by the total number of registers allocated this cycle
        free_ptr <= free_ptr + alloc_count;

        // 2. Rename Instruction 0
        if(alloc0) begin
            prd_0 <= free_ptr;
            map_table[rd_0] <= free_ptr;
        end else begin
            prd_0 <= 0;
        end

        // 3. Rename Instruction 1 
        // We offset by 'alloc0' so it takes the NEXT available pointer if inst0 also allocated
        if(alloc1) begin
            prd_1 <= free_ptr + alloc0;
            map_table[rd_1] <= free_ptr + alloc0;
        end else begin
            prd_1 <= 0;
        end
    end
end

//////////////////////////////////////////////////
// SOURCE LOOKUP & INTRA-GROUP BYPASS
//////////////////////////////////////////////////
always @(*) begin
    // inst0 always looks up directly from the map table
    prs1_0 = map_table[rs1_0];
    prs2_0 = map_table[rs2_0];

    // inst1 MUST bypass the map table if it reads a register that inst0 is currently writing to
    prs1_1 = (alloc0 && (rs1_1 == rd_0) && (rs1_1 != 0)) ? free_ptr : map_table[rs1_1];
    prs2_1 = (alloc0 && (rs2_1 == rd_0) && (rs2_1 != 0)) ? free_ptr : map_table[rs2_1];
end

endmodule