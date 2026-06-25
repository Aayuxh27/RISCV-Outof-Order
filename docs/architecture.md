# Architecture Overview

A single-issue, out-of-order RV32I core implemented in synthesizable
SystemVerilog and verified against a C++ architectural golden model through
DPI-C co-simulation. The design follows classic Tomasulo principles with a
reorder buffer for precise state, a unified physical register file, register
renaming with a free list, a gshare/BTB branch predictor with speculative
execution, and a load/store queue with store-to-load forwarding.

It is deliberately **single-issue**: one instruction is fetched, decoded,
renamed and dispatched per cycle, but the back-end executes and completes
instructions *out of order* and retires them *in order*. Single-issue removes a
large class of same-cycle race conditions that a superscalar front-end forces,
leaving the actual out-of-order concepts — renaming, wakeup/select, speculative
recovery, memory disambiguation, precise commit — clean and easy to follow.

## Block diagram

```
                         +------------------------+
            redirect <---|  branch_predictor      |<--- train (commit)
            predict  --->|  gshare PHT + BTB + GHR |
                         +-----------+------------+
                                     |
   +-----------+   +-----------+   +-v---------+   +-------------+
   |  fetch    |-->|  decode   |-->|  rename   |-->|  dispatch   |
   |  PC,IMEM  |   |  RV32I    |   | RAT+free  |   | (handshake) |
   +-----------+   +-----------+   |  list     |   +------+------+
        ^                          +-----------+          |
        |  redirect_pc / stall                            | allocate
        |                                                 v
        |        +----------------------------------------+-----------------+
        |        |                        ROB (in order)                    |
        |        +----+--------------------------+------------------+-------+
        |             | alloc                    | complete         | commit
        |             v                          |                  v
        |     +---------------+   issue   +-------+------+    +-------------+
        |     | reservation   |---------->|  execute     |    |  commit /   |
        |     | station       |  oldest  |  ALU + branch |    |  retire     |
        |     | (wakeup/sel)  |  ready    |  + AGU        |    |  + DPI check|
        |     +-------+-------+           +---+------+----+    +------+------+
        |             ^   CDB (tag,value)     |      | addr/data     |
        |             +-----------------------+      v               |
        |     +-----------------+          +-----------------+       |
        |     | physical regfile|<---CDB---| load/store queue|<------+ commit store
        |     | value + ready   |          | + data memory   |  (writes memory)
        |     +-----------------+          | + forwarding    |
        +--------------------------------- +-----------------+
                 flush (squash-at-retire) on committed misprediction
```

## Pipeline stages

1. **Fetch** (`fetch_unit.sv`) — a PC, a read-only instruction memory loaded
   from the program image, and the redirect/stall logic. Next PC is the
   misprediction redirect target, a hold (on back-end stall), or the predicted
   next PC.
2. **Predict** (`branch_predictor.sv`) — gshare conditional predictor (PHT
   indexed by `(pc>>2) XOR GHR`) plus a BTB providing the target and a
   conditional/unconditional bit. A speculative GHR advances at fetch and is
   restored from the architectural GHR on a flush. The exact PHT index used is
   carried to commit so the same entry is trained.
3. **Decode** (`decode_unit.sv`) — full RV32I decode into a micro-op. Unused
   source registers are forced to x0 so they ride the always-ready path.
4. **Rename** (`rename_unit.sv`) — speculative RAT, free-list bitmap, and a
   committed (architectural) RAT. Each writer gets a fresh physical register,
   eliminating WAR/WAW hazards; RAW hazards are tracked by the producing
   physical tag.
5. **Dispatch** — top-level handshake that allocates a ROB entry, a reservation
   station entry, and (for memory ops) a load- or store-queue entry, stalling
   the front-end if any structure is full or no physical register is free.
6. **Issue** (`reservation_station.sv`) — the oldest entry with both operands
   ready is selected and issued; wakeup is driven by the common data bus.
7. **Execute** (`execute_unit.sv`) — single-cycle integer ALU, the
   LUI/AUIPC/JAL/JALR result paths, conditional-branch resolution, and the
   load/store address generator.
8. **Memory** (`lsq.sv`) — stores wait in the store queue and write memory only
   at commit; loads execute out of order with conservative disambiguation and
   store-to-load forwarding.
9. **Commit** (`ooo_core.sv`) — the ROB head retires in order, updating the
   architectural map, reclaiming the superseded physical register, committing
   stores to memory, training the predictor, and handing the retirement to the
   golden model over DPI-C.

## Register renaming and recovery

* 32 architectural registers map onto 64 physical registers. Physical register
  `p0` is permanently architectural `x0` (zero, always ready) and is never
  freed.
* Allocation takes the lowest free physical register from a free-list bitmap.
  At commit, the *previous* mapping of the committed architectural register is
  returned to the free list — so a register-writing instruction always has a
  spare physical register available as long as fewer than 32 writers are in
  flight. (This is exactly the reclamation the earlier monotonic design lacked.)
* **Recovery is squash-at-retire.** A mispredicted control instruction is marked
  in its ROB entry when it executes, but the flush is taken only when it reaches
  the head and commits. At that instant every older instruction has already
  retired, so the architectural map is exact: recovery is a single-cycle reload
  of the speculative RAT from the committed RAT, a rebuild of the free list from
  the committed map, and a full squash of the ROB, reservation station and LSQ —
  no per-branch checkpoints. This trades a few cycles of misprediction penalty
  for a dramatically simpler, always-correct recovery path.

## Reorder buffer and precise state

The 32-entry ROB carries, per instruction, the rename bookkeeping (arch dest,
new and superseded physical registers), the result value, exception status, the
PC/instruction word, and the resolved control-flow outcome. Architectural state
(registers via the committed map, and memory via committed stores) changes only
at in-order commit, which is what makes both exceptions and branch recovery
precise.

## Load/Store queue

* In-order FIFOs allocated at dispatch (FIFO order = program order) and freed at
  commit, each entry tagged with a monotonic dispatch sequence number for age
  comparison.
* Stores compute address+data at issue, wait in the store queue, and write
  memory only at commit — wrong-path stores never touch memory.
* Loads execute out of order under a conservative rule: a load may complete only
  when every older store either has a known, non-overlapping address, or exactly
  matches it with ready data (forward). An older store with an unknown address,
  a partial overlap, or matching-but-not-ready data blocks the load until it
  resolves. This yields correct store-to-load forwarding and memory ordering
  without speculative load replay.

## Branch prediction details

* **GHR** — speculative copy updated at fetch, architectural copy updated in
  order at commit, speculative restored from architectural on flush.
* **PHT** — `2^8` two-bit saturating counters, gshare-indexed.
* **BTB** — 64-entry direct-mapped, storing target and a conditional bit; a hit
  is what tells fetch a PC is a control instruction.
* Statistics (committed control instructions, mispredictions, accuracy) are
  accumulated at commit and exported via CSV. Short programs show low accuracy
  (every branch is a first-time BTB miss); a warm loop (`tests/asm/predict.s`)
  reaches ~95%.

## Verification methodology

See [verification.md](verification.md). In short: the RTL calls a DPI-C function
at every retirement passing the committed PC, instruction, destination register
and value; the C++ golden model (`cpp_model/`) re-executes the same instruction
and compares architectural state, terminating with a detailed report on any
divergence. Directed tests cover each instruction class and microarchitectural
mechanism; a random generator stresses renaming, scheduling and the LSQ with
thousands of instructions per run.

## Parameters

All sizes live in `rtl/riscv_ooo_pkg.sv` and are easy to retune:

| Parameter   | Value | Meaning                         |
|-------------|-------|---------------------------------|
| `PHYS_REGS` | 64    | physical register file depth    |
| `ROB_SIZE`  | 32    | reorder buffer entries          |
| `RS_SIZE`   | 16    | reservation station entries     |
| `LQ_SIZE`   | 8     | load queue entries              |
| `SQ_SIZE`   | 8     | store queue entries             |
| `GHR_BITS`  | 8     | global history / PHT index bits |
| `BTB_ENTRIES`| 64   | branch target buffer entries    |
| `MEM_BYTES` | 65536 | flat memory image size          |
