module execution_units
(
    input clk,
    input reset,

    ////////////////////////////////////////////////
    // ISSUE SLOT 0
    ////////////////////////////////////////////////

    input issue0_valid,
    input [3:0] issue0_opcode,
    input [5:0] issue0_pd,
    input issue0_use_imm,
    input [31:0] issue0_imm,
    input issue0_is_branch,
    input issue0_predicted_taken,
    input [2:0] issue0_branch_cond,
    input [31:0] issue0_branch_target,
    input [31:0] issue0_branch_pc,

    input [31:0] rs1_val0,
    input [31:0] rs2_val0,

    ////////////////////////////////////////////////
    // ISSUE SLOT 1
    ////////////////////////////////////////////////

    input issue1_valid,
    input [3:0] issue1_opcode,
    input [5:0] issue1_pd,
    input issue1_use_imm,
    input [31:0] issue1_imm,
    input issue1_is_branch,
    input issue1_predicted_taken,
    input [2:0] issue1_branch_cond,
    input [31:0] issue1_branch_target,
    input [31:0] issue1_branch_pc,

    input [31:0] rs1_val1,
    input [31:0] rs2_val1,

    ////////////////////////////////////////////////
    // BROADCAST OUTPUT (2 INDEPENDENT CDB PORTS)
    ////////////////////////////////////////////////
    // Two ports because two instructions can be issued in the same
    // cycle (scheduler.v picks the two oldest ready entries). A single
    // shared ALU/broadcast port would force one of those two to be
    // silently dropped: the issue queue would still remove both entries
    // that cycle (scheduler said both issued), but only one result would
    // ever be computed or written back, permanently losing the other.
    // A branch never drives these -- it has no destination register.

    output broadcast0_valid,
    output [5:0] broadcast0_tag,
    output [31:0] broadcast0_value,

    output broadcast1_valid,
    output [5:0] broadcast1_tag,
    output [31:0] broadcast1_value,

    ////////////////////////////////////////////////
    // BRANCH RESOLUTION
    ////////////////////////////////////////////////
    // At most one branch can be outstanding at a time (rat.v's single
    // checkpoint), so combining the two ports' resolutions into one
    // bundle here -- rather than exposing 16 separate signals for
    // ooo_top to arbitrate between -- is safe, not just convenient.

    output branch_resolved_valid,
    output branch_mispredicted,
    output [31:0] branch_correct_target,
    output [31:0] branch_update_pc,
    output branch_update_taken
);

//////////////////////////////////////////////////
// SHARED ALU (ONE DEFINITION, TWO INSTANCES)
//////////////////////////////////////////////////
// Factored into a function so the two execution ports can't drift out
// of sync with each other as opcodes are added/changed.

function [31:0] alu_op;
    input [3:0] opcode;
    input [31:0] op1;
    input [31:0] op2;
    begin
        case(opcode)

            0:  alu_op = op1 + op2;                     // ADD
            1:  alu_op = op1 - op2;                     // SUB

            2:  alu_op = op1 & op2;                     // AND
            3:  alu_op = op1 | op2;                     // OR
            4:  alu_op = op1 ^ op2;                     // XOR

            5:  alu_op = (op1 < op2) ? 32'd1 : 32'd0;   // SLT

            6:  alu_op = op1 << op2[4:0];                  // SLL
            7:  alu_op = op1 >> op2[4:0];                  // SRL
            8:  alu_op = $signed(op1) >>> op2[4:0];        // SRA

            9:  alu_op = op1 + op2;                     // ADDI
            10: alu_op = (op1 < op2) ? 32'd1 : 32'd0;   // SLTI

            11: alu_op = op1 & op2;                     // ANDI
            12: alu_op = op1 | op2;                     // ORI
            13: alu_op = op1 ^ op2;                     // XORI

            default: alu_op = 32'd0;

        endcase
    end
endfunction

//////////////////////////////////////////////////
// SHARED BRANCH COMPARATOR (ONE DEFINITION, TWO INSTANCES)
//////////////////////////////////////////////////
// cond is funct3 straight from the encoding -- 010/011 are reserved
// and never decoded as is_branch in the first place, so they can't
// reach here.

function branch_taken;
    input [2:0] cond;
    input [31:0] op1;
    input [31:0] op2;
    begin
        case(cond)
            3'b000: branch_taken = (op1 == op2);                    // BEQ
            3'b001: branch_taken = (op1 != op2);                    // BNE
            3'b100: branch_taken = ($signed(op1) <  $signed(op2));  // BLT
            3'b101: branch_taken = ($signed(op1) >= $signed(op2));  // BGE
            3'b110: branch_taken = (op1 <  op2);                    // BLTU
            3'b111: branch_taken = (op1 >= op2);                    // BGEU
            default: branch_taken = 1'b0;
        endcase
    end
endfunction

//////////////////////////////////////////////////
// PORT 0
//////////////////////////////////////////////////

wire [31:0] op2_0 = issue0_use_imm ? issue0_imm : rs2_val0;

assign broadcast0_valid = issue0_valid && !issue0_is_branch;
assign broadcast0_tag   = issue0_pd;
assign broadcast0_value = alu_op(issue0_opcode, rs1_val0, op2_0);

wire port0_resolved   = issue0_valid && issue0_is_branch;
wire actual_taken0    = branch_taken(issue0_branch_cond, rs1_val0, rs2_val0);
wire mispredicted0    = actual_taken0 != issue0_predicted_taken;
wire [31:0] correct_target0 = actual_taken0 ? issue0_branch_target : (issue0_branch_pc + 32'd4);

//////////////////////////////////////////////////
// PORT 1
//////////////////////////////////////////////////

wire [31:0] op2_1 = issue1_use_imm ? issue1_imm : rs2_val1;

assign broadcast1_valid = issue1_valid && !issue1_is_branch;
assign broadcast1_tag   = issue1_pd;
assign broadcast1_value = alu_op(issue1_opcode, rs1_val1, op2_1);

wire port1_resolved   = issue1_valid && issue1_is_branch;
wire actual_taken1    = branch_taken(issue1_branch_cond, rs1_val1, rs2_val1);
wire mispredicted1    = actual_taken1 != issue1_predicted_taken;
wire [31:0] correct_target1 = actual_taken1 ? issue1_branch_target : (issue1_branch_pc + 32'd4);

//////////////////////////////////////////////////
// COMBINED RESOLUTION (PORT 0 PRIORITY, SEE PORT LIST COMMENT)
//////////////////////////////////////////////////

assign branch_resolved_valid  = port0_resolved || port1_resolved;
assign branch_mispredicted    = port0_resolved ? mispredicted0 : mispredicted1;
assign branch_correct_target  = port0_resolved ? correct_target0 : correct_target1;
assign branch_update_pc       = port0_resolved ? issue0_branch_pc : issue1_branch_pc;
assign branch_update_taken    = port0_resolved ? actual_taken0 : actual_taken1;

endmodule
