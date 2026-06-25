// ============================================================================
// decode_unit.sv
// ----------------------------------------------------------------------------
// Single-issue RV32I decoder.  Purely combinational: given a fetched
// instruction word and its PC, produce the micro-op the back-end executes.
//
// Unused source registers are forced to x0 on purpose.  x0 renames to physical
// register p0, which is hard-wired to zero and permanently "ready", so any uop
// that does not actually consume rs1 and/or rs2 rides the always-ready path for
// free instead of needing separate "this source is unused" plumbing through the
// reservation station.
// ============================================================================
import riscv_ooo_pkg::*;

module decode_unit (
    input  logic [31:0] inst,
    input  logic [31:0] pc,

    output logic        valid,        // legal, supported RV32I instruction
    output uop_e        uop_type,
    output alu_e        alu_op,

    output logic [4:0]  rs1,          // architectural source 1 (0 if unused)
    output logic [4:0]  rs2,          // architectural source 2 (0 if unused)
    output logic [4:0]  rd,           // architectural destination (0 if none)
    output logic        writes_reg,   // true => allocates a physical destination

    output logic [31:0] imm,
    output logic        uses_imm,     // ALU op2 = imm (OP-IMM), else op2 = rs2

    output logic [2:0]  br_cond,      // branch funct3
    output logic [2:0]  mem_func      // load/store funct3 (size + sign)
);

  // ----- Field extraction ---------------------------------------------------
  wire [6:0] opcode = inst[6:0];
  wire [4:0] a_rd   = inst[11:7];
  wire [2:0] funct3 = inst[14:12];
  wire [4:0] a_rs1  = inst[19:15];
  wire [4:0] a_rs2  = inst[24:20];
  wire [6:0] funct7 = inst[31:25];

  // ----- Immediate variants -------------------------------------------------
  wire [31:0] imm_i = {{20{inst[31]}}, inst[31:20]};
  wire [31:0] imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
  wire [31:0] imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
  wire [31:0] imm_u = {inst[31:12], 12'b0};
  wire [31:0] imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};

  // ----- ALU op decode for OP / OP-IMM --------------------------------------
  // Shared between register-register and register-immediate forms; the only
  // difference is SUB/SRA, which are gated by funct7[5] and only legal for the
  // register-register encoding (and for SRAI, where the same bit lives).
  function automatic alu_e dec_alu(input logic is_imm);
    case (funct3)
      3'b000: dec_alu = (!is_imm && funct7[5]) ? ALU_SUB : ALU_ADD; // ADD/SUB/ADDI
      3'b001: dec_alu = ALU_SLL;                                    // SLL/SLLI
      3'b010: dec_alu = ALU_SLT;                                    // SLT/SLTI
      3'b011: dec_alu = ALU_SLTU;                                   // SLTU/SLTIU
      3'b100: dec_alu = ALU_XOR;                                    // XOR/XORI
      3'b101: dec_alu = funct7[5] ? ALU_SRA : ALU_SRL;              // SRL/SRA/SRLI/SRAI
      3'b110: dec_alu = ALU_OR;                                     // OR/ORI
      3'b111: dec_alu = ALU_AND;                                    // AND/ANDI
      default: dec_alu = ALU_ADD;
    endcase
  endfunction

  always_comb begin
    // Defaults: an illegal/unsupported word becomes a harmless NOP bubble.
    valid      = 1'b1;
    uop_type   = UOP_NOP;
    alu_op     = ALU_ADD;
    rs1        = 5'd0;
    rs2        = 5'd0;
    rd         = 5'd0;
    imm        = 32'd0;
    uses_imm   = 1'b0;
    br_cond    = funct3;
    mem_func   = funct3;

    unique case (opcode)
      OPC_LUI: begin
        uop_type = UOP_LUI;
        rd       = a_rd;
        imm      = imm_u;
      end
      OPC_AUIPC: begin
        uop_type = UOP_AUIPC;
        rd       = a_rd;
        imm      = imm_u;
      end
      OPC_JAL: begin
        uop_type = UOP_JAL;
        rd       = a_rd;
        imm      = imm_j;
      end
      OPC_JALR: begin
        if (funct3 == 3'b000) begin
          uop_type = UOP_JALR;
          rd       = a_rd;
          rs1      = a_rs1;
          imm      = imm_i;
        end else begin
          valid = 1'b0;  // funct3 != 0 is reserved
        end
      end
      OPC_BRANCH: begin
        unique case (funct3)
          BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU: begin
            uop_type = UOP_BRANCH;
            rs1      = a_rs1;
            rs2      = a_rs2;
            imm      = imm_b;
            br_cond  = funct3;
          end
          default: valid = 1'b0;  // funct3 010/011 reserved
        endcase
      end
      OPC_LOAD: begin
        unique case (funct3)
          MEM_B, MEM_H, MEM_W, MEM_BU, MEM_HU: begin
            uop_type = UOP_LOAD;
            rd       = a_rd;
            rs1      = a_rs1;
            imm      = imm_i;
            uses_imm = 1'b1;      // address = rs1 + imm
            mem_func = funct3;
          end
          default: valid = 1'b0;
        endcase
      end
      OPC_STORE: begin
        unique case (funct3)
          MEM_B, MEM_H, MEM_W: begin
            uop_type = UOP_STORE;
            rs1      = a_rs1;     // base address
            rs2      = a_rs2;     // store data
            imm      = imm_s;
            uses_imm = 1'b1;
            mem_func = funct3;
          end
          default: valid = 1'b0;
        endcase
      end
      OPC_OP: begin
        // Only legal funct7 values are 0000000 and 0100000 (the latter only
        // for SUB/SRA).  Anything else is an unsupported extension.
        if (funct7 == 7'b0000000 ||
            (funct7 == 7'b0100000 && (funct3 == 3'b000 || funct3 == 3'b101))) begin
          uop_type = UOP_ALU;
          rd       = a_rd;
          rs1      = a_rs1;
          rs2      = a_rs2;
          alu_op   = dec_alu(1'b0);
        end else begin
          valid = 1'b0;
        end
      end
      OPC_OPIMM: begin
        uop_type = UOP_ALU;
        rd       = a_rd;
        rs1      = a_rs1;
        imm      = imm_i;
        uses_imm = 1'b1;
        alu_op   = dec_alu(1'b1);
        // Shift-immediate legality: shamt high bits must be clean.
        if (funct3 == 3'b001 && funct7 != 7'b0000000)
          valid = 1'b0;                                  // SLLI
        if (funct3 == 3'b101 && funct7 != 7'b0000000 && funct7 != 7'b0100000)
          valid = 1'b0;                                  // SRLI/SRAI
      end
      default: valid = 1'b0;
    endcase
  end

  // A uop writes a register if its type produces a result and rd != x0.
  wire produces_value = (uop_type == UOP_ALU)  || (uop_type == UOP_LOAD) ||
                        (uop_type == UOP_LUI)  || (uop_type == UOP_AUIPC) ||
                        (uop_type == UOP_JAL)  || (uop_type == UOP_JALR);
  assign writes_reg = valid && produces_value && (rd != 5'd0);

endmodule
