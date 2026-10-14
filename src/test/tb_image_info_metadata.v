`timescale 1ns/1ps
// 独立整数参考检查尺寸、百分比舍入、五槽绑定、提前提交和失败复用。
module tb_image_info_metadata;
reg clk=0,rst=1,start=0,abort=0,commit=0,frame_start=0;
always #5 clk=~clk;
reg [2:0] write_slot=0,display_slot=0;
reg [15:0] source_width=0,source_height=0;
wire [88:0] display_info;
integer n,w,h;
image_info_metadata dut(.clk(clk),.rst(rst),.start(start),.abort(abort),.commit(commit),.ready(),
    .video_clk(clk),.video_rst(rst),.frame_start(frame_start),
    .write_slot(write_slot),.display_slot(display_slot),.source_width(source_width),.source_height(source_height),.display_info(display_info));
function [27:0] bcd_reference;
    input integer value;
    integer i,v;
    begin
        bcd_reference=0;v=value;
        for(i=0;i<7;i=i+1)begin bcd_reference[i*4 +: 4]=v%10;v=v/10;end
    end
endfunction
function [87:0] expected;
    input integer width,height;
    reg [27:0] wb,hb;
    begin
        wb=bcd_reference(width);hb=bcd_reference(height);
        expected={wb[15:0],hb[15:0],bcd_reference((6400000+width/2)/width),bcd_reference((4800000+height/2)/height)};
    end
endfunction
task begin_load;
    input integer slot,width,height;
    begin
        @(negedge clk);write_slot=slot;source_width=width;source_height=height;start=1;
        @(negedge clk);start=0;
        // 后续解析总线改变，缓存内容必须仍取启动快照。
        source_width=17;source_height=19;
    end
endtask
task publish;
    begin @(negedge clk);commit=1;@(negedge clk);commit=0;end
endtask
task check_slot;
    input integer slot,width,height;
    begin
        @(negedge clk);display_slot=slot;frame_start=1;
        @(negedge clk);frame_start=0;repeat(16)@(negedge clk);
        if(display_info!=={1'b1,expected(width,height)})
            $fatal(1,"metadata slot %d size %dx%d expected %h got %h",slot,width,height,{1'b1,expected(width,height)},display_info);
    end
endtask
initial begin
    repeat(3)@(negedge clk);rst=0;
    begin_load(0,320,240);repeat(170)@(negedge clk);
    if(display_info[88]!==0)$fatal(1,"uncommitted metadata visible");publish;repeat(16)@(negedge clk);check_slot(0,320,240);
    begin_load(1,640,480);publish;repeat(170)@(negedge clk);check_slot(1,640,480);
    begin_load(2,1920,1080);repeat(12)@(negedge clk);abort=1;@(negedge clk);abort=0;
    publish;repeat(170)@(negedge clk);display_slot=2;frame_start=1;
    @(negedge clk);frame_start=0;repeat(16)@(negedge clk);
    if(display_info[88]!==0)$fatal(1,"aborted metadata published");
    begin_load(2,1920,1080);repeat(170)@(negedge clk);publish;repeat(16)@(negedge clk);check_slot(2,1920,1080);
    begin_load(3,1280,720);publish;repeat(170)@(negedge clk);check_slot(3,1280,720);
    begin_load(4,1,1);publish;repeat(170)@(negedge clk);check_slot(4,1,1);
    check_slot(0,320,240);check_slot(1,640,480);check_slot(2,1920,1080);check_slot(3,1280,720);
    for(n=0;n<40;n=n+1)begin
        w=1+(n*127)%1920;h=1+(n*73)%1080;
        begin_load(n%5,w,h);publish;repeat(170)@(negedge clk);check_slot(n%5,w,h);
    end
    begin_load(0,0,480);publish;repeat(170)@(negedge clk);display_slot=0;frame_start=1;
    @(negedge clk);frame_start=0;repeat(16)@(negedge clk);
    if(display_info[88]!==0)$fatal(1,"invalid zero dimension published");
    rst=1;@(negedge clk);rst=0;
    for(n=0;n<5;n=n+1)begin display_slot=n;#1;if(display_info[88]!==0)$fatal(1,"stale valid after reset");end
    display_slot=7;frame_start=1;@(negedge clk);frame_start=0;repeat(16)@(negedge clk);
    if(display_info[88]!==0)$fatal(1,"invalid slot not blank");
    $display("PASS metadata: 45 sizes, rounded X/Y ratios, five slots, atomic commit, abort/reuse, stable snapshot, reset");$finish;
end
initial begin #200000;$fatal(1,"metadata timeout");end
endmodule
