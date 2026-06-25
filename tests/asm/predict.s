# predict.s -- a long-running loop so the gshare predictor warms up and branch
# accuracy climbs well above zero (short tests can't show this -- every branch is
# a first-time BTB miss).  Counts down from 200.
        li    x1, 0             # accumulator
        li    x2, 200           # iteration counter
loop:
        addi  x1, x1, 3
        addi  x2, x2, -1
        bnez  x2, loop          # taken 199x, falls through once
        # x1 == 600
done:
        j     done
