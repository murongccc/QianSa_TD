`timescale 1ns/1ps
module tb_rhythm_pcm_clock;
    reg clk=0,rst=1;
    reg [1:0] mode=2'd2;
    reg [2:0] volume=4;
    reg [31:0] data=0;
    integer read_index=0,limit=0,emitted=0,ticks=0,missing=0,paused_count;
    wire empty=read_index>=limit;
    wire re,av,ev,mv,prefetched;
    wire [31:0] index,count;
    wire [23:0] left,right;
    always #20 clk=~clk;
    pcm_audio_player #(.PREFETCH_PAUSED(1)) dut(
        .clk(clk),.rst(rst),.fifo_dout(data),.fifo_empty(empty),.volume_level_async(volume),
        .playback_mode_async(mode),.fifo_re(re),.audio_valid(av),.left_pcm(left),.right_pcm(right),
        .underrun(),.sample_emitted(ev),.sample_missing(mv),.sample_index(index),
        .emitted_count(count),.prefetch_ready(prefetched));
    always @(posedge clk)begin
        if(rst)begin read_index<=0;data<=0;end
        else if(re && !empty)begin data<=32'h10000000+read_index;read_index<=read_index+1;end
    end
    always @(negedge clk)if(!rst)begin
        if(av)ticks=ticks+1;
        if(mv)begin
            missing=missing+1;
            if(ev || !av || left!=0 || right!=0)$fatal(1,"invalid missing pulse/silence");
        end
        if(ev)begin
            if(!av || index!==emitted || count!==emitted+1)$fatal(1,"song time not consecutive");
            if(volume!=0 && left!==(emitted<<8))$fatal(1,"FIFO sample order failed %0d %h",emitted,left);
            emitted=emitted+1;
        end
    end
    initial begin
        repeat(4)@(negedge clk);rst=0;
        // 先让 STOP→PAUSE 的同步器稳定，再启用生产者，避免 STOP 清理期吞掉新会话。
        repeat(20)@(negedge clk);limit=4;
        repeat(2000)@(negedge clk);
        if(!prefetched || count!=0 || read_index!=1 || ticks<3)$fatal(1,"paused prefill/time failed");
        mode=1;wait(count==4);repeat(1500)@(negedge clk);
        if(count!=4 || missing<1)$fatal(1,"starvation advanced song time");
        mode=2;repeat(20)@(negedge clk);paused_count=count;
        limit=8;repeat(1200)@(negedge clk);
        if(count!=paused_count || !prefetched)$fatal(1,"pause lost prefetched frame");
        mode=1;wait(count==6);mode=2;
        repeat(20)@(negedge clk);paused_count=count;
        repeat(1100)@(negedge clk);if(count!=paused_count)$fatal(1,"pause advanced count");
        volume=0;mode=1;wait(count==8);
        if(left!=0 || right!=0)$fatal(1,"volume-zero scaling failed");
        mode=0;repeat(20)@(negedge clk);
        if(count!=0 || prefetched)$fatal(1,"stop retained song time/sample");
        // 清理完成后开始新会话；首个真正输出的采样编号必须重新为零。
        rst=1;repeat(4)@(negedge clk);emitted=0;limit=0;mode=2;volume=4;rst=0;
        repeat(20)@(negedge clk);limit=4;
        wait(prefetched);mode=1;wait(count==4);
        $display("PASS emitted PCM clock, index zero, pause prefill, starvation freeze, muted frames, restart");$finish;
    end
    initial begin #2000000;$fatal(1,"PCM clock timeout");end
endmodule
