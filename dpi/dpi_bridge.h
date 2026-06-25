// ============================================================================
// dpi_bridge.h
// ----------------------------------------------------------------------------
// Glue between the Verilated RTL (via DPI-C) and the C++ golden model, plus a
// few helpers the simulation driver uses to load the program and read results.
// ============================================================================
#ifndef DPI_BRIDGE_H
#define DPI_BRIDGE_H

#include <cstdint>

// Set by the simulation driver every cycle so mismatch reports can name a cycle.
extern uint64_t g_sim_cycle;

// Called by the driver before simulation starts.
bool     gm_load_program(const char* path, uint32_t reset_pc);
uint64_t gm_mismatch_count();
uint64_t gm_commit_count();

#endif // DPI_BRIDGE_H
