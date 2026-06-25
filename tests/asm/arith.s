# arith.s -- integer ALU ops and a dependency chain.
# Every result is checked against the C++ golden model via DPI at commit.
        addi  x1, x0, 10        # x1 = 10
        addi  x2, x0, 20        # x2 = 20
        add   x3, x1, x2        # x3 = 30   (RAW on x1,x2)
        sub   x4, x2, x1        # x4 = 10
        xor   x5, x1, x2        # x5 = 30
        and   x6, x3, x4        # x6 = 10
        or    x7, x1, x2        # x7 = 30
        slli  x8, x1, 2         # x8 = 40
        srai  x9, x4, 1         # x9 = 5
        sltu  x10, x1, x2       # x10 = 1
        li    x11, 0x12345      # large immediate (lui+addi)
        add   x12, x11, x1      # x12 = 0x12345 + 10
        addi  x13, x12, -100    # negative immediate
        sll   x14, x1, x2       # x14 = 10 << 20
done:
        j     done
