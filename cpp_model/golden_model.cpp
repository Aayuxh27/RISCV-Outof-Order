// ============================================================================
// golden_model.cpp -- RV32I architectural reference implementation.
// ============================================================================
#include "golden_model.h"

#include <cstdio>
#include <fstream>
#include <sstream>

GoldenModel::GoldenModel(uint32_t reset_pc) : pc_(reset_pc), mem_(MEM_BYTES, 0) {
    for (auto& r : regs_) r = 0;
}

bool GoldenModel::load_hex(const std::string& path) {
    std::ifstream f(path);
    if (!f) return false;
    uint32_t addr = 0;
    std::string line;
    while (std::getline(f, line)) {
        // Strip comments / whitespace.
        auto h = line.find("//");
        if (h != std::string::npos) line = line.substr(0, h);
        std::istringstream ss(line);
        std::string tok;
        while (ss >> tok) {
            if (tok[0] == '@') {                 // address directive
                addr = std::stoul(tok.substr(1), nullptr, 16) * 4;
                continue;
            }
            uint32_t word = std::stoul(tok, nullptr, 16);
            if (addr + 3 < MEM_BYTES) write32(addr, word);
            addr += 4;
        }
    }
    return true;
}

// ----- Little-endian memory ---------------------------------------------------
uint8_t  GoldenModel::read8 (uint32_t a) const { return mem_[a & (MEM_BYTES - 1)]; }
uint16_t GoldenModel::read16(uint32_t a) const { return read8(a) | (read8(a + 1) << 8); }
uint32_t GoldenModel::read32(uint32_t a) const { return read16(a) | (read16(a + 2) << 16); }
void GoldenModel::write8 (uint32_t a, uint8_t v)  { mem_[a & (MEM_BYTES - 1)] = v; }
void GoldenModel::write16(uint32_t a, uint16_t v) { write8(a, v & 0xff); write8(a + 1, v >> 8); }
void GoldenModel::write32(uint32_t a, uint32_t v) { write16(a, v & 0xffff); write16(a + 2, v >> 16); }

void GoldenModel::set_reg(int i, uint32_t v) {
    if (i != 0) regs_[i & 31] = v;
}

static inline uint32_t sext(uint32_t v, int bits) {
    uint32_t m = 1u << (bits - 1);
    return (v ^ m) - m;
}

bool GoldenModel::step() {
    last_rd_    = -1;
    last_value_ = 0;

    const uint32_t inst   = read32(pc_);
    const uint32_t opcode = inst & 0x7f;
    const int      rd     = (inst >> 7)  & 0x1f;
    const int      rs1    = (inst >> 15) & 0x1f;
    const int      rs2    = (inst >> 20) & 0x1f;
    const uint32_t f3     = (inst >> 12) & 0x7;
    const uint32_t f7     = (inst >> 25) & 0x7f;
    const uint32_t a      = reg(rs1);
    const uint32_t b      = reg(rs2);

    const uint32_t imm_i  = sext(inst >> 20, 12);
    const uint32_t imm_s  = sext(((inst >> 25) << 5) | ((inst >> 7) & 0x1f), 12);
    const uint32_t imm_b  = sext((((inst >> 31) & 1) << 12) | (((inst >> 7) & 1) << 11) |
                                 (((inst >> 25) & 0x3f) << 5) | (((inst >> 8) & 0xf) << 1), 13);
    const uint32_t imm_u  = inst & 0xfffff000u;
    const uint32_t imm_j  = sext((((inst >> 31) & 1) << 20) | (((inst >> 12) & 0xff) << 12) |
                                 (((inst >> 20) & 1) << 11) | (((inst >> 21) & 0x3ff) << 1), 21);

    uint32_t next_pc = pc_ + 4;
    bool ok = true;

    auto writeback = [&](uint32_t v) { set_reg(rd, v); last_rd_ = rd; last_value_ = v; };

    switch (opcode) {
    case 0x37: writeback(imm_u); break;                       // LUI
    case 0x17: writeback(pc_ + imm_u); break;                 // AUIPC
    case 0x6f: writeback(pc_ + 4); next_pc = pc_ + imm_j; break;          // JAL
    case 0x67: writeback(pc_ + 4); next_pc = (a + imm_i) & ~1u; break;    // JALR
    case 0x63: {                                              // BRANCH
        bool taken = false;
        switch (f3) {
            case 0x0: taken = (a == b); break;                          // BEQ
            case 0x1: taken = (a != b); break;                          // BNE
            case 0x4: taken = ((int32_t)a <  (int32_t)b); break;        // BLT
            case 0x5: taken = ((int32_t)a >= (int32_t)b); break;        // BGE
            case 0x6: taken = (a <  b); break;                          // BLTU
            case 0x7: taken = (a >= b); break;                          // BGEU
            default: ok = false; break;
        }
        if (taken) next_pc = pc_ + imm_b;
        break;
    }
    case 0x03: {                                              // LOAD
        uint32_t addr = a + imm_i;
        switch (f3) {
            case 0x0: writeback(sext(read8(addr), 8)); break;           // LB
            case 0x1: writeback(sext(read16(addr), 16)); break;         // LH
            case 0x2: writeback(read32(addr)); break;                   // LW
            case 0x4: writeback(read8(addr)); break;                    // LBU
            case 0x5: writeback(read16(addr)); break;                   // LHU
            default: ok = false; break;
        }
        break;
    }
    case 0x23: {                                              // STORE
        uint32_t addr = a + imm_s;
        switch (f3) {
            case 0x0: write8(addr, b & 0xff); break;                    // SB
            case 0x1: write16(addr, b & 0xffff); break;                 // SH
            case 0x2: write32(addr, b); break;                          // SW
            default: ok = false; break;
        }
        break;
    }
    case 0x13: {                                              // OP-IMM
        uint32_t shamt = imm_i & 0x1f;
        switch (f3) {
            case 0x0: writeback(a + imm_i); break;                                  // ADDI
            case 0x2: writeback(((int32_t)a < (int32_t)imm_i) ? 1 : 0); break;      // SLTI
            case 0x3: writeback((a < imm_i) ? 1 : 0); break;                        // SLTIU
            case 0x4: writeback(a ^ imm_i); break;                                  // XORI
            case 0x6: writeback(a | imm_i); break;                                  // ORI
            case 0x7: writeback(a & imm_i); break;                                  // ANDI
            case 0x1: writeback(a << shamt); break;                                 // SLLI
            case 0x5: writeback((f7 & 0x20) ? (uint32_t)((int32_t)a >> shamt)
                                            : (a >> shamt)); break;                 // SRLI/SRAI
            default: ok = false; break;
        }
        break;
    }
    case 0x33: {                                              // OP
        switch ((f7 << 3) | f3) {
            case (0x00 << 3) | 0x0: writeback(a + b); break;                        // ADD
            case (0x20 << 3) | 0x0: writeback(a - b); break;                        // SUB
            case (0x00 << 3) | 0x1: writeback(a << (b & 0x1f)); break;              // SLL
            case (0x00 << 3) | 0x2: writeback(((int32_t)a < (int32_t)b) ? 1 : 0); break; // SLT
            case (0x00 << 3) | 0x3: writeback((a < b) ? 1 : 0); break;              // SLTU
            case (0x00 << 3) | 0x4: writeback(a ^ b); break;                        // XOR
            case (0x00 << 3) | 0x5: writeback(a >> (b & 0x1f)); break;              // SRL
            case (0x20 << 3) | 0x5: writeback((uint32_t)((int32_t)a >> (b & 0x1f))); break; // SRA
            case (0x00 << 3) | 0x6: writeback(a | b); break;                        // OR
            case (0x00 << 3) | 0x7: writeback(a & b); break;                        // AND
            default: ok = false; break;
        }
        break;
    }
    default: ok = false; break;
    }

    if (ok) pc_ = next_pc;
    return ok;
}
