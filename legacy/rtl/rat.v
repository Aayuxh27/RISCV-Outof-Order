module rat
#(
    parameter ARCH_REGS = 32,
    parameter PHYS_REGS = 64
)
(
    input clk,
    input reset,

    // decode inputs
    input valid0,
    input valid1,

    input [4:0] rs1_0,
    input [4:0] rs2_0,
    input [4:0] rd_0,

    input [4:0] rs1_1,
    input [4:0] rs2_1,
    input [4:0] rd_1,

    // physical source registers
    output reg [5:0] prs1_0,
    output reg [5:0] prs2_0,
    output reg [5:0] prs1_1,
    output reg [5:0] prs2_1,

    // physical destination registers
    output [5:0] prd_0,
    output [5:0] prd_1,

    //////////////////////////////////////////////////
    // SPECULATION: SINGLE-CHECKPOINT RENAME RECOVERY
    //////////////////////////////////////////////////
    // Only one branch is allowed to be outstanding (dispatched but not
    // yet resolved) at a time -- exactly one checkpoint of map_table +
    // free_ptr is kept, snapshotted right before the branch's own
    // rename. `valid1` here must already be gated by the predictor's
    // squash_slot1 (a taken slot-0 branch makes slot 1 wrong-path) --
    // that gating happens once, upstream, in ooo_top.

    input is_branch0,
    input is_branch1,

    input misprediction_valid,    // restore the checkpoint, free it
    input branch_correct_valid,   // just free the checkpoint

    // Case B: a branch needs the checkpoint and it won't be free this
    // cycle (an older branch is still outstanding) -- hold the whole
    // fetch group and retry it next cycle. Drives fetch_unit's PC hold
    // and dispatch_unit's squash for both slots.
    output stall,

    // Case C: both slots are branches in the same fetch group, so at
    // most one of them can claim the (single) checkpoint this cycle.
    // Slot 0 proceeds normally; slot 1 must be squashed and refetched
    // alone next cycle (redirected to pc+4) instead of being silently
    // dropped or causing the whole group to stall forever (which a
    // flat "stall if not available" rule would do, since this exact
    // group would face the same 2-vs-1 conflict every time it's
    // retried -- a real livelock, not just a missed optimization).
    output ckpt_conflict
);

//////////////////////////////////////////////////
// RAT TABLE & POINTER
//////////////////////////////////////////////////
reg [5:0] map_table [0:ARCH_REGS-1];
reg [5:0] free_ptr;
integer i;

//////////////////////////////////////////////////
// SINGLE CHECKPOINT STORAGE
//////////////////////////////////////////////////
reg [5:0] ckpt_map [0:ARCH_REGS-1];
reg [5:0] ckpt_free_ptr;
reg ckpt_busy;

//////////////////////////////////////////////////
// CHECKPOINT AVAILABILITY (SAME-CYCLE BYPASS)
//////////////////////////////////////////////////
// A checkpoint freed by a branch resolving correctly THIS cycle is
// available THIS cycle too -- ckpt_busy is the registered, start-of-
// cycle value and won't reflect branch_correct_valid until the next
// edge. Without this bypass a same-cycle "old branch resolves, new
// branch dispatches" sequence would incorrectly stall, since it's the
// exact same registered-vs-combinational race fixed in the regfile's
// ready bit earlier in this project.
wire ckpt_available = !ckpt_busy || branch_correct_valid;

wire branch_needed0 = valid0 && is_branch0;
wire branch_needed1 = valid1 && is_branch1;
wire [1:0] branches_needed = branch_needed0 + branch_needed1;

// Stall the WHOLE group whenever nothing is available this cycle,
// regardless of whether 1 or 2 branches are asking -- if none is
// available, letting slot 0 of a 2-branch group through unprotected
// (no checkpoint to roll back to) would be a correctness hole, not
// just a missed optimization. Only when a checkpoint IS available do
// we distinguish "exactly one, give it the checkpoint" from "two,
// give slot 0 the checkpoint and defer slot 1" (ckpt_conflict).
assign stall         = (branches_needed > 0) && !ckpt_available;
assign ckpt_conflict = ckpt_available && (branches_needed > 1);

wire save_checkpoint = !stall && (branches_needed >= 1);

//////////////////////////////////////////////////
// ALLOCATION LOGIC
//////////////////////////////////////////////////
// Evaluate whether each instruction actually requests a destination register.
// alloc1 additionally excludes a slot 1 that lost the Case C conflict above --
// it isn't really dispatching this cycle, so it must not be renamed either,
// or its (never-written) destination tag would corrupt the map table for
// whatever instruction reads that architectural register on the correct,
// next-cycle refetch of slot 1.
wire alloc0 = valid0 && (rd_0 != 0);
wire alloc1 = valid1 && (rd_1 != 0) && !ckpt_conflict;
wire [1:0] alloc_count = alloc0 + alloc1;

//////////////////////////////////////////////////
// DESTINATION TAGS (COMBINATIONAL)
//////////////////////////////////////////////////
// These must live in the same cycle as the instruction they tag.
// They were previously registered, which attached each dispatched
// micro-op's destination tag to the PREVIOUS cycle's instruction
// instead of its own (decode/prs* are combinational off the current
// instruction, so prd* has to be too, or the two desync by one slot).
// free_ptr==0 never happens post-reset (it starts at ARCH_REGS and only
// grows), so prd_0/prd_1==0 unambiguously means "no allocation this slot".
assign prd_0 = alloc0 ? free_ptr : 6'd0;
assign prd_1 = alloc1 ? (free_ptr + alloc0) : 6'd0;

//////////////////////////////////////////////////
// RESET + RENAME
//////////////////////////////////////////////////
always @(posedge clk or posedge reset) begin
    if(reset) begin
        // Initial mapping: xN → pN
        for(i=0; i<ARCH_REGS; i=i+1) begin
            map_table[i] <= i;
        end
        free_ptr  <= ARCH_REGS;
        ckpt_busy <= 0;
    end
    else if(misprediction_valid) begin
        // Roll back to the state as it was right before the mispredicted
        // branch. Whatever got renamed on the wrong path since is simply
        // abandoned -- there's nothing to undo, since nothing downstream
        // will ever read those tags again once the map table no longer
        // points at them.
        for(i=0; i<ARCH_REGS; i=i+1) begin
            map_table[i] <= ckpt_map[i];
        end
        free_ptr  <= ckpt_free_ptr;
        ckpt_busy <= 0;
    end
    else if(stall) begin
        // Can't safely rename this group without a checkpoint to protect
        // it. Hold map_table/free_ptr untouched; fetch_unit holds the same
        // PC so this exact group is retried next cycle. Still have to let
        // an unrelated, already-outstanding branch resolve correctly this
        // same cycle, though, or its checkpoint would stay busy forever.
        if(branch_correct_valid)
            ckpt_busy <= 0;
    end
    else begin

        if(branch_correct_valid)
            ckpt_busy <= 0;

        if(save_checkpoint) begin
            for(i=0; i<ARCH_REGS; i=i+1) begin
                ckpt_map[i] <= map_table[i];
            end
            ckpt_free_ptr <= free_ptr;
            ckpt_busy     <= 1;
        end

        // 1. Advance the pointer by the total number of registers allocated this cycle
        free_ptr <= free_ptr + alloc_count;

        // 2. Rename Instruction 0
        if(alloc0) begin
            map_table[rd_0] <= free_ptr;
        end

        // 3. Rename Instruction 1
        // We offset by 'alloc0' so it takes the NEXT available pointer if inst0 also allocated.
        // If rd_0==rd_1 (WAW in the same group) this statement runs second and wins, which is
        // correct: the later instruction in program order owns the architectural mapping.
        if(alloc1) begin
            map_table[rd_1] <= free_ptr + alloc0;
        end
    end
end

//////////////////////////////////////////////////
// SOURCE LOOKUP & INTRA-GROUP BYPASS
//////////////////////////////////////////////////
always @(*) begin
    // inst0 always looks up directly from the map table
    prs1_0 = map_table[rs1_0];
    prs2_0 = map_table[rs2_0];

    // inst1 MUST bypass the map table if it reads a register that inst0 is currently writing to
    prs1_1 = (alloc0 && (rs1_1 == rd_0) && (rs1_1 != 0)) ? free_ptr : map_table[rs1_1];
    prs2_1 = (alloc0 && (rs2_1 == rd_0) && (rs2_1 != 0)) ? free_ptr : map_table[rs2_1];
end

endmodule