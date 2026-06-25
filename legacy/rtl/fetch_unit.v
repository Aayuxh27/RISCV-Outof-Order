module fetch_unit(

    input clk,
    input reset,

    // Highest priority: a resolved branch was mispredicted -- whatever
    // is currently in fetch/decode is wrong-path, redirect immediately.
    input misprediction_valid,
    input [31:0] misprediction_pc,

    // Next: a predict-time redirect (taken branch in this fetch group),
    // OR a single-checkpoint conflict deferring slot 1 to be refetched
    // alone next cycle -- both expressed the same way by ooo_top: a
    // redirect target for the next fetch.
    input redirect_valid,
    input [31:0] redirect_pc,

    // Lowest priority before falling through to sequential: hold PC,
    // an outstanding branch hasn't freed the single rename checkpoint
    // yet, so this whole group is retried next cycle.
    input stall,

    output reg [31:0] pc,
    output [31:0] inst0,
    output [31:0] inst1
);

//////////////////////////////////////////////////
// SIMPLE INSTRUCTION MEMORY
//////////////////////////////////////////////////

reg [31:0] memory [0:255];

initial begin

    // Example program -- see tb/cpu_tb.v for the matching golden model.
    //
    // Words 0-7: straight-line ALU/immediate prologue (unchanged from
    // the front-end-only version of this core).
    //
    // Words 8-15: branch test A -- BEQ x1,x1 is always taken and the
    // cold-start predictor (reset to weakly-taken) gets it right on the
    // first try, so this exercises predict-taken + slot-1 squash +
    // redirect with NO misprediction recovery involved. Word 9 (decoy)
    // must never retire; words 10/11 are dead code, reachable by
    // neither the real nor the speculative path, kept only to show
    // what a not-taken fallthrough would have looked like; word 14 is
    // the real landing zone.
    //
    // Words 12-13: NOT part of test A's flow -- this is test B's
    // speculative target, placed here specifically because it's
    // already-proven dead code from test A's perspective (the redirect
    // at word 8 jumps straight over it), so reusing it can't be
    // accidentally re-executed by anything else later.
    //
    // Words 16-20: branch test B -- BLT x2,x1 (20 < 10) is actually
    // NOT taken, but the cold-start predictor still says taken, so
    // this is a real misprediction: word 17 (the true fallthrough) is
    // squashed at predict time same as any taken-branch's slot 1, the
    // speculative target at word 12 dispatches and even executes
    // before the branch resolves, and recovery has to (a) flush that
    // speculative write before it commits and (b) re-fetch word 17 for
    // real off the recovery redirect. x13 ends up 444 (from word 17),
    // never 888 (the abandoned, never-committed speculative write from
    // word 12) -- that's the whole "abandon, don't undo" rename
    // recovery model in one register.

    memory[0]  = 32'h00a00093; // addi x1,x0,10
    memory[1]  = 32'h01400113; // addi x2,x0,20
    memory[2]  = 32'h002081b3; // add x3,x1,x2
    memory[3]  = 32'h40118233; // sub x4,x3,x1
    memory[4]  = 32'h002182b3; // add x5,x3,x2
    memory[5]  = 32'h00320333; // add x6,x4,x3
    memory[6]  = 32'h004303b3; // add x7,x6,x4
    memory[7]  = 32'h00500493; // addi x9,x0,5

    memory[8]  = 32'h00108c63; // beq x1,x1,+24      -> word 14 (taken, correctly predicted)
    memory[9]  = 32'h06f00513; // addi x10,x0,111    [squashed decoy, must never retire]
    memory[10] = 32'h0de00513; // addi x10,x0,222    [dead code]
    memory[11] = 32'h14d00513; // addi x10,x0,333    [dead code]
    memory[12] = 32'h37800693; // addi x13,x0,888    [test B's speculative poison target]
    memory[13] = 32'h00000013; // addi x0,x0,0       [inert filler, prd==0 never dispatches]
    memory[14] = 32'h30900513; // addi x10,x0,777    [test A real landing zone]
    memory[15] = 32'h00100613; // addi x12,x0,1

    memory[16] = 32'hfe1148e3; // blt x2,x1,-16      -> word 12 (predicted taken, ACTUALLY not taken: mispredict)
    memory[17] = 32'h1bc00693; // addi x13,x0,444    [real fallthrough; squashed at predict time, refetched by recovery]
    memory[18] = 32'h22b00a13; // addi x20,x0,555
    memory[19] = 32'h01468ab3; // add x21,x13,x20    = 444+555 = 999
    memory[20] = 32'h00000013; // addi x0,x0,0       [inert filler]

end

//////////////////////////////////////////////////
// PC UPDATE
//////////////////////////////////////////////////

always @(posedge clk or posedge reset)
begin

    if(reset)
        pc <= 0;
    else if(misprediction_valid)
        pc <= misprediction_pc;
    else if(redirect_valid)
        pc <= redirect_pc;
    else if(stall)
        pc <= pc;       // hold: retry this exact fetch group next cycle
    else
        pc <= pc + 8;   // 2 instructions per cycle

end

//////////////////////////////////////////////////
// 2-WIDE FETCH
//////////////////////////////////////////////////

assign inst0 = memory[pc[9:2]];
assign inst1 = memory[pc[9:2] + 1];

endmodule
