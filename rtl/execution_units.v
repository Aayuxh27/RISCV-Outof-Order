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

    output broadcast0_valid,
    output [5:0] broadcast0_tag,
    output [31:0] broadcast0_value,

    output broadcast1_valid,
    output [5:0] broadcast1_tag,
    output [31:0] broadcast1_value
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
// PORT 0
//////////////////////////////////////////////////

wire [31:0] op2_0 = issue0_use_imm ? issue0_imm : rs2_val0;

assign broadcast0_valid = issue0_valid;
assign broadcast0_tag   = issue0_pd;
assign broadcast0_value = alu_op(issue0_opcode, rs1_val0, op2_0);

//////////////////////////////////////////////////
// PORT 1
//////////////////////////////////////////////////

wire [31:0] op2_1 = issue1_use_imm ? issue1_imm : rs2_val1;

assign broadcast1_valid = issue1_valid;
assign broadcast1_tag   = issue1_pd;
assign broadcast1_value = alu_op(issue1_opcode, rs1_val1, op2_1);

endmodule
