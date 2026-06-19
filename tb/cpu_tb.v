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


initial begin

    $dumpfile("waveforms/cpu.vcd");
    $dumpvars(0, cpu_tb);

    clk = 0;
    reset = 1;

    #20;
    reset = 0;

    #200;

    $finish;

end

endmodule
