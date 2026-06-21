module physical_regfile
#(
    parameter PHYS_REGS = 64
)
(
    input clk,
    input reset,

    ////////////////////////////////////////////////
    // DISPATCH-TIME READINESS PORTS (slot 0 / slot 1)
    ////////////////////////////////////////////////
    // Dispatch only needs to know whether an operand is ALREADY ready
    // when the instruction enters the issue queue (so the queue can
    // skip waiting for a wakeup that already happened). The value
    // itself can still change between dispatch and issue, so it is
    // deliberately not read here -- see the issue-time ports below.

    input [5:0] prs1_0,
    input [5:0] prs2_0,
    output ready1_0,
    output ready2_0,

    input [5:0] prs1_1,
    input [5:0] prs2_1,
    output ready1_1,
    output ready2_1,

    ////////////////////////////////////////////////
    // ISSUE-TIME VALUE PORTS (slot 0 / slot 1)
    ////////////////////////////////////////////////
    // The scheduler already guarantees both operands are ready before
    // asserting issue*_valid (using the issue queue's own ready bits,
    // which update in lockstep with this regfile on every broadcast),
    // so these ports only need to fetch the value, addressed by
    // whatever the issue queue actually stored for that entry.

    input [5:0] issue0_prs1,
    input [5:0] issue0_prs2,
    output [31:0] issue0_rs1_val,
    output [31:0] issue0_rs2_val,

    input [5:0] issue1_prs1,
    input [5:0] issue1_prs2,
    output [31:0] issue1_rs1_val,
    output [31:0] issue1_rs2_val,

    ////////////////////////////////////////////////
    // RENAME ALLOCATION (CLEAR READY ON NEW DESTINATION)
    ////////////////////////////////////////////////
    // A freshly-renamed destination tag must read back as "not ready"
    // until its producer actually broadcasts a value. Previously every
    // physical register (including ones not yet allocated to anything)
    // was marked ready at reset and never cleared, so a consumer
    // dispatched the cycle after its producer would see a stale
    // ready=1/value=0 instead of correctly waiting for the real result.
    // prd_0/prd_1 are 0 exactly when no allocation is happening in that
    // slot (the RAT never assigns tag 0, that's x0's permanent tag).

    input [5:0] prd_0,
    input [5:0] prd_1,

    ////////////////////////////////////////////////
    // BROADCAST WRITEBACK (2 CDB PORTS)
    ////////////////////////////////////////////////

    input broadcast0_valid,
    input [5:0] broadcast0_tag,
    input [31:0] broadcast0_value,

    input broadcast1_valid,
    input [5:0] broadcast1_tag,
    input [31:0] broadcast1_value
);

//////////////////////////////////////////////////
// PHYSICAL REGISTER STORAGE
//////////////////////////////////////////////////

reg [31:0] regfile [0:PHYS_REGS-1];
reg ready [0:PHYS_REGS-1];

integer i;

//////////////////////////////////////////////////
// RESET + ALLOCATE + WRITEBACK
//////////////////////////////////////////////////

always @(posedge clk or posedge reset)
begin

    if(reset)
    begin

        for(i=0;i<PHYS_REGS;i=i+1)
        begin
            regfile[i] <= 0;
            ready[i]   <= 1;
        end

    end
    else
    begin

        ////////////////////////////////////////////////
        // CLEAR READY ON NEW ALLOCATION
        ////////////////////////////////////////////////

        if(prd_0 != 6'd0)
            ready[prd_0] <= 0;

        if(prd_1 != 6'd0)
            ready[prd_1] <= 0;

        ////////////////////////////////////////////////
        // WRITEBACK FROM EXECUTION
        ////////////////////////////////////////////////

        if(broadcast0_valid)
        begin
            regfile[broadcast0_tag] <= broadcast0_value;
            ready[broadcast0_tag]   <= 1;
        end

        if(broadcast1_valid)
        begin
            regfile[broadcast1_tag] <= broadcast1_value;
            ready[broadcast1_tag]   <= 1;
        end

    end

end

//////////////////////////////////////////////////
// READ PORTS
//////////////////////////////////////////////////
// Dispatch-time readiness must also bypass the CDB directly, not just
// read the registered `ready` bit. The bit for a tag broadcast THIS
// cycle only updates at the next edge, but a dependent instruction can
// be renamed onto that exact tag and dispatched in this same cycle --
// without the bypass it latches a stale ready=0 into the issue queue
// and never gets another wakeup for that tag, stalling forever.

wire bcast_hit1_0 = (broadcast0_valid && broadcast0_tag==prs1_0) ||
                     (broadcast1_valid && broadcast1_tag==prs1_0);
wire bcast_hit2_0 = (broadcast0_valid && broadcast0_tag==prs2_0) ||
                     (broadcast1_valid && broadcast1_tag==prs2_0);
wire bcast_hit1_1 = (broadcast0_valid && broadcast0_tag==prs1_1) ||
                     (broadcast1_valid && broadcast1_tag==prs1_1);
wire bcast_hit2_1 = (broadcast0_valid && broadcast0_tag==prs2_1) ||
                     (broadcast1_valid && broadcast1_tag==prs2_1);

// A second race lives in the opposite direction: if a sibling
// instruction in the SAME dispatch group is allocating the very tag
// being read (e.g. "add x3,x1,x2 / sub x4,x3,x1" in one fetch group),
// the `ready` array still holds its old value -- the allocate-time
// clear above hasn't taken effect yet, it lands on the next edge. A
// freshly-allocated tag can never legitimately be ready in the same
// cycle it's allocated, so this must win over both `ready[]` and the
// CDB bypass.
wire alloc_hit1_0 = (prd_0!=6'd0 && prd_0==prs1_0) || (prd_1!=6'd0 && prd_1==prs1_0);
wire alloc_hit2_0 = (prd_0!=6'd0 && prd_0==prs2_0) || (prd_1!=6'd0 && prd_1==prs2_0);
wire alloc_hit1_1 = (prd_0!=6'd0 && prd_0==prs1_1) || (prd_1!=6'd0 && prd_1==prs1_1);
wire alloc_hit2_1 = (prd_0!=6'd0 && prd_0==prs2_1) || (prd_1!=6'd0 && prd_1==prs2_1);

assign ready1_0 = !alloc_hit1_0 && (ready[prs1_0] || bcast_hit1_0);
assign ready2_0 = !alloc_hit2_0 && (ready[prs2_0] || bcast_hit2_0);

assign ready1_1 = !alloc_hit1_1 && (ready[prs1_1] || bcast_hit1_1);
assign ready2_1 = !alloc_hit2_1 && (ready[prs2_1] || bcast_hit2_1);

assign issue0_rs1_val = regfile[issue0_prs1];
assign issue0_rs2_val = regfile[issue0_prs2];

assign issue1_rs1_val = regfile[issue1_prs1];
assign issue1_rs2_val = regfile[issue1_prs2];

endmodule
