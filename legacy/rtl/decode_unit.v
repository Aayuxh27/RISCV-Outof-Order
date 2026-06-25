module decode_unit
(
    input [31:0] pc,
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
    output reg [31:0] imm1,

    // Branches: condition code (= funct3, resolved by the comparator in
    // execution_units), the predicted-taken target, and the instruction's
    // own PC (needed to compute the fall-through address if the branch
    // turns out not-taken).
    output reg is_branch0,
    output reg [2:0] branch_cond0,
    output reg [31:0] branch_target0,
    output reg [31:0] branch_pc0,

    output reg is_branch1,
    output reg [2:0] branch_cond1,
    output reg [31:0] branch_target1,
    output reg [31:0] branch_pc1,

    // Loads/stores: address = rs1 + imm, riding the same use_imm/imm
    // path as an ALU immediate. Stores additionally need rs2 as a real
    // source register (the data to write), not an ALU operand.
    output reg is_load0,
    output reg is_store0,

    output reg is_load1,
    output reg is_store1
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

// B-type immediate is its own bit shuffle, split across the rd and
// funct7 fields specifically so a branch and an R-type instruction
// with the same value in those positions hash to different opcodes --
// imm[12]=inst[31], imm[11]=inst[7], imm[10:5]=inst[30:25],
// imm[4:1]=inst[11:8], imm[0]=0.
wire [31:0] imm_b0 = {{19{inst0[31]}}, inst0[31], inst0[7], inst0[30:25], inst0[11:8], 1'b0};
wire [31:0] imm_b1 = {{19{inst1[31]}}, inst1[31], inst1[7], inst1[30:25], inst1[11:8], 1'b0};

// S-type immediate (stores) is yet another bit shuffle -- split across
// the funct7 and rd field positions, neither of which a store actually
// has, so this is a third, independent overlap with those bits on top
// of the I-type and B-type ones already handled above.
wire [31:0] imm_s0 = {{20{inst0[31]}}, inst0[31:25], inst0[11:7]};
wire [31:0] imm_s1 = {{20{inst1[31]}}, inst1[31:25], inst1[11:7]};

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

is_branch0      = 0;
branch_cond0    = 3'd0;
branch_target0  = 32'd0;
branch_pc0      = pc;

is_load0  = 0;
is_store0 = 0;

if(op0 == 7'b0000011) begin

    // LW: address = rs1 + imm, same bit layout as an ALU immediate.
    // rs2 isn't a real field here either (same overlap as ALU I-type).
    rs2_0    = 5'd0;
    use_imm0 = 1;
    imm0     = imm_i0;
    is_load0 = 1;

    if(f3_0 != 3'b010)
        valid0 = 0; // only LW implemented -- see README limitations

end
else if(op0 == 7'b0100011) begin

    // SW: address = rs1 + imm (S-type immediate), rs2 = real data
    // operand. S-type has no rd field at all -- those bits are
    // imm[4:0] -- so rd must be forced to 0, same reasoning as branches.
    rd_0      = 5'd0;
    use_imm0  = 1;
    imm0      = imm_s0;
    is_store0 = 1;

    if(f3_0 != 3'b010)
        valid0 = 0; // only SW implemented -- see README limitations

end
else if(op0 == 7'b1100011) begin

    // B-type has no rd field at all -- inst[11:7] is actually
    // imm[4:1]/imm[11], so rd must be forced to 0 (no destination
    // tag is ever allocated for a branch) instead of being read as
    // a phantom register index.
    rd_0 = 5'd0;

    is_branch0     = 1;
    branch_cond0   = f3_0;
    branch_target0 = pc + imm_b0;

    case(f3_0)
        3'b000: ; // BEQ
        3'b001: ; // BNE
        3'b100: ; // BLT
        3'b101: ; // BGE
        3'b110: ; // BLTU
        3'b111: ; // BGEU
        default: valid0 = 0; // funct3 010/011 reserved, not in RV32I
    endcase

end
else if(op0 == 7'b0110011) begin

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

is_branch1      = 0;
branch_cond1    = 3'd0;
branch_target1  = 32'd0;
branch_pc1      = pc + 32'd4;

is_load1  = 0;
is_store1 = 0;

if(op1 == 7'b0000011) begin

    rs2_1    = 5'd0;
    use_imm1 = 1;
    imm1     = imm_i1;
    is_load1 = 1;

    if(f3_1 != 3'b010)
        valid1 = 0;

end
else if(op1 == 7'b0100011) begin

    rd_1      = 5'd0;
    use_imm1  = 1;
    imm1      = imm_s1;
    is_store1 = 1;

    if(f3_1 != 3'b010)
        valid1 = 0;

end
else if(op1 == 7'b1100011) begin

    rd_1 = 5'd0;

    is_branch1     = 1;
    branch_cond1   = f3_1;
    branch_target1 = (pc + 32'd4) + imm_b1;

    case(f3_1)
        3'b000: ;
        3'b001: ;
        3'b100: ;
        3'b101: ;
        3'b110: ;
        3'b111: ;
        default: valid1 = 0;
    endcase

end
else if(op1 == 7'b0110011) begin

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
