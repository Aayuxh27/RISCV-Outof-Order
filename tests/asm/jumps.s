# jumps.s -- JAL / JALR control transfers and a tiny call/return sequence.
        addi  x1, x0, 0
        jal   x5, skip          # x5 = return addr; jump over the trap
        addi  x1, x1, 100       # SKIPPED on the first pass...
skip:
        addi  x2, x0, 7         # x2 = 7

        # call a leaf "function" that doubles a0, via JALR return
        addi  x10, x0, 21       # a0 = 21
        jal   x1, dbl           # call
        addi  x11, x10, 0       # x11 = 42 (a0 after return)

        # indirect jump through a register
        auipc x6, 0             # x6 = pc
        addi  x6, x6, 20        # point past the two traps -> 'target'
        jalr  x0, x6, 0
        addi  x7, x0, -1        # SKIPPED
        addi  x7, x0, -1        # SKIPPED
target:
        addi  x8, x0, 123
done:
        j     done

dbl:
        add   x10, x10, x10     # a0 *= 2
        jalr  x0, x1, 0         # return
