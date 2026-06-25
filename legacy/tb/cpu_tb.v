`timescale 1ns/1ps

module cpu_tb;

reg clk;
reg reset;

// instantiate CPU
ooo_top cpu(
    .clk(clk),
    .reset(reset)
);

// clock generation
always #5 clk = ~clk;

//////////////////////////////////////////////////
// GOLDEN MODEL
//////////////////////////////////////////////////
// Mirrors rtl/fetch_unit.v's bundled program by hand. See that file's
// comments for the full word-by-word layout; in short:
//   x1..x9    straight-line ALU/immediate prologue
//   x10       branch test A (BEQ, correctly predicted taken) -> 777
//   x12       filler on test A's real path -> 1
//   x13       branch test B (BLT, mispredicted) -> 444, NOT 888
//             (888 is the abandoned speculative write from the
//             wrongly-predicted target; 444 is the real fallthrough)
//   x20, x21  confirm execution continues correctly post-recovery
// If you change the program in fetch_unit.v, update these arrays to match.

integer check_reg [0:12];
integer expected  [0:12];
integer idx;
integer reg_num;
integer phys_tag;
integer errors;

//////////////////////////////////////////////////
// STIMULUS + SELF-CHECK
//////////////////////////////////////////////////

initial begin

    $dumpfile("waveforms/cpu.vcd");
    $dumpvars(0, cpu_tb);

    check_reg[0]  = 1;  expected[0]  = 10;
    check_reg[1]  = 2;  expected[1]  = 20;
    check_reg[2]  = 3;  expected[2]  = 30;
    check_reg[3]  = 4;  expected[3]  = 20;
    check_reg[4]  = 5;  expected[4]  = 50;
    check_reg[5]  = 6;  expected[5]  = 50;
    check_reg[6]  = 7;  expected[6]  = 70;
    check_reg[7]  = 9;  expected[7]  = 5;
    check_reg[8]  = 10; expected[8]  = 777;
    check_reg[9]  = 12; expected[9]  = 1;
    check_reg[10] = 13; expected[10] = 444;
    check_reg[11] = 20; expected[11] = 555;
    check_reg[12] = 21; expected[12] = 999;

    clk = 0;
    reset = 1;

    #20;
    reset = 0;

    // 21 instructions across 11 fetch groups, plus the misprediction
    // recovery round trip (flush + re-fetch) for branch test B -- 400ns
    // (40 cycles at 10ns/cycle) is a comfortable margin.
    #400;

    errors = 0;

    $display("==================================================");
    $display(" RISC-V OoO core -- architectural register check");
    $display("==================================================");

    for(idx = 0; idx <= 12; idx = idx + 1)
    begin
        reg_num  = check_reg[idx];
        phys_tag = cpu.rat_inst.map_table[reg_num];

        if(cpu.regfile_inst.regfile[phys_tag] !== expected[idx])
        begin
            errors = errors + 1;
            $display("FAIL x%0d: expected %0d, got %0d (p%0d)",
                reg_num, expected[idx],
                cpu.regfile_inst.regfile[phys_tag], phys_tag);
        end
        else
        begin
            $display("PASS x%0d = %0d (p%0d)",
                reg_num, cpu.regfile_inst.regfile[phys_tag], phys_tag);
        end
    end

    if(cpu.commit_inst.retired_count !== 15)
    begin
        errors = errors + 1;
        $display("FAIL retired_count: expected 15, got %0d",
            cpu.commit_inst.retired_count);
    end
    else
    begin
        $display("PASS retired_count = %0d", cpu.commit_inst.retired_count);
    end

    $display("==================================================");
    if(errors == 0)
        $display(" ALL CHECKS PASSED");
    else
        $display(" %0d CHECK(S) FAILED", errors);
    $display("==================================================");

    $finish;

end

endmodule
