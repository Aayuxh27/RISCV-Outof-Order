// ============================================================================
// execute_unit.sv
// ----------------------------------------------------------------------------
// Combinational single-cycle execution for the issued uop: integer ALU, the
// LUI/AUIPC/JAL/JALR result paths, conditional-branch resolution, and the load/
// store address generator.  Loads only produce their *address* here; their data
// is produced later by the LSQ (phase B).
// ============================================================================
import riscv_ooo_pkg::*;

module execute_unit (
    input  uop_e        uop,
    input  alu_e        alu_op,
    input  logic [2:0]  br_cond,
    input  logic        uses_imm,
    input  logic [31:0] imm,
    input  logic [31:0] pc,
    input  logic [31:0] rs1_val,
    input  logic [31:0] rs2_val,
    input  logic        pred_taken,
    input  logic [31:0] pred_target,

    output logic [31:0] result,        // value for a register-writing uop
    output logic        produces_value, // drives the CDB (excludes loads/stores/branches)
    output logic [31:0] agu_addr,       // rs1 + imm  (loads/stores)
    output logic [31:0] store_data,     // rs2        (stores)

    output logic        is_control,
    output logic        is_cond,
    output logic        actual_taken,
    output logic [31:0] actual_target,
    output logic        mispredicted
);

  // ----- Integer ALU --------------------------------------------------------
  function automatic logic [31:0] alu(input alu_e op, input logic [31:0] a, input logic [31:0] b);
    case (op)
      ALU_ADD : alu = a + b;
      ALU_SUB : alu = a - b;
      ALU_SLL : alu = a << b[4:0];
      ALU_SLT : alu = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
      ALU_SLTU: alu = (a < b) ? 32'd1 : 32'd0;
      ALU_XOR : alu = a ^ b;
      ALU_SRL : alu = a >> b[4:0];
      ALU_SRA : alu = $signed(a) >>> b[4:0];
      ALU_OR  : alu = a | b;
      ALU_AND : alu = a & b;
      default : alu = 32'd0;
    endcase
  endfunction

  function automatic logic branch_cond(input logic [2:0] c, input logic [31:0] a, input logic [31:0] b);
    case (c)
      BR_BEQ : branch_cond = (a == b);
      BR_BNE : branch_cond = (a != b);
      BR_BLT : branch_cond = ($signed(a) <  $signed(b));
      BR_BGE : branch_cond = ($signed(a) >= $signed(b));
      BR_BLTU: branch_cond = (a <  b);
      BR_BGEU: branch_cond = (a >= b);
      default: branch_cond = 1'b0;
    endcase
  endfunction

  wire [31:0] op2 = uses_imm ? imm : rs2_val;

  assign agu_addr   = rs1_val + imm;
  assign store_data = rs2_val;

  always_comb begin
    result         = 32'd0;
    produces_value = 1'b0;
    is_control     = 1'b0;
    is_cond        = 1'b0;
    actual_taken   = 1'b0;
    actual_target  = pc + 32'd4;

    unique case (uop)
      UOP_ALU: begin
        result = alu(alu_op, rs1_val, op2);
        produces_value = 1'b1;
      end
      UOP_LUI: begin
        result = imm;
        produces_value = 1'b1;
      end
      UOP_AUIPC: begin
        result = pc + imm;
        produces_value = 1'b1;
      end
      UOP_JAL: begin
        result        = pc + 32'd4;
        produces_value= 1'b1;
        is_control    = 1'b1;
        actual_taken  = 1'b1;
        actual_target = pc + imm;
      end
      UOP_JALR: begin
        result        = pc + 32'd4;
        produces_value= 1'b1;
        is_control    = 1'b1;
        actual_taken  = 1'b1;
        actual_target = (rs1_val + imm) & ~32'd1;
      end
      UOP_BRANCH: begin
        is_control    = 1'b1;
        is_cond       = 1'b1;
        actual_taken  = branch_cond(br_cond, rs1_val, rs2_val);
        actual_target = actual_taken ? (pc + imm) : (pc + 32'd4);
      end
      default: ; // LOAD / STORE / NOP: no register result here
    endcase
  end

  // A control transfer is mispredicted if its direction differs from the
  // prediction, or (when taken) it goes somewhere other than predicted.
  assign mispredicted = is_control &&
        ((actual_taken != pred_taken) ||
         (actual_taken && (actual_target != pred_target)));

endmodule
