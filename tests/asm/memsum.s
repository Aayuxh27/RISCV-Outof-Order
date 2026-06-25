# memsum.s -- store an array to memory, then sum it back with a load loop.
# Exercises loads in a loop, the LSQ, and load-after-store ordering across both
# forwarding (in-flight) and committed-to-memory stores.
        li    x1, 0x400         # array base

        li    x2, 5
        sw    x2, 0(x1)
        li    x2, 10
        sw    x2, 4(x1)
        li    x2, 15
        sw    x2, 8(x1)
        li    x2, 20
        sw    x2, 12(x1)
        li    x2, 50
        sw    x2, 16(x1)

        li    x3, 0             # sum
        li    x4, 0             # byte offset
        li    x5, 20            # end offset (5 words)
sumloop:
        add   x6, x1, x4
        lw    x7, 0(x6)
        add   x3, x3, x7
        addi  x4, x4, 4
        blt   x4, x5, sumloop
        # x3 == 100
done:
        j     done
