module fetch_unit(

    input clk,
    input reset,

    output reg [31:0] pc,
    output [31:0] inst0,
    output [31:0] inst1
);

//////////////////////////////////////////////////
// SIMPLE INSTRUCTION MEMORY
//////////////////////////////////////////////////

reg [31:0] memory [0:255];

initial begin

    // Example program

    memory[0] = 32'h00a00093; // addi x1,x0,10
    memory[1] = 32'h01400113; // addi x2,x0,20
    memory[2] = 32'h002081b3; // add x3,x1,x2
    memory[3] = 32'h40118233; // sub x4,x3,x1
    memory[4] = 32'h002182b3; // add x5,x3,x2
    memory[5] = 32'h00320333; // add x6,x4,x3
    memory[6] = 32'h004303b3; // add x7,x6,x4

end

//////////////////////////////////////////////////
// PC UPDATE
//////////////////////////////////////////////////

always @(posedge clk or posedge reset)
begin

    if(reset)
        pc <= 0;
    else
        pc <= pc + 8;   // 2 instructions per cycle

end

//////////////////////////////////////////////////
// 2-WIDE FETCH
//////////////////////////////////////////////////

assign inst0 = memory[pc[9:2]];
assign inst1 = memory[pc[9:2] + 1];

endmodule
