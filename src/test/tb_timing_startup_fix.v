`timescale 1ns/1ps

// 与修改前的模块逐拍对照，覆盖双时钟 FIFO 满/空、指针回卷和取消复位。
module tb_chart_buffer_timing;
reg wclk=0,rclk=0,rst=1,we=0,ready=0;
always #10 wclk=~wclk;
always #17 rclk=~rclk;
reg [63:0] data=0;
wire reserve_new,reserve_old,overflow_new,overflow_old,valid_new,valid_old;
wire [7:0] used_new,used_old;
wire [63:0] note_new,note_old;
integer tick=0,reads=0,writes=0;
reg [31:0] random_state=32'h52a9b137;
rhythm_chart_buffer dut(rst,wclk,rclk,we,data,reserve_new,used_new,overflow_new,ready,valid_new,note_new);
baseline_rhythm_chart_buffer reference_buffer(rst,wclk,rclk,we,data,reserve_old,used_old,overflow_old,ready,valid_old,note_old);
always @(posedge wclk)begin
    if(!rst && we && used_new<128)writes=writes+1;
    #1;
    if({reserve_new,used_new,overflow_new}!=={reserve_old,used_old,overflow_old})
        $fatal(1,"FIFO write/control mismatch at %0t",$time);
end
always @(posedge rclk)begin
    if(!rst && ready && valid_new)reads=reads+1;
    #1;
    if(valid_new!==valid_old || (valid_new && note_new!==note_old))
        $fatal(1,"FIFO data mismatch at %0t: %h/%h",$time,note_new,note_old);
end
always @(negedge wclk)begin
    tick=tick+1;
    random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
    data={random_state,32'habbad00d^tick};
    we=!rst && ((tick<160) || random_state[0]);
end
always @(negedge rclk)ready=!rst && tick>=160 && random_state[3];
initial begin
    repeat(3)@(negedge wclk);#2;rst=0;
    wait(tick==165);
    if(!overflow_new)$fatal(1,"FIFO full/overflow was not exercised");
    wait(tick==900);#3;rst=1;
    // 非时钟沿复位，覆盖取消时尚未耗尽的预取以及 RAM 中的旧内容。
    repeat(2)@(negedge wclk);#2;rst=0;
    wait(tick==3000);
    if(writes<512 || reads<256)$fatal(1,"insufficient pointer wrap coverage");
    $display("PASS chart buffer timing: %0d writes/%0d reads, dual-clock equivalence, wrap, full and reset",writes,reads);
    $finish;
end
initial begin #100000;$fatal(1,"FIFO test timeout");end
endmodule
