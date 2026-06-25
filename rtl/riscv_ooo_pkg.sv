// ============================================================================
// riscv_ooo_pkg.sv
// ----------------------------------------------------------------------------
// Shared parameters and encodings for the single-issue out-of-order RV32I core.
//
// Everything here is plain SystemVerilog that Verilator accepts in --sv mode.
// The package only defines *constants and enums*; module ports are kept as
// discrete vectors (not packed structs) so the design is trivial to trace in
// a waveform and impossible to mis-wire by field order.
// ============================================================================
package riscv_ooo_pkg;

  // ----- Core widths --------------------------------------------------------
  localparam int XLEN        = 32;          // RV32
  localparam int ARCH_REGS   = 32;          // x0..x31
  localparam int PHYS_REGS   = 64;          // physical register file depth
  localparam int PREG_BITS   = 6;           // $clog2(PHYS_REGS)
  localparam int AREG_BITS   = 5;           // $clog2(ARCH_REGS)

  // ----- Structure sizes ----------------------------------------------------
  localparam int ROB_SIZE    = 32;          // reorder buffer entries
  localparam int ROB_BITS    = 5;           // $clog2(ROB_SIZE)
  localparam int RS_SIZE     = 16;          // reservation-station entries
  localparam int RS_BITS     = 4;
  localparam int LQ_SIZE     = 8;           // load-queue entries
  localparam int LQ_BITS     = 3;
  localparam int SQ_SIZE     = 8;           // store-queue entries
  localparam int SQ_BITS     = 3;

  // ----- Memory model -------------------------------------------------------
  // Byte-addressable, flat. IMEM and DMEM are the *same* address space so a
  // program and its data can share one image, exactly like the C++ golden
  // model.  Sized to 64 KiB which is plenty for course-scale test programs.
  localparam int MEM_BYTES   = 1 << 16;     // 64 KiB
  localparam int MEM_ADDR_BITS = 16;
  localparam int RESET_PC    = 32'h0000_0000;

  // ----- Branch-predictor sizes --------------------------------------------
  localparam int GHR_BITS    = 8;           // global history register width
  localparam int PHT_ENTRIES = 1 << GHR_BITS;
  localparam int BTB_ENTRIES = 64;
  localparam int BTB_IDX_BITS = 6;          // $clog2(BTB_ENTRIES)

  // ----- Micro-op type ------------------------------------------------------
  // One field that tells the back-end how to execute and commit a uop.
  typedef enum logic [3:0] {
    UOP_ALU   = 4'd0,   // reg/imm integer op, result = alu(rs1, op2)
    UOP_BRANCH= 4'd1,   // conditional branch
    UOP_JAL   = 4'd2,   // jump and link (rd = pc+4, target = pc+immJ)
    UOP_JALR  = 4'd3,   // jump and link register (target = (rs1+immI)&~1)
    UOP_LOAD  = 4'd4,   // memory load
    UOP_STORE = 4'd5,   // memory store
    UOP_LUI   = 4'd6,   // rd = immU
    UOP_AUIPC = 4'd7,   // rd = pc + immU
    UOP_NOP   = 4'd8    // bubble / illegal (never allocates a destination)
  } uop_e;

  // ----- ALU operation ------------------------------------------------------
  // Matches RV32I funct3/funct7 semantics for the integer ops.  Used by both
  // register-register (OP) and register-immediate (OP-IMM) instructions; the
  // immediate path simply substitutes op2.
  typedef enum logic [3:0] {
    ALU_ADD = 4'd0,
    ALU_SUB = 4'd1,
    ALU_SLL = 4'd2,
    ALU_SLT = 4'd3,
    ALU_SLTU= 4'd4,
    ALU_XOR = 4'd5,
    ALU_SRL = 4'd6,
    ALU_SRA = 4'd7,
    ALU_OR  = 4'd8,
    ALU_AND = 4'd9
  } alu_e;

  // ----- Branch condition (== RV32I funct3) ---------------------------------
  localparam logic [2:0] BR_BEQ  = 3'b000;
  localparam logic [2:0] BR_BNE  = 3'b001;
  localparam logic [2:0] BR_BLT  = 3'b100;
  localparam logic [2:0] BR_BGE  = 3'b101;
  localparam logic [2:0] BR_BLTU = 3'b110;
  localparam logic [2:0] BR_BGEU = 3'b111;

  // ----- Memory access funct3 (size + sign) ---------------------------------
  localparam logic [2:0] MEM_B  = 3'b000;   // LB / SB
  localparam logic [2:0] MEM_H  = 3'b001;   // LH / SH
  localparam logic [2:0] MEM_W  = 3'b010;   // LW / SW
  localparam logic [2:0] MEM_BU = 3'b100;   // LBU
  localparam logic [2:0] MEM_HU = 3'b101;   // LHU

  // ----- RV32I major opcodes ------------------------------------------------
  localparam logic [6:0] OPC_LUI    = 7'b0110111;
  localparam logic [6:0] OPC_AUIPC  = 7'b0010111;
  localparam logic [6:0] OPC_JAL    = 7'b1101111;
  localparam logic [6:0] OPC_JALR   = 7'b1100111;
  localparam logic [6:0] OPC_BRANCH = 7'b1100011;
  localparam logic [6:0] OPC_LOAD   = 7'b0000011;
  localparam logic [6:0] OPC_STORE  = 7'b0100011;
  localparam logic [6:0] OPC_OPIMM  = 7'b0010011;
  localparam logic [6:0] OPC_OP     = 7'b0110011;

  // The sentinel that halts simulation: `jal x0, 0` ("j .") = 0x0000006F.
  // The commit stage recognises it and asserts the top-level `halt` output.
  localparam logic [31:0] HALT_INST = 32'h0000_006F;

  // 2-bit saturating counter helpers for the gshare PHT.
  function automatic logic [1:0] ctr_inc(input logic [1:0] c);
    ctr_inc = (c == 2'b11) ? 2'b11 : (c + 2'b01);
  endfunction
  function automatic logic [1:0] ctr_dec(input logic [1:0] c);
    ctr_dec = (c == 2'b00) ? 2'b00 : (c - 2'b01);
  endfunction

endpackage
