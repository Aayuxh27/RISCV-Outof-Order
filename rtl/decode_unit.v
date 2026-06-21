module decode_unit
(
    input [31:0] inst0,
    input [31:0] inst1,

    output reg valid0,
    output reg valid1,

    output reg [3:0] opcode0,
    output reg [3:0] opcode1,

    output reg [4:0] rs1_0,
    output reg [4:0] rs2_0,
    output reg [4:0] rd_0,

    output reg [4:0] rs1_1,
    output reg [4:0] rs2_1,
    output reg [4:0] rd_1,

    // I-type immediate (sign-extended) and a flag telling downstream
    // stages to use it instead of the rs2 operand value
    output reg use_imm0,
    output reg [31:0] imm0,

    output reg use_imm1,
    output reg [31:0] imm1
);

//////////////////////////////////////////////////
// FIELD EXTRACTION
//////////////////////////////////////////////////

wire [6:0] op0 = inst0[6:0];
wire [6:0] op1 = inst1[6:0];

wire [2:0] f3_0 = inst0[14:12];
wire [2:0] f3_1 = inst1[14:12];

wire [6:0] f7_0 = inst0[31:25];
wire [6:0] f7_1 = inst1[31:25];

// I-type immediate lives in bits [31:20] and must be sign-extended,
// not read as a second register index (that was the original bug:
// rs2[24:20] and imm[11:5] physically overlap in the encoding).
wire [31:0] imm_i0 = {{20{inst0[31]}}, inst0[31:20]};
wire [31:0] imm_i1 = {{20{inst1[31]}}, inst1[31:20]};

//////////////////////////////////////////////////
// DECODE LOGIC
//////////////////////////////////////////////////

always @(*) begin

//////////////////////////////////////////////////
// INSTRUCTION 0
//////////////////////////////////////////////////

valid0 = 1;

rs1_0 = inst0[19:15];
rs2_0 = inst0[24:20];
rd_0  = inst0[11:7];

opcode0  = 0;
use_imm0 = 0;
imm0     = 32'd0;

if(op0 == 7'b0110011) begin

    case({f7_0,f3_0})

        10'b0000000_000: opcode0 = 0; // ADD
        10'b0100000_000: opcode0 = 1; // SUB
        10'b0000000_111: opcode0 = 2; // AND
        10'b0000000_110: opcode0 = 3; // OR
        10'b0000000_100: opcode0 = 4; // XOR
        10'b0000000_010: opcode0 = 5; // SLT
        10'b0000000_001: opcode0 = 6; // SLL
        10'b0000000_101: opcode0 = 7; // SRL
        10'b0100000_101: opcode0 = 8; // SRA

        default: valid0 = 0;

    endcase

end
else if(op0 == 7'b0010011) begin

    // I-type: rs2_0 does not name a real register here (those bits
    // are imm[4:0]), so force it to x0 -- it renames to p0, which is
    // always ready/zero -- and route the real operand through imm0.
    rs2_0    = 5'd0;
    use_imm0 = 1;
    imm0     = imm_i0;

    case(f3_0)

        3'b000: opcode0 = 9;  // ADDI
        3'b010: opcode0 = 10; // SLTI
        3'b111: opcode0 = 11; // ANDI
        3'b110: opcode0 = 12; // ORI
        3'b100: opcode0 = 13; // XORI

        default: valid0 = 0;

    endcase

end
else begin
    valid0 = 0;
end


//////////////////////////////////////////////////
// INSTRUCTION 1
//////////////////////////////////////////////////

valid1 = 1;

rs1_1 = inst1[19:15];
rs2_1 = inst1[24:20];
rd_1  = inst1[11:7];

opcode1  = 0;
use_imm1 = 0;
imm1     = 32'd0;

if(op1 == 7'b0110011) begin

    case({f7_1,f3_1})

        10'b0000000_000: opcode1 = 0;
        10'b0100000_000: opcode1 = 1;
        10'b0000000_111: opcode1 = 2;
        10'b0000000_110: opcode1 = 3;
        10'b0000000_100: opcode1 = 4;
        10'b0000000_010: opcode1 = 5;
        10'b0000000_001: opcode1 = 6;
        10'b0000000_101: opcode1 = 7;
        10'b0100000_101: opcode1 = 8;

        default: valid1 = 0;

    endcase

end
else if(op1 == 7'b0010011) begin

    rs2_1    = 5'd0;
    use_imm1 = 1;
    imm1     = imm_i1;

    case(f3_1)

        3'b000: opcode1 = 9;
        3'b010: opcode1 = 10;
        3'b111: opcode1 = 11;
        3'b110: opcode1 = 12;
        3'b100: opcode1 = 13;

        default: valid1 = 0;

    endcase

end
else begin
    valid1 = 0;
end

end

endmodule
