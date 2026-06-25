# RISC-V Out-of-Order RV32I Core

A graduate-level **out-of-order RV32I processor** in synthesizable SystemVerilog,
co-verified against a **C++ architectural golden model** through **DPI-C**, and
built and run entirely with **Verilator + GCC + Make** on Linux.

It implements the full RV32I integer ISA on a Tomasulo-style out-of-order
back-end: speculative fetch with a gshare/BTB branch predictor, register
renaming with a free list, a reorder buffer for precise state, reservation-
station wakeup/select, a unified physical register file, a load/store queue with
store-to-load forwarding, in-order commit with physical-register reclamation, and
single-cycle squash-at-retire misprediction recovery.

Every retired instruction is checked, in lockstep, against an independent C++
RV32I reference model — so correctness is *proven by co-simulation*, not eyeballed
off a waveform.

```
==================================================
 RISC-V OoO core -- run summary (predict)
==================================================
 status              : PASS
 cycles              : 627
 committed insts     : 605
 IPC                 : 0.965
 branches committed  : 201
 branch mispredicts  : 11
 branch accuracy     : 94.53%
 avg ROB occupancy   : 1.95 / 32
 ...
 golden mismatches   : 0
==================================================
```

## What it implements

* **ISA:** complete RV32I — arithmetic, logical, shifts, comparisons, LUI,
  AUIPC, all branches, JAL/JALR, and byte/half/word loads and stores. No FP, no
  compressed, no privileged ISA.
* **Out-of-order execution:** Tomasulo issue with CDB wakeup, oldest-ready
  select, out-of-order completion, in-order retirement.
* **Register renaming:** speculative + architectural RATs and a free-list bitmap;
  eliminates WAR/WAW hazards and reclaims physical registers at commit.
* **Branch prediction:** gshare PHT + BTB + speculative/architectural GHR, with
  prediction, training, and misprediction recovery, plus accuracy statistics.
* **Reorder buffer:** precise state and exceptions; in-order commit.
* **Load/store queue:** memory dependency tracking and store-to-load forwarding
  over a simplified flat memory model.
* **Recovery:** squash-at-retire — a single-cycle full flush + RAT/free-list
  restore + fetch redirect when a mispredicted control instruction commits.
* **Verification:** DPI-C golden-model co-simulation, directed tests, a random
  program generator, and CSV performance statistics.

## Repository layout

```
rtl/         SystemVerilog design (one module per file) + riscv_ooo_pkg.sv
cpp_model/   C++ RV32I architectural golden model
dpi/         DPI-C bridge (RTL commit -> golden-model check)
tb/          Verilator C++ simulation driver (clocking, halt, CSV export)
scripts/     self-contained RV32I assembler + random program generator
tests/asm/   directed test programs (assembled to tests/hex/ at build time)
docs/        architecture and verification documentation
legacy/      the earlier dual-issue Icarus design, kept for reference
build/        Verilator/g++ output (gitignored)
```

The RTL modules:

| File | Role |
|------|------|
| `riscv_ooo_pkg.sv`        | parameters, micro-op / ALU encodings, helpers |
| `fetch_unit.sv`           | PC, instruction memory, redirect/stall        |
| `branch_predictor.sv`     | gshare PHT + BTB + GHR, predict/train/recover  |
| `decode_unit.sv`          | full RV32I decode                              |
| `rename_unit.sv`          | RAT, free list, committed map, recovery        |
| `reservation_station.sv`  | allocate / wakeup / oldest-ready select        |
| `execute_unit.sv`         | ALU, branch/jump resolution, address generation|
| `physical_regfile.sv`     | physical register file (value + ready bit)     |
| `lsq.sv`                  | load/store queue, forwarding, data memory      |
| `reorder_buffer.sv`       | in-order ROB, precise state                    |
| `ooo_core.sv`             | top-level integration, commit, stats, DPI hook |

## Prerequisites

* Verilator (5.x), GCC/G++ (C++17), GNU Make, Python 3.

```bash
sudo apt-get install verilator g++ make python3   # Debian/Ubuntu
```

## Build and run

```bash
make sim                 # build the Verilator simulation (build/Vooo_sim)
make check               # build + assemble + run the directed test suite
make run TEST=predict    # run a single program with a full summary
make random              # 20 random programs, all golden-model checked
make help                # list all targets
```

Each run prints a summary and appends a row to a CSV (default `build/stats.csv`)
with IPC, branch accuracy, mispredictions, and ROB/RS/LQ/SQ occupancy.

> **Note on paths:** Verilator's generated build Makefile refuses to run in a
> directory whose path contains spaces. This project therefore uses Verilator
> only to *generate* C++ (`--cc`) and compiles it with `g++` using relative
> paths, so it builds correctly even under a path like `.../RISCV OOO/...`.

### Waveforms (optional)

```bash
make TRACE=1 run TEST=branches VCD=wave.vcd
gtkwave wave.vcd        # or: surfer wave.vcd
```

## Writing your own test

Tests are plain RV32I assembly (the bundled assembler supports the full base ISA
plus `nop`, `mv`, `li`, `j`, `jr`, `ret`, `beqz`, `bnez`). End a program with a
self-loop, which the core recognises as a halt:

```asm
        addi  x1, x0, 41
        addi  x1, x1, 1     # x1 = 42
done:
        j     done          # halt
```

Drop it in `tests/asm/mytest.s` and run `make run TEST=mytest`. The golden model
verifies every committed instruction automatically.

## Documentation

* [docs/architecture.md](docs/architecture.md) — pipeline, block diagram, module
  descriptions, renaming/recovery, LSQ, predictor, parameters.
* [docs/verification.md](docs/verification.md) — DPI-C methodology, test
  catalogue, random testing, statistics.

## Verification status

All directed tests and random programs pass with **zero** golden-model
mismatches, including an 8000-instruction random stress run (8002 instructions
retired at ~0.99 IPC), which confirms physical-register reclamation over far more
register writers than there are physical registers — the central limitation the
earlier monotonic-rename design could not cross.
