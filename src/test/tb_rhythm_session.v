`timescale 1ns/1ps
module tb_rhythm_session;
    reg clk=0;always #20 clk=~clk;
    reg rst=1,game=1,sw1=1,k2=1,k3=1,k4=1,quiet=0,cancelled=0,ready=0;
    reg eof=0,ceof=0,emit=0,missing=0,prefetch=1,judge_done=0,overflow=0;
    reg [3:0] error=0;reg [31:0] index=0,count=0,level=2048;
    wire freeze,active,auto_mode,clear,enable,cancel,engine_reset,engine_run,engine_load,chart_eof;
    wire [1:0] mode;wire signed [32:0] time_now;wire [31:0] frames;wire [15:0] notes;wire signed [31:0] offset;
    wire [3:0] state,error_code;
    rhythm_session_controller #(.CLOCK_HZ(48000),.DEBOUNCE_MS(1),.PREROLL_SAMPLES(8),.TAIL_SAMPLES(8)) dut(
        clk,rst,game,sw1,k2,k3,k4,quiet,ready,cancelled,eof,ceof,error,32'd20,level,16'd1,32'sd0,
        emit,missing,prefetch,index,count,judge_done,overflow,freeze,active,auto_mode,clear,enable,cancel,
        engine_reset,engine_run,engine_load,mode,time_now,frames,notes,offset,chart_eof,state,error_code);
    integer cancel_wait=0,load_wait=0,resets=0;
    always @(posedge clk)begin
        if(rst)begin cancelled<=0;ready<=0;cancel_wait<=0;load_wait<=0;end
        else begin
            if(cancel)begin
                cancel_wait<=cancel_wait+1;if(cancel_wait>=12)cancelled<=1;
            end else begin cancel_wait<=0;cancelled<=0;end
            if(clear)begin ready<=0;load_wait<=0;resets<=resets+1;end
            else if(enable)begin load_wait<=load_wait+1;if(load_wait>=20)ready<=1;end
        end
    end
    task wait_state;input [3:0] expected;
        integer ticks;begin ticks=0;while(state!=expected && ticks<1000)begin @(negedge clk);ticks=ticks+1;end
            if(state!=expected)$fatal(1,"state timeout expected %0d actual %0d",expected,state);end
    endtask
    task press;input integer key;
        begin @(negedge clk);case(key)2:k2=0;3:k3=0;4:k4=0;endcase
            repeat(65)@(negedge clk);case(key)2:k2=1;3:k3=1;4:k4=1;endcase
            repeat(65)@(negedge clk);end
    endtask
    task frame;input [31:0] sample;
        begin @(negedge clk);index=sample;count=sample+1;emit=1;@(negedge clk);emit=0;end
    endtask
    integer i;reg signed [32:0] paused_time;
    initial begin
        repeat(4)@(negedge clk);rst=0;repeat(100)@(negedge clk);
        if(clear || state!=0)$fatal(1,"reset before picture transaction retired");quiet=1;
        wait_state(5);if(time_now!=-8 || mode!=2 || !active || auto_mode)$fatal(1,"manual pre-roll setup");
        wait_state(6);frame(0);repeat(5)@(negedge clk);if(time_now!=0)$fatal(1,"first sample time");
        repeat(10)@(negedge clk);if(time_now!=0)$fatal(1,"time moved without PCM");
        level=0;prefetch=0;missing=1;@(negedge clk);missing=0;wait_state(8);
        repeat(10)@(negedge clk);if(time_now!=0 || engine_run)$fatal(1,"buffer freeze");
        level=2048;prefetch=1;wait_state(6);frame(1);press(3);wait_state(7);paused_time=time_now;
        repeat(20)@(negedge clk);if(time_now!=paused_time || mode!=2)$fatal(1,"pause advanced");
        press(3);wait_state(6);for(i=2;i<20;i=i+1)frame(i);eof=1;ceof=1;wait_state(9);
        repeat(20)@(negedge clk);if(state!=9 || time_now!=27)$fatal(1,"tail/result synchronization");
        judge_done=1;wait_state(10);repeat(20)@(negedge clk);if(state!=10)$fatal(1,"result restarted");
        // 旧模式键在结果页及运行、暂停期间都必须无效，不得清空或重载。
        press(4);if(auto_mode || state!=10)$fatal(1,"mode key changed result");
        count=0;judge_done=0;press(2);wait_state(6);if(auto_mode || time_now!=0)$fatal(1,"manual restart");
        paused_time=time_now;press(4);if(auto_mode || state!=6 || time_now!=paused_time)$fatal(1,"mode key changed play");
        press(3);wait_state(7);press(4);if(state!=7 || auto_mode)$fatal(1,"mode key changed pause");press(3);wait_state(6);
        frame(0);count=0;press(2);wait_state(6);if(time_now!=0)$fatal(1,"KEY2 stale time");
        // 多位错误码只消费稳定值，短暂中间值不应锁死为错误页。
        error=3;@(negedge clk);error=0;repeat(6)@(negedge clk);if(state==11)$fatal(1,"transient error latched");
        error=12;wait_state(11);if(error_code!=12)$fatal(1,"E8L detail not preserved");error=0;
        count=0;press(2);wait_state(6);
        overflow=1;wait_state(11);if(error_code!=10 || !cancel || mode!=2)$fatal(1,"queue error");overflow=0;
        count=0;press(2);wait_state(6);sw1=0;wait_state(2);if(enable || mode!=0)$fatal(1,"stop");
        sw1=1;wait_state(6);game=0;count=0;wait_state(0);wait_state(6);
        if(active || freeze || time_now!=0)$fatal(1,"exit media");press(3);if(state!=6)$fatal(1,"media key paused audio");
        $display("PASS manual session retire/clear/pre-roll/PCM/buffer/pause/tail/result/restart/ignored-mode-key/exit");$finish;
    end
    initial begin #10000000;$fatal(1,"session timeout");end
endmodule
