`timescale 1ns/1ps
module tb_touch_lane_glow;
reg clk=0;always #20 clk=~clk;
reg rst=1,enabled=1,de=0,vs=0,auto_mode=0;
reg [3:0] state=6,down=0,press=0;
wire capture,on,frame_enabled;wire [23:0] color;
wire [7:0] observed_levels=dut.glow_levels;
rhythm_game_renderer #(.BLOCK_GEOMETRY(1),.STREAM_METADATA(1),.BLOCK_HUD(1)) dut(
    .clk(clk),.rst(rst),.enabled(enabled),.de(de),.vs(vs),.song_time(33'sd0),.song_frames(32'd480000),
    .state(state),.error_code(4'd0),.auto_mode(auto_mode),.score(20'd0),.combo(16'd0),.max_combo(16'd0),
    .perfect_count(16'd0),.good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),
    .metadata_valid(1'b0),.metadata_data(8'd0),.metadata_address(),.title(192'd0),.difficulty(128'd0),
    .view_index(),.view_valid(1'b0),.view_start(32'd0),.view_end(32'd0),.holding_mask(4'd0),
    .input_down(down),.input_press(press),.capture_busy(capture),.frame_enabled(frame_enabled),.pixel_on(on),.pixel_rgb(color));
task frame;begin
    @(negedge clk);vs=1;@(negedge clk);vs=0;repeat(4000)@(negedge clk);
    if(capture)$fatal(1,"glow extended capture");
end endtask
task pulse;input [3:0] p;begin @(negedge clk);press=p;@(negedge clk);press=0;end endtask
task levels;input [7:0] value;begin if(observed_levels!==value)$fatal(1,"glow levels %h expected %h",observed_levels,value);end endtask
integer xx,yy,f,pixels=0;reg save=0,d1=0;reg [9:0] input_x=0,x1=0;reg [8:0] input_y=0,y1=0;
reg [23:0] expected;
always @(posedge clk)begin d1<=de;x1<=input_x;y1<=input_y;end
always @(negedge clk)if(save && d1)begin
    $fwrite(f,"%c%c%c",on ? color[23:16]:8'h10,on ? color[15:8]:8'h12,on ? color[7:0]:8'h1b);pixels=pixels+1;
    if(y1==390 && (x1==152 || x1==264 || x1==376 || x1==488))begin
        case(x1)
            152:expected=24'hffcf28;264:expected=24'hff7900;376:expected=24'hed2166;default:expected=24'hce3cf0;
        endcase
        if(!on || color!==expected)$fatal(1,"receptor pixel %d/%d %h",x1,y1,color);
    end
    if(y1==384 && x1==400 && (!on || color!==24'hffffff))$fatal(1,"glow covered judge line");
    if(y1==432 && (x1==95 || x1==544) && on)$fatal(1,"glow outside tracks");
    if(y1==370 && x1==152 && color!==24'h3f330a)$fatal(1,"middle glow tier");
    if(y1==360 && x1==152 && color!==24'h3f330a)$fatal(1,"upper glow tier");
    if(y1==352 && x1==152 && color!==24'h1f1905)$fatal(1,"expanded area glow tier");
end
initial begin
    repeat(4)@(negedge clk);rst=0;repeat(3)@(negedge clk);frame;levels(0);
    down=1;pulse(1);frame;levels(8'h03);frame;levels(8'h03);
    down=3;pulse(2);frame;levels(8'h0f);
    // 帧间快速Tap，已松开仍需闪一次；包括frame_start当拍的press。
    enabled=0;repeat(2)@(negedge clk);enabled=1;down=0;pulse(15);frame;levels(8'hff);
    f=$fopen("prj/log/touch_glow_20261012/glow.ppm","wb");$fwrite(f,"P6\n640 480\n255\n");save=1;
    for(yy=0;yy<480;yy=yy+1)begin
        for(xx=0;xx<640;xx=xx+1)begin @(negedge clk);de=1;input_x=xx;input_y=yy;end
        @(negedge clk);de=0;repeat(160)@(negedge clk);
    end
    repeat(3)@(negedge clk);save=0;$fclose(f);if(pixels!=307200)$fatal(1,"pixel count");
    frame;levels(8'haa);frame;levels(8'haa);frame;levels(8'h55);frame;levels(8'h55);frame;levels(0);
    down=15;pulse(15);frame;levels(8'hff);
    state=7;repeat(2)@(negedge clk);levels(0);state=6;down=0;frame;levels(0);
    down=1;pulse(1);frame;levels(3);auto_mode=1;repeat(2)@(negedge clk);levels(0);
    auto_mode=0;down=0;
    @(negedge clk);press=8;vs=1;@(negedge clk);press=0;vs=0;repeat(4000)@(negedge clk);levels(8'hc0);
    rst=1;repeat(2)@(negedge clk);levels(0);
    $display("PASS lane glow held/chord/fast Tap/fade/AUTO/pause/reset, frame-edge press and 307200 pixel checks");$finish;
end
initial begin #100000000;$fatal(1,"timeout");end
endmodule
