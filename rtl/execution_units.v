module execution_units
(
    input clk,
    input reset,

    ////////////////////////////////////////////////
    // ISSUE SLOT 0
    ////////////////////////////////////////////////

    input issue0_valid,
    input [3:0] issue0_opcode,
    input [5:0] issue0_prs1,
    input [5:0] issue0_prs2,
    input [5:0] issue0_pd,

    input [31:0] rs1_val0,
    input [31:0] rs2_val0,

    ////////////////////////////////////////////////
    // ISSUE SLOT 1
    ////////////////////////////////////////////////

    input issue1_valid,
    input [3:0] issue1_opcode,
    input [5:0] issue1_prs1,
    input [5:0] issue1_prs2,
    input [5:0] issue1_pd,

    input [31:0] rs1_val1,
    input [31:0] rs2_val1,

    ////////////////////////////////////////////////
    // BROADCAST OUTPUT
    ////////////////////////////////////////////////

    output reg broadcast_valid,
    output reg [5:0] broadcast_tag,
    output reg [31:0] broadcast_value
);

reg [31:0] result;

//////////////////////////////////////////////////
// ALU EXECUTION
//////////////////////////////////////////////////

always @(*)
begin

    broadcast_valid = 0;
    broadcast_tag   = 0;
    broadcast_value = 0;

//////////////////////////////////////////////////
// ISSUE SLOT 0
//////////////////////////////////////////////////

if(issue0_valid)
begin

    case(issue0_opcode)

        0: result = rs1_val0 + rs2_val0;   // ADD
        1: result = rs1_val0 - rs2_val0;   // SUB

        2: result = rs1_val0 & rs2_val0;
        3: result = rs1_val0 | rs2_val0;
        4: result = rs1_val0 ^ rs2_val0;

        5: result = (rs1_val0 < rs2_val0);

        6: result = rs1_val0 << rs2_val0[4:0];
        7: result = rs1_val0 >> rs2_val0[4:0];
        8: result = $signed(rs1_val0) >>> rs2_val0[4:0];

        9: result = rs1_val0 + rs2_val0;   // ADDI
        10: result = (rs1_val0 < rs2_val0); // SLTI

        11: result = rs1_val0 & rs2_val0; // ANDI
        12: result = rs1_val0 | rs2_val0; // ORI
        13: result = rs1_val0 ^ rs2_val0; // XORI

        default: result = 0;

    endcase

    broadcast_valid = 1;
    broadcast_tag   = issue0_pd;
    broadcast_value = result;

end

//////////////////////////////////////////////////
// ISSUE SLOT 1 (if slot0 idle)
//////////////////////////////////////////////////

else if(issue1_valid)
begin

    case(issue1_opcode)

        0: result = rs1_val1 + rs2_val1;
        1: result = rs1_val1 - rs2_val1;

        2: result = rs1_val1 & rs2_val1;
        3: result = rs1_val1 | rs2_val1;
        4: result = rs1_val1 ^ rs2_val1;

        5: result = (rs1_val1 < rs2_val1);

        6: result = rs1_val1 << rs2_val1[4:0];
        7: result = rs1_val1 >> rs2_val1[4:0];
        8: result = $signed(rs1_val1) >>> rs2_val1[4:0];

        default: result = 0;

    endcase

    broadcast_valid = 1;
    broadcast_tag   = issue1_pd;
    broadcast_value = result;

end

end

endmodule
