# RISC-V Out-of-Order Superscalar Core

A small dual-issue, out-of-order execution core in Verilog, built to actually
understand how register renaming, wakeup-based scheduling, and CDB broadcast
fit together -- not just to recite the diagram. It implements the RV32I ALU
subset (R-type and I-type integer ops, no loads/stores/branches yet) end to
end: fetch -> decode -> rename -> dispatch -> issue queue -> 2-wide execute ->
CDB -> reorder buffer -> commit.

Every register value below is checked against a hand-computed golden model
in the testbench, not just eyeballed off a waveform (see [Verification](#verification)
for why that distinction matters here).

## Pipeline and why each stage looks the way it does

### Fetch (`rtl/fetch_unit.v`)
A 256-word instruction memory seeded with a fixed demo program, fetching two
instructions per cycle (`pc[9:2]` and `pc[9:2]+1`) and bumping the PC by 8
bytes a cycle. No branches, so there's no need for a BTB or redirect path --
the PC is a straight-line counter. This is intentionally the least
interesting module in the design; the point of the project is everything
downstream of it.

### Decode (`rtl/decode_unit.v`)
Decodes both instructions per cycle into `{opcode, rs1, rs2, rd}` plus,
critically, a sign-extended 32-bit immediate and a `use_imm` flag for I-type
ops. That immediate path is worth dwelling on: R-type's `rs2` field and
I-type's `imm[4:0]` field occupy the *same bit positions* (`inst[24:20]`) in
the RV32I encoding. Decode for an I-type instruction explicitly zeroes
`rs2` and routes the real operand through `imm` instead of letting it fall
through as a bogus register index -- forcing `rs2 = 0` is also what lets the
immediate operand ride on the existing "x0 is always ready" path everywhere
downstream, instead of needing a separate plumbing path.

### Rename / RAT (`rtl/rat.v`)
32 architectural registers map onto 64 physical registers. Renaming is
monotonic: a free pointer starts at 32 (right after the 1:1 boot mapping for
x0-x31) and increments by 1 or 2 every cycle depending on how many of the two
decoded instructions actually write a register. There's no free list and no
reclamation -- this is the single biggest scaling limitation of the design
(see [Limitations](#known-limitations--natural-next-steps)), but it keeps the
rename logic small enough to actually reason about by hand, which was the
point for a first OOO project.

Two things about this stage are easy to get wrong and worth calling out
explicitly because they're exactly the kind of thing that breaks silently in
simulation instead of throwing an error:

- **Intra-group bypass.** If instruction 1 in a fetch group reads a register
  that instruction 0 in the *same* group is about to write (e.g.
  `add x3,x1,x2` / `sub x4,x3,x1` fetched together), the map table hasn't
  been updated yet -- that write only lands on the next clock edge. Instr 1's
  source lookup has to bypass straight to the tag instruction 0 is about to
  receive (`free_ptr`), not the stale map table entry.
- **Destination tags must be combinational, not registered.** `prd_0`/`prd_1`
  used to be registered outputs, sampled one cycle after `opcode`/`prs1`/`prs2`
  (which are combinational off the *current* decoded instruction). That meant
  the destination tag handed to the issue queue belonged to the *previous*
  cycle's instruction, not the one it was bundled with. They're `assign`ed
  combinationally now, off the same `free_ptr`/`alloc0`/`alloc1` terms used to
  update the map table, so a micro-op's opcode, operands, and destination all
  describe the same instruction.

### Dispatch (`rtl/dispatch_unit.v`)
Purely combinational glue between rename and the issue queue/ROB. The one
real decision it makes: an instruction renamed with destination tag 0 (i.e.
its architectural destination is `x0`) is dropped here instead of being
let into the issue queue. Since this core has no branches or memory ops, a
register write is an instruction's *only* externally visible effect -- if
that write target is `x0`, there's nothing left to track, and worse, letting
it through would let some instruction's broadcast tag collide with `p0`,
which has to stay permanently zero.

### Issue queue + scheduler (`rtl/issue_queue.v`, `rtl/scheduler.v`)
An 8-entry scoreboard: each entry tracks `{opcode, prs1, prs2, pd, imm,
use_imm, ready1, ready2}`. Dispatch can write up to two entries in the same
cycle, which means the free-slot search for slot 1 has to explicitly exclude
whatever slot 0 just claimed -- otherwise two simultaneously-dispatching
instructions can race for the same free index and one vanishes. The
scheduler scans for the two oldest entries with both operands ready and
issues both in the same cycle; everything else stalls in place. This is
where the "out-of-order" in the name actually happens: an instruction with
both operands ready can issue ahead of an older one still waiting on a
producer.

### Execution + CDB (`rtl/execution_units.v`)
Two independent ALU/broadcast ports, not one. This isn't decoration: the
scheduler can legitimately issue two ready instructions in the same cycle
(that's the entire point of having two issue slots), and the issue queue
removes both of their entries that same cycle once the scheduler says they
issued. If there were only one shared ALU and broadcast port, the second
instruction's *entry* would still be removed from the queue, but its
*result* would simply never be computed or written back -- a silent,
permanent loss of one in every pair of simultaneously-ready instructions.
Two ports means the CDB width matches the issue width, which is what makes
dual-issue actually dual-issue all the way to the register file. The ALU
itself is a single `function` instantiated twice so the two ports can't
drift out of sync as opcodes get added.

### Physical register file (`rtl/physical_regfile.v`)
This module ended up being where most of the subtlety in the whole design
lives, because it sits at the intersection of three different timing
domains: dispatch-time readiness, issue-time value reads, and CDB
writeback. Two separate read interfaces exist on purpose:

- **Dispatch-time ports** (`prs1_0/prs2_0`, `prs1_1/prs2_1`) only return a
  ready bit, not a value -- dispatch just needs to know whether to mark an
  issue-queue entry ready-at-birth or wait for a wakeup. The value can still
  change between dispatch and issue.
- **Issue-time ports** (`issue0_prs1/issue0_prs2`, `issue1_prs1/issue1_prs2`)
  return the actual operand values, addressed by whatever the scheduler is
  issuing *this* cycle. The scheduler only issues an entry once the issue
  queue's own ready bits say both operands are in, so by construction the
  regfile write from the producing broadcast has already landed by the time
  this read happens.

The readiness side needed two bypasses to avoid losing wakeups, both found
by tracing actual register values through a run rather than just watching
`free_ptr`:

1. **CDB-to-dispatch bypass.** The `ready` bit for a tag broadcast *this*
   cycle only updates on the next clock edge. If a dependent instruction is
   dispatched in that same cycle (entirely possible -- a one-cycle-apart RAW
   chain is the common case, not an edge case), reading the registered
   `ready` bit gives a stale "not ready," and since that tag's only broadcast
   already happened, the instruction would never get woken up again. Fixed
   by having the dispatch-time ready ports also directly compare against
   both live broadcast tags, not just the registered bit.
2. **Allocate-to-dispatch bypass.** The opposite race: if a sibling
   instruction in the *same* dispatch group is allocating the exact tag being
   read (`add x3,x1,x2` / `sub x4,x3,x1` again), the `ready` array still holds
   whatever it held before -- the allocate-time clear is also a registered
   write that hasn't landed yet. A tag can never legitimately be ready in the
   same cycle it's allocated, so this check forces `ready=0` and takes
   priority over both the stored bit and the CDB bypass above.

Without either bypass the pipeline doesn't crash -- it just quietly computes
wrong numbers or stalls forever, which is a much worse failure mode for a
learning project because it looks like it's working if you only check that
the simulation finishes.

### Reorder buffer + commit (`rtl/reorder_buffer.v`, `rtl/commit_unit.v`)
A 32-entry circular buffer tracking program order, allocating up to two
entries per cycle (with the same "slot 1 offsets by slot 0's count" pattern
used everywhere else two things can happen in one cycle) and retiring up to
two entries per cycle from the head once their tag has been broadcast.
There are no exceptions or branch mispredictions in this core, so nothing
*depends* on the ROB for correctness today -- the physical register file is
already updated directly off the CDB, which is safe precisely because there's
nothing to roll back. I wired it up anyway and pass `commit_done` /
`retired_count` out to the top level because (a) precise in-order commit is
the actual point of having a ROB in a real design, and skipping it would
leave the project half-explaining its own block diagram, and (b) the head
pointer here is exactly the hook a future free-list-based register
reclamation scheme would consume -- see [Limitations](#known-limitations--natural-next-steps).

## Verification

The original version of this testbench just dumped a VCD and told you to go
look at `rat_inst.free_ptr` in a waveform viewer. The problem with that: it
only proves the RAT can hand out two tags in one cycle, which says nothing
about whether the instructions those tags belong to ever produce the right
*values*. Tracing actual register contents during development is what
surfaced every bug described above -- the free-pointer waveform looked
exactly the same before and after every one of those fixes.

`tb/cpu_tb.v` now hand-computes the expected value of `x1`-`x7` for the
bundled program, runs the core, then reads each architectural register back
through the RAT's own map table (`cpu.rat_inst.map_table[n]`) into the
physical register file (`cpu.regfile_inst.regfile[tag]`) and diffs it
against the golden value. It also checks `retired_count` hits 7, so a
instruction that silently never reaches commit fails the run instead of
passing by omission. A VCD is still dumped for anyone who wants to look at
the waveform by hand (e.g. to watch the dual-issue dispatch directly, see
below) -- it's just no longer the thing standing between "ran" and "correct."

## Known limitations / natural next steps

- **No free list.** Physical registers are handed out monotonically and
  never reclaimed, so the core can only ever execute as many
  register-writing instructions as it has spare physical registers (32, in
  this configuration) before `free_ptr` wraps and corrupts the boot mapping.
  Fine for a 7-instruction demo program; the fix is a free list pushed to by
  ROB commit, which is exactly why `commit_done`/`retired_count` already
  exist.
- **No branches.** Fetch is a straight-line counter. Adding control flow
  means adding a redirect path and, since this core renames speculatively,
  a way to recover the RAT/free-list state on a misprediction.
- **No loads/stores.** The ISA is ALU-only (R-type and I-type). Memory ops
  would need an age-ordered load/store queue, which is a different (and
  larger) hazard-detection problem than anything register renaming solves.
- **Issue width caps at 2 regardless of queue occupancy.** The scheduler
  only ever looks for the oldest two ready entries, even though the queue
  holds eight. This matches the 2-wide fetch/dispatch/execute front end
  consistently, but a wider machine would need a wider scheduler and CDB to
  match.

## Repository layout

```
rtl/    synthesizable design (fetch, decode, rename, dispatch,
        issue queue, scheduler, execution, regfile, ROB, commit, top)
tb/     self-checking testbench
sim/    build output (gitignored)
waveforms/  VCD output (gitignored)
```

## Running the simulation

Prerequisites: Icarus Verilog (`iverilog`/`vvp`) with SystemVerilog support
(`-g2012`), and GTKWave (or Surfer) if you want to look at the waveform.

```bash
# 1. Clone the repository
git clone https://github.com/devtyagi3909/riscv-ooo-core.git
cd riscv-ooo-core

# 2. Compile the RTL and the self-checking testbench
iverilog -g2012 -o sim/cpu_sim rtl/*.v tb/cpu_tb.v

# 3. Run it -- this both executes the golden-model check and dumps
#    waveforms/cpu.vcd
vvp sim/cpu_sim
```

Expected output:

```
==================================================
 RISC-V OoO core -- architectural register check
==================================================
PASS x1 = 10 (p32)
PASS x2 = 20 (p33)
PASS x3 = 30 (p34)
PASS x4 = 20 (p35)
PASS x5 = 50 (p36)
PASS x6 = 50 (p37)
PASS x7 = 70 (p38)
PASS retired_count = 7
==================================================
 ALL CHECKS PASSED
==================================================
```

If any check fails it prints `FAIL <reg>: expected <N>, got <M> (p<tag>)`
instead, which is enough to immediately tell you whether the bug is in
renaming (wrong tag), execution (right tag, wrong value), or scheduling
(instruction never retires).

```bash
# 4. (optional) open the waveform
gtkwave waveforms/cpu.vcd
# or, if you have it installed:
surfer waveforms/cpu.vcd
```

To watch dual-issue dispatch directly in the waveform: add
`rat_inst.free_ptr` and `iq_inst.valid`/`sched_inst.issue0_valid`/
`sched_inst.issue1_valid` to the view. You'll see `free_ptr` jump by 2 in a
single cycle on every fetch group where both instructions write a register,
and -- unlike in the version of this design that only proved that one
signal -- you can now also cross-check the corresponding `commit0_tag`/
`commit1_tag` pulses on `rob_inst` against the values printed by the
testbench above to confirm both instructions in a group actually carried
their result all the way to commit, not just into the queue.

![Surfer waveform: RAT dual-allocation](assets/surfer_trace.png)
