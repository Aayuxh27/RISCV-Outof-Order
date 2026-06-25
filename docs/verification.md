# Verification Methodology

The core is verified by **lockstep co-simulation against a C++ architectural
golden model** through SystemVerilog DPI-C, backed by directed and random tests.

## DPI-C co-simulation

At every retirement the commit stage in `ooo_core.sv` calls the imported DPI-C
function:

```systemverilog
import "DPI-C" function int gm_commit(
    input int pc, input int inst, input int rd, input int value, input int writes_reg);
```

The bridge (`dpi/dpi_bridge.cpp`) drives the golden model (`cpp_model/`):

1. **PC check** — the golden model's program-order PC must equal the committed
   PC (catches control-flow divergence and lost/extra instructions).
2. **Instruction check** — the committed instruction word must match what the
   model fetches at that PC (catches fetch/decode corruption and stray writes
   into the code region).
3. **Execute** — the model executes the same instruction architecturally.
4. **Write-back check** — if the instruction writes a register, the committed
   value must equal the model's result.

Any divergence prints a detailed report and returns non-zero, which the RTL
turns into a sticky `halt` with a mismatch code so the simulation terminates
immediately:

```
==================================================
 GOLDEN MODEL MISMATCH
==================================================
 Cycle    : 4134
 Commit # : 4097
 PC       : 0x00004000
 Inst     : 0x00021513
 Field    : x7
 RTL Value: 0x12345678
 Model    : 0x87654321
==================================================
```

Because the model is the reference, *any* well-formed program is a valid test:
the check verifies arithmetic, branches, jumps, loads/stores, renaming, ROB
operation and branch recovery all at once, at the exact instruction where
anything first goes wrong.

## Directed tests (`tests/asm/`)

| Test         | Exercises                                                        |
|--------------|-----------------------------------------------------------------|
| `arith.s`    | All ALU/ALU-imm ops, shifts, large immediates, dependency chains |
| `branches.s` | A counting loop: prediction, speculative rename, recovery       |
| `jumps.s`    | JAL / JALR, a call/return sequence, indirect jumps              |
| `loadstore.s`| LSQ, store-to-load forwarding, sub-word (B/H/W) and re-stores   |
| `memsum.s`   | Loads in a loop, load-after-store across forwarding and memory  |
| `predict.s`  | A long loop so gshare warms up (~95% accuracy)                  |

## Random tests

`scripts/gen_random.py` emits random but self-terminating programs (random ALU
dependency chains plus memory traffic to a scratch region clear of the code).
`make random` generates, assembles and runs a batch under the golden check.
This is the strongest test of the out-of-order machinery: free-list reclamation,
wakeup/select ordering, and the LSQ are all exercised with thousands of
instructions and arbitrary dependency patterns.

A representative result: an 8000-instruction random program retires 8002
instructions at ~0.99 IPC with zero golden-model mismatches — confirming, in
particular, that physical-register reclamation is correct over far more writers
than there are physical registers.

## Performance statistics

Every run writes a CSV row (default `build/stats.csv`) and prints a summary:
IPC, branch prediction accuracy, branch mispredictions, and average ROB / RS /
LQ / SQ occupancy, plus committed instructions and cycles. Occupancy averages
are accumulated every cycle in RTL and divided by the cycle count in the driver.

## Reproducing

```bash
make check                 # build + run the directed suite (golden-checked)
make random                # 20 random programs, golden-checked
make random RAND_N=2000    # longer random programs
make run TEST=predict      # a single test, with full summary
```
