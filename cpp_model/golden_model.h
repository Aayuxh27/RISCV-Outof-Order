// ============================================================================
// golden_model.h
// ----------------------------------------------------------------------------
// Architectural ("golden") reference model for RV32I.  It models *only* correct
// ISA behaviour -- no timing, no microarchitecture.  The DPI bridge steps it one
// instruction per RTL retirement and compares architectural state, so any
// divergence between the out-of-order core and the reference is caught exactly
// at the offending instruction.
// ============================================================================
#ifndef GOLDEN_MODEL_H
#define GOLDEN_MODEL_H

#include <cstdint>
#include <vector>
#include <string>

class GoldenModel {
public:
    static constexpr uint32_t MEM_BYTES = 1u << 16;  // 64 KiB, matches the RTL

    explicit GoldenModel(uint32_t reset_pc = 0);

    // Load a Verilog $readmemh-style image (one 32-bit word per line, hex).
    bool load_hex(const std::string& path);

    // Execute exactly one instruction at the current PC.
    // Returns false if the instruction is illegal/unsupported.
    bool step();

    // ----- State accessors ----------------------------------------------------
    uint32_t pc() const            { return pc_; }
    uint32_t reg(int i) const      { return (i == 0) ? 0u : regs_[i & 31]; }
    uint32_t inst_at(uint32_t a) const { return read32(a); }

    // The destination register and value produced by the *last* executed
    // instruction (valid only immediately after a successful step()).
    int      last_rd() const       { return last_rd_; }
    uint32_t last_value() const    { return last_value_; }
    bool     last_writes_reg() const { return last_rd_ > 0; }

private:
    uint32_t pc_;
    uint32_t regs_[32];
    std::vector<uint8_t> mem_;

    int      last_rd_ = -1;
    uint32_t last_value_ = 0;

    uint32_t read32(uint32_t a) const;
    uint16_t read16(uint32_t a) const;
    uint8_t  read8 (uint32_t a) const;
    void     write32(uint32_t a, uint32_t v);
    void     write16(uint32_t a, uint16_t v);
    void     write8 (uint32_t a, uint8_t v);

    void     set_reg(int i, uint32_t v);
};

#endif // GOLDEN_MODEL_H
