# loadstore.s -- exercises the load/store queue, store-to-load forwarding, and
# sub-word accesses.  Uses a scratch data region at 0x400 (zero-initialised,
# clear of the program).
        li    x1, 0x400         # base address

        li    x2, 0x11223344
        sw    x2, 0(x1)         # store word
        lw    x3, 0(x1)         # forward from the in-flight store -> 0x11223344

        li    x4, 0x000000F0
        sb    x4, 8(x1)         # store byte 0xF0
        lb    x5, 8(x1)         # signed   -> 0xFFFFFFF0
        lbu   x6, 8(x1)         # unsigned -> 0x000000F0

        li    x7, 0x0000BEEF
        sh    x7, 12(x1)        # store half
        lh    x8, 12(x1)        # signed   -> 0xFFFFBEEF
        lhu   x9, 12(x1)        # unsigned -> 0x0000BEEF

        # dependent address: store then load through a computed pointer
        addi  x10, x1, 16
        li    x11, 12345
        sw    x11, 0(x10)
        lw    x12, 0(x10)       # -> 12345

        # overwrite then re-read (latest store must win the forward)
        li    x13, 999
        sw    x13, 0(x1)
        lw    x14, 0(x1)        # -> 999  (not 0x11223344)
done:
        j     done
