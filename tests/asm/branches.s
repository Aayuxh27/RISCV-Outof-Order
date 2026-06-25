# branches.s -- a counting loop that exercises branch prediction, speculative
# rename/free-list reuse across iterations, and misprediction recovery on exit.
# Computes sum(1..10) = 55 in x1.
        addi  x1, x0, 0         # sum = 0
        addi  x2, x0, 1         # i = 1
        addi  x3, x0, 11        # bound = 11
loop:
        add   x1, x1, x2        # sum += i
        addi  x2, x2, 1         # i++
        blt   x2, x3, loop      # taken 9 times, falls through once (mispredict)
        # x1 == 55 here
        addi  x4, x1, 0         # copy result
        slti  x5, x1, 100       # 1
        slti  x6, x1, 10        # 0
done:
        j     done
