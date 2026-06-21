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
// Mirrors rtl/fetch_unit.v's bundled program by hand:
//   addi x1,x0,10        x1 = 10
//   addi x2,x0,20        x2 = 20
//   add  x3,x1,x2        x3 = 30
//   sub  x4,x3,x1        x4 = 20
//   add  x5,x3,x2        x5 = 50
//   add  x6,x4,x3        x6 = 50
//   add  x7,x6,x4        x7 = 70
// If you change the program in fetch_unit.v, update this array to match.

integer expected [1:7];
integer reg_num;
integer phys_tag;
integer errors;

//////////////////////////////////////////////////
// STIMULUS + SELF-CHECK
//////////////////////////////////////////////////

initial begin

    $dumpfile("waveforms/cpu.vcd");
    $dumpvars(0, cpu_tb);

    expected[1] = 10;
    expected[2] = 20;
    expected[3] = 30;
    expected[4] = 20;
    expected[5] = 50;
    expected[6] = 50;
    expected[7] = 70;

    clk = 0;
    reset = 1;

    #20;
    reset = 0;

    // 7 instructions, fetched 2-wide, executed/committed within a few
    // more cycles for wakeup + broadcast latency -- 20 cycles is a
    // comfortable margin for this program at 10ns/cycle.
    #200;

    errors = 0;

    $display("==================================================");
    $display(" RISC-V OoO core -- architectural register check");
    $display("==================================================");

    for(reg_num = 1; reg_num <= 7; reg_num = reg_num + 1)
    begin
        phys_tag = cpu.rat_inst.map_table[reg_num];

        if(cpu.regfile_inst.regfile[phys_tag] !== expected[reg_num])
        begin
            errors = errors + 1;
            $display("FAIL x%0d: expected %0d, got %0d (p%0d)",
                reg_num, expected[reg_num],
                cpu.regfile_inst.regfile[phys_tag], phys_tag);
        end
        else
        begin
            $display("PASS x%0d = %0d (p%0d)",
                reg_num, cpu.regfile_inst.regfile[phys_tag], phys_tag);
        end
    end

    if(cpu.commit_inst.retired_count !== 7)
    begin
        errors = errors + 1;
        $display("FAIL retired_count: expected 7, got %0d",
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
