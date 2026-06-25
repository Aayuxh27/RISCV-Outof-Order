// ============================================================================
// sim_main.cpp
// ----------------------------------------------------------------------------
// Verilator simulation driver for the out-of-order RV32I core.
//
//   * loads the program image into both the RTL (+MEM=, via $readmemh) and the
//     C++ golden model (so the DPI co-simulation has a reference),
//   * clocks the design until it halts (normal "j ." termination, an
//     architectural mismatch, or an illegal-instruction trap),
//   * prints a human-readable summary and writes a CSV row of performance stats.
//
// Plusargs:
//   +MEM=<file>       program hex image (required)
//   +CSV=<file>       stats CSV output       (default: build/stats.csv)
//   +MAXCYCLES=<n>    safety timeout         (default: 500000)
//   +NAME=<str>       label used in the CSV  (default: derived from +MEM)
//   +VCD=<file>       waveform dump          (requires a --trace build)
// ============================================================================
#include "Vooo_core.h"
#include "verilated.h"
#include "dpi_bridge.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <fstream>

#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

static constexpr uint32_t RESET_PC = 0;

static std::string plusarg(int argc, char** argv, const char* key, const char* dflt) {
    std::string pfx = std::string("+") + key + "=";
    for (int i = 1; i < argc; i++)
        if (std::strncmp(argv[i], pfx.c_str(), pfx.size()) == 0)
            return std::string(argv[i] + pfx.size());
    return dflt;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);  // let the RTL see +MEM= for $readmemh

    const std::string mem  = plusarg(argc, argv, "MEM", "");
    const std::string csv  = plusarg(argc, argv, "CSV", "build/stats.csv");
    const std::string vcd  = plusarg(argc, argv, "VCD", "");
    const uint64_t max_cyc = std::stoull(plusarg(argc, argv, "MAXCYCLES", "500000"));
    std::string name       = plusarg(argc, argv, "NAME", "");
    if (name.empty()) {
        name = mem;
        auto s = name.find_last_of('/'); if (s != std::string::npos) name = name.substr(s + 1);
        auto d = name.find_last_of('.'); if (d != std::string::npos) name = name.substr(0, d);
    }

    if (mem.empty()) {
        std::fprintf(stderr, "error: +MEM=<hexfile> is required\n");
        return 2;
    }
    if (!gm_load_program(mem.c_str(), RESET_PC)) {
        std::fprintf(stderr, "error: could not load golden image '%s'\n", mem.c_str());
        return 2;
    }

    auto* top = new Vooo_core;

#if VM_TRACE
    VerilatedVcdC* tfp = nullptr;
    if (!vcd.empty()) {
        Verilated::traceEverOn(true);
        tfp = new VerilatedVcdC;
        top->trace(tfp, 99);
        tfp->open(vcd.c_str());
    }
#endif

    auto tick = [&](uint64_t cyc) {
        g_sim_cycle = cyc;
        top->clk = 0; top->eval();
#if VM_TRACE
        if (tfp) tfp->dump((vluint64_t)(cyc * 2));
#endif
        top->clk = 1; top->eval();   // posedge: commit + DPI check happen here
#if VM_TRACE
        if (tfp) tfp->dump((vluint64_t)(cyc * 2 + 1));
#endif
    };

    // Reset.
    top->reset = 1;
    for (uint64_t c = 0; c < 4; c++) tick(c);
    top->reset = 0;

    uint64_t cyc = 4;
    bool timed_out = false;
    while (!top->halt) {
        if (cyc >= max_cyc) { timed_out = true; break; }
        tick(cyc++);
    }

#if VM_TRACE
    if (tfp) { tfp->close(); delete tfp; }
#endif

    // ----- Results ----------------------------------------------------------
    const uint64_t cycles   = top->stat_cycles;
    const uint64_t commits  = top->stat_committed;
    const uint32_t bp_tot   = top->stat_bp_total;
    const uint32_t bp_mis   = top->stat_bp_mispred;
    const double   ipc      = cycles ? (double)commits / cycles : 0.0;
    const double   bp_acc   = bp_tot ? 100.0 * (bp_tot - bp_mis) / bp_tot : 0.0;
    const double   rob_occ  = cycles ? (double)top->stat_rob_occ_sum / cycles : 0.0;
    const double   rs_occ   = cycles ? (double)top->stat_rs_occ_sum  / cycles : 0.0;
    const double   lq_occ   = cycles ? (double)top->stat_lq_occ_sum  / cycles : 0.0;
    const double   sq_occ   = cycles ? (double)top->stat_sq_occ_sum  / cycles : 0.0;

    const char* status;
    if (timed_out)               status = "TIMEOUT";
    else switch (top->halt_code) {
        case 1:  status = "PASS";        break;   // normal j . termination
        case 2:  status = "TRAP";        break;   // illegal instruction
        case 3:  status = "MISMATCH";    break;   // golden divergence
        default: status = "UNKNOWN";     break;
    }

    std::printf("\n==================================================\n");
    std::printf(" RISC-V OoO core -- run summary (%s)\n", name.c_str());
    std::printf("==================================================\n");
    std::printf(" status              : %s\n", status);
    std::printf(" cycles              : %llu\n", (unsigned long long)cycles);
    std::printf(" committed insts     : %llu\n", (unsigned long long)commits);
    std::printf(" IPC                 : %.3f\n", ipc);
    std::printf(" branches committed  : %u\n", bp_tot);
    std::printf(" branch mispredicts  : %u\n", bp_mis);
    std::printf(" branch accuracy     : %.2f%%\n", bp_acc);
    std::printf(" avg ROB occupancy   : %.2f / %d\n", rob_occ, 32);
    std::printf(" avg RS  occupancy   : %.2f / %d\n", rs_occ, 16);
    std::printf(" avg LQ  occupancy   : %.2f / %d\n", lq_occ, 8);
    std::printf(" avg SQ  occupancy   : %.2f / %d\n", sq_occ, 8);
    std::printf(" golden mismatches   : %llu\n", (unsigned long long)gm_mismatch_count());
    std::printf("==================================================\n");

    // ----- CSV --------------------------------------------------------------
    {
        bool exists = false;
        { std::ifstream f(csv); exists = f.good(); }
        std::ofstream f(csv, std::ios::app);
        if (f) {
            if (!exists)
                f << "name,status,cycles,committed,ipc,branches,mispredicts,"
                     "bp_accuracy,avg_rob,avg_rs,avg_lq,avg_sq,mismatches\n";
            f << name << ',' << status << ',' << cycles << ',' << commits << ','
              << ipc << ',' << bp_tot << ',' << bp_mis << ',' << bp_acc << ','
              << rob_occ << ',' << rs_occ << ',' << lq_occ << ',' << sq_occ << ','
              << gm_mismatch_count() << '\n';
        }
    }

    int rc = (std::strcmp(status, "PASS") == 0) ? 0 : 1;
    top->final();
    delete top;
    return rc;
}
