// ============================================================================
// dpi_bridge.cpp
// ----------------------------------------------------------------------------
// Implements the DPI-C function the RTL calls at every retirement.  Each call
// re-executes the same instruction in the golden model and compares the
// resulting architectural state (PC + destination register) against what the
// out-of-order core committed.  Any divergence is reported in detail and flagged
// so the driver can terminate the simulation.
// ============================================================================
#include "dpi_bridge.h"
#include "golden_model.h"

#include <cstdio>
#include <cstdint>

// Verilator generates this header with the exact prototype for gm_commit.
#include "Vooo_core__Dpi.h"

uint64_t g_sim_cycle = 0;

namespace {
    GoldenModel* g_model        = nullptr;
    uint64_t     g_commits      = 0;
    uint64_t     g_mismatches   = 0;

    void report(const char* field, uint32_t pc, uint32_t inst,
                uint32_t rtl, uint32_t model) {
        std::printf("\n");
        std::printf("==================================================\n");
        std::printf(" GOLDEN MODEL MISMATCH\n");
        std::printf("==================================================\n");
        std::printf(" Cycle    : %llu\n", (unsigned long long)g_sim_cycle);
        std::printf(" Commit # : %llu\n", (unsigned long long)g_commits);
        std::printf(" PC       : 0x%08x\n", pc);
        std::printf(" Inst     : 0x%08x\n", inst);
        std::printf(" Field    : %s\n", field);
        std::printf(" RTL Value: 0x%08x\n", rtl);
        std::printf(" Model    : 0x%08x\n", model);
        std::printf("==================================================\n");
    }
}

bool gm_load_program(const char* path, uint32_t reset_pc) {
    delete g_model;
    g_model = new GoldenModel(reset_pc);
    return g_model->load_hex(path);
}

uint64_t gm_mismatch_count() { return g_mismatches; }
uint64_t gm_commit_count()   { return g_commits; }

// ----- DPI-C entry point (called from ooo_core at each commit) ---------------
extern "C" int gm_commit(int pc, int inst, int rd, int value, int writes_reg) {
    const uint32_t upc    = (uint32_t)pc;
    const uint32_t uinst  = (uint32_t)inst;
    const uint32_t uvalue = (uint32_t)value;

    if (!g_model) return 0;  // model not loaded; nothing to check

    g_commits++;

    // 1) Control-flow check: the program-order PC must match.
    if (g_model->pc() != upc) {
        report("PC", upc, uinst, upc, g_model->pc());
        g_mismatches++;
        return 1;
    }

    // 2) The retired instruction word should match the image the model fetches.
    if (g_model->inst_at(upc) != uinst) {
        report("INST", upc, uinst, uinst, g_model->inst_at(upc));
        g_mismatches++;
        return 1;
    }

    // 3) Execute the same instruction architecturally.
    if (!g_model->step()) {
        report("ILLEGAL", upc, uinst, uvalue, 0);
        g_mismatches++;
        return 1;
    }

    // 4) Register write-back check.
    if (writes_reg) {
        if (g_model->last_value() != uvalue) {
            char field[8];
            std::snprintf(field, sizeof(field), "x%d", rd);
            report(field, upc, uinst, uvalue, g_model->last_value());
            g_mismatches++;
            return 1;
        }
    }

    return 0;
}
