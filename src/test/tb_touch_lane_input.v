`timescale 1ns/1ps
module tb_touch_lane_input;
reg clk=0;always #10 clk=~clk;
reg rst=1,enable=0,update_valid=0,a_down=0,b_down=0;
reg [3:0] a_id=1,b_id=2;
reg [15:0] a_x=0,a_y=0,b_x=0,b_y=0;
wire valid,armed;wire [3:0] p,r,d;
touch_lane_input dut(clk,rst,enable,update_valid,a_id,a_down,a_x,a_y,b_id,b_down,b_x,b_y,valid,p,r,d,armed);
task report;
input ad,bd;input [3:0] ai,bi;input [15:0] ax,ay,bx,by;
input [3:0] ed,ep,er;
begin
    @(negedge clk);a_down=ad;b_down=bd;a_id=ai;b_id=bi;a_x=ax;a_y=ay;b_x=bx;b_y=by;update_valid=1;
    @(negedge clk);update_valid=0;repeat(12)@(negedge clk);
    if(d!==ed || p!==ep || r!==er || valid!==((ep|er)!=0))
        $fatal(1,"lane got D/P/R %h/%h/%h expected %h/%h/%h x/y %d/%d",d,p,r,ed,ep,er,ax,ay);
end endtask
task up;begin report(0,0,1,2,0,0,0,0,0,0,d);end endtask
integer i,j;reg [15:0] edges[0:4];reg [3:0] expected;
initial begin
    repeat(3)@(negedge clk);rst=0;enable=1;repeat(3)@(negedge clk);
    edges[0]=486;edges[1]=2494;edges[2]=4503;edges[3]=6512;edges[4]=8521;
    for(i=0;i<5;i=i+1)for(j=-1;j<=1;j=j+1)begin
        if(i==0 && j==-1 || i==4 && j>=0)expected=0;
        else if(j==-1)expected=1<<(i-1);else expected=1<<i;
        report(1,0,1,2,edges[i]+j,7584,0,0,expected,expected,0);up;
    end
    for(i=0;i<4;i=i+1)begin
        report(1,0,1,2,(edges[i]+edges[i+1])/2,6961,0,0,0,0,0);up;
        report(1,0,1,2,(edges[i]+edges[i+1])/2,6962,0,0,1<<i,1<<i,0);up;
        report(1,0,1,2,(edges[i]+edges[i+1])/2,6963,0,0,1<<i,1<<i,0);up;
    end
    // 新增的判定线上方区域：区外按下滑入仍忽略，区内向上移出仍绑定。
    report(1,0,1,2,1500,6961,0,0,0,0,0);
    report(1,0,1,2,1500,7100,0,0,0,0,0);up;
    report(1,0,1,2,1500,6962,0,0,1,1,0);
    report(1,0,1,2,1500,6961,0,0,1,0,0);up;
    report(1,0,1,2,100,8000,0,0,0,0,0);
    report(1,0,1,2,3500,8000,0,0,0,0,0);up;
    report(1,0,1,2,1500,65535,0,0,1,1,0);
    report(1,0,1,2,7500,8000,0,0,1,0,0);
    report(1,0,1,2,65535,100,0,0,1,0,0);up;
    report(1,0,1,2,7500,8000,0,0,8,8,0);up;
    report(1,1,1,2,1500,8000,7500,8000,9,9,0);
    // 槽交换，身份绑定保留；随后一指释放另一指仍保持。
    report(1,1,2,1,1500,8000,7500,8000,9,0,0);
    report(1,0,2,1,1500,8000,0,0,8,0,1);up;
    report(1,0,1,2,3500,8000,0,0,2,2,0);
    report(1,1,1,2,3500,8000,3600,8000,2,0,0);
    report(0,1,1,2,3500,8000,3600,8000,2,0,0);up;
    report(1,0,1,2,1500,8000,0,0,1,1,0);
    report(1,0,3,2,5500,8000,0,0,4,4,1);up;
    report(1,0,3,2,5500,8000,0,0,4,4,0);
    @(negedge clk);enable=0;repeat(3)@(negedge clk);enable=1;
    repeat(4)@(negedge clk);if(armed || d)$fatal(1,"held restart armed");
    report(1,0,3,2,1500,8000,0,0,0,0,0);
    report(0,0,3,2,0,0,0,0,0,0,0);repeat(3)@(negedge clk);
    report(1,0,3,2,1500,8000,0,0,1,1,0);up;
    // 顺序处理尚未完成时停用，必须丢弃整条报告，不提交半条绑定。
    @(negedge clk);a_down=1;a_id=5;a_x=3500;a_y=8000;update_valid=1;
    @(negedge clk);update_valid=0;repeat(4)@(negedge clk);enable=0;
    repeat(16)@(negedge clk);if(valid || d || armed)$fatal(1,"partial report survived pause");
    enable=1;repeat(16)@(negedge clk);if(valid || d || armed)$fatal(1,"partial report resumed");
    report(0,0,5,2,0,0,0,0,0,0,0);repeat(3)@(negedge clk);
    report(1,0,5,2,3500,8000,0,0,2,2,0);up;
    $display("PASS lane boundaries, identity, no slide, chords, same lane, rearm, partial report cancellation");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
