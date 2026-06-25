#!/usr/bin/env python3
# ============================================================================
# gen_random.py -- emit a random but self-terminating RV32I program.
# ----------------------------------------------------------------------------
# The C++ golden model is the reference, so *any* well-formed program is a valid
# test: the DPI co-simulation flags any RTL/model divergence.  This generator
# stresses register renaming, wakeup/scheduling and the LSQ with random
# dependency chains and memory traffic, while guaranteeing termination and
# keeping every memory access inside a scratch region clear of the code.
#
#   usage:  gen_random.py [seed] [n_instructions] > out.s
# ============================================================================
import random, sys

seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
n    = int(sys.argv[2]) if len(sys.argv) > 2 else 200
random.seed(seed)

# x31 is reserved as the memory base pointer and never written in the body.
GP = list(range(1, 31))          # general scratch registers x1..x30
RR = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
RI = ["addi", "slti", "sltiu", "xori", "ori", "andi", "slli", "srli", "srai"]

# Place the scratch data region on a 4 KiB boundary safely *above* the code, so
# stores never overwrite instructions (the RTL keeps instruction/data memories
# separate while the golden model is unified -- they only agree when code and
# data are disjoint, i.e. no self-modifying code).
code_bytes = (n + 4) * 4
base = (code_bytes + 0x100 + 0xFFF) & ~0xFFF
assert base + 0x100 < (1 << 16), "program too large for 64 KiB memory"

print("# auto-generated random test (seed=%d, n=%d)" % (seed, n))
print("        lui   x31, 0x%x          # memory base = 0x%x (scratch, above code)"
      % (base >> 12, base))

for _ in range(n):
    k = random.random()
    if k < 0.45:                                  # register-register ALU
        op = random.choice(RR)
        print("        %-6s x%d, x%d, x%d" % (op, random.choice(GP),
              random.choice(GP), random.choice(GP)))
    elif k < 0.75:                                # register-immediate ALU
        op = random.choice(RI)
        if op in ("slli", "srli", "srai"):
            imm = random.randint(0, 31)
        else:
            imm = random.randint(-2048, 2047)
        print("        %-6s x%d, x%d, %d" % (op, random.choice(GP),
              random.choice(GP), imm))
    elif k < 0.90:                                # store to scratch region
        op  = random.choice(["sb", "sh", "sw"])
        off = random.randint(0, 252) & ~3
        print("        %-6s x%d, %d(x31)" % (op, random.choice(GP), off))
    else:                                         # load from scratch region
        op  = random.choice(["lb", "lh", "lw", "lbu", "lhu"])
        off = random.randint(0, 252) & ~3
        print("        %-6s x%d, %d(x31)" % (op, random.choice(GP), off))

print("done:")
print("        j     done")
