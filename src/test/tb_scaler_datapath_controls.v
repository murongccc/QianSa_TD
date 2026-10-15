`timescale 1ns/1ps

// 与 64 位坐标公式、互补权重的独立参考模型逐像素比较。
// 行缓存模型使用 tb_bmp_bilinear_scaler.v 中的注册输出模型。
module tb_scaler_datapath_controls;
parameter integer OUT_W=19, OUT_H=14, RUN_BOUNDARIES=1, RESET_SWEEP=0, FULL_SMOKE=0;
parameter integer MAX_W=1920, MAX_H=1080;
reg clk=0, rst=1, start=0, abort=0, active=0;
reg [15:0] width_value=1,height_value=1;
reg src_valid=0,src_last=0,src_frame_last=0,dst_ready=0;
reg [23:0] src_pixel=0;
wire src_ready,dst_valid,dst_last,dst_frame_last,busy,done;
wire [23:0] dst_pixel;
wire [9:0] dst_x,dst_y;
integer input_count=0,output_count=0,cycle_count=0,pattern=0;
integer row_index,col_index;
reg stalled=0;
reg [45:0] held_output;
reg [23:0] expected_pixel;
always #5 clk=~clk;

bmp_bilinear_scaler #(.OUT_WIDTH(OUT_W),.OUT_HEIGHT(OUT_H),
    .MAX_WIDTH(MAX_W),.MAX_HEIGHT(MAX_H)) dut(
    .clk(clk),.rst(rst),.start(start),.abort(abort),
    .src_width(width_value),.src_height(height_value),
    .src_valid(src_valid),.src_pixel(src_pixel),.src_last(src_last),
    .src_frame_last(src_frame_last),.src_ready(src_ready),
    .dst_ready(dst_ready),.dst_valid(dst_valid),.dst_pixel(dst_pixel),
    .dst_last(dst_last),.dst_frame_last(dst_frame_last),.dst_x(dst_x),.dst_y(dst_y),
    .busy(busy),.done(done)
);
wire ref_src_ready,ref_dst_valid,ref_dst_last,ref_dst_frame_last,ref_busy,ref_done;
wire [23:0] ref_dst_pixel;
wire [9:0] ref_dst_x,ref_dst_y;
baseline_bmp_bilinear_scaler #(.OUT_WIDTH(OUT_W),.OUT_HEIGHT(OUT_H),
    .MAX_WIDTH(MAX_W),.MAX_HEIGHT(MAX_H)) reference_dut(
    .clk(clk),.rst(rst),.start(start),.abort(abort),
    .src_width(width_value),.src_height(height_value),
    .src_valid(src_valid),.src_pixel(src_pixel),.src_last(src_last),
    .src_frame_last(src_frame_last),.src_ready(ref_src_ready),
    .dst_ready(dst_ready),.dst_valid(ref_dst_valid),.dst_pixel(ref_dst_pixel),
    .dst_last(ref_dst_last),.dst_frame_last(ref_dst_frame_last),.dst_x(ref_dst_x),.dst_y(ref_dst_y),
    .busy(ref_busy),.done(ref_done)
);
// 输出数据和全部握手逐拍对照，包含无效周期、反压及 abort。
always @(negedge clk) begin
    if({src_ready,dst_valid,dst_pixel,dst_last,dst_frame_last,dst_x,dst_y,busy,done} !==
       {ref_src_ready,ref_dst_valid,ref_dst_pixel,ref_dst_last,ref_dst_frame_last,ref_dst_x,ref_dst_y,ref_busy,ref_done})
        $fatal(1,"baseline cycle mismatch at cycle %0d",cycle_count);
    // 只在实际读取邻点或准备行缓存时证明边界比较的前提。
    if(!rst && !abort && (dut.state==5'd18 || dut.state==5'd6 ||
       dut.state==5'd7 || dut.state==5'd8)) begin
        if(dut.sx0>dut.sw-1'b1 || dut.sy0>dut.sh-1'b1)
            $fatal(1,"coordinate exceeded source boundary");
        if(OUT_W>1 && dut.x_fp!==reference_dut.x_fp_eff)
            $fatal(1,"redundant x endpoint premise violated");
        if(OUT_H>1 && dut.y_fp!==reference_dut.y_fp_eff)
            $fatal(1,"redundant y endpoint premise violated");
    end
end


function [23:0] source_pixel;
    input integer x,y;
    begin
        if(pattern==1) source_pixel=24'hffffff;
        else if(pattern==3) source_pixel=24'h000000;
        else if(pattern==2) source_pixel=((x+y)%2)?24'hffffff:24'h000000;
        else begin
            source_pixel[23:16]=(x*73+y*29)&255;
            source_pixel[15:8]=(x*17+y*103)&255;
            source_pixel[7:0]=(x*151+y*47)&255;
        end
    end
endfunction

function [23:0] reference_pixel;
    input integer output_x,output_y;
    reg [63:0] fixed_x,fixed_y;
    reg [23:0] p00,p01,p10,p11,result;
    integer x0,x1,y0,y1,fx,fy,channel_index,h0,h1,vertical;
    begin
        fixed_x=(64'd65536*(width_value-1)*output_x)/(OUT_W-1);
        fixed_y=(64'd65536*(height_value-1)*output_y)/(OUT_H-1);
        x0=fixed_x>>16;y0=fixed_y>>16;
        x1=(x0<width_value-1)?x0+1:x0;
        y1=(y0<height_value-1)?y0+1:y0;
        fx=(fixed_x>>8)&255;fy=(fixed_y>>8)&255;
        p00=source_pixel(x0,y0);p01=source_pixel(x1,y0);
        p10=source_pixel(x0,y1);p11=source_pixel(x1,y1);
        for(channel_index=0;channel_index<3;channel_index=channel_index+1) begin
            h0=((p00>>(channel_index*8))&255)*(256-fx)+
               ((p01>>(channel_index*8))&255)*fx;
            h1=((p10>>(channel_index*8))&255)*(256-fx)+
               ((p11>>(channel_index*8))&255)*fx;
            vertical=h0*(256-fy)+h1*fy;
            result[channel_index*8 +: 8]=(vertical+32768)>>16;
        end
        reference_pixel=result;
    end
endfunction

always @(negedge clk) begin
    cycle_count=cycle_count+1;
    if(active && !rst && !abort) begin
        dst_ready=(cycle_count%11!=0)&&(cycle_count%11!=1);
        src_valid=(input_count<width_value*height_value)&&(cycle_count%7!=0);
        col_index=input_count%width_value;row_index=input_count/width_value;
        src_pixel=source_pixel(col_index,row_index);
        src_last=(col_index==width_value-1);
        src_frame_last=(input_count==width_value*height_value-1);
    end else begin src_valid=0;dst_ready=0;end
end

always @(posedge clk) begin
    if(rst || abort) stalled=0;
    else if(active) begin
        if(src_valid && src_ready) input_count=input_count+1;
        if(stalled && (!dst_valid || {dst_pixel,dst_x,dst_y,dst_last,dst_frame_last}!==held_output))
            $fatal(1,"output changed while stalled");
        stalled=dst_valid && !dst_ready;
        if(stalled) held_output={dst_pixel,dst_x,dst_y,dst_last,dst_frame_last};
        if(dst_valid && dst_ready) begin
            expected_pixel=reference_pixel(output_count%OUT_W,output_count/OUT_W);
            if(((OUT_W>1 && OUT_H>1) && dst_pixel!==expected_pixel) || dst_x!=output_count%OUT_W || dst_y!=output_count/OUT_W)
                $fatal(1,"pixel mismatch at %0d: got %h expected %h",output_count,dst_pixel,expected_pixel);
            if(dst_last!==(output_count%OUT_W==OUT_W-1) ||
               dst_frame_last!==(output_count==OUT_W*OUT_H-1))
                $fatal(1,"output boundary mismatch at %0d",output_count);
            output_count=output_count+1;
        end
    end
end

task begin_frame;
    input integer image_width,image_height,image_pattern;
    begin
        @(negedge clk);active=0;rst=1;
        repeat(3) @(negedge clk);
        width_value=image_width;height_value=image_height;pattern=image_pattern;
        input_count=0;output_count=0;stalled=0;abort=0;rst=0;start=1;active=1;
        @(negedge clk);start=0;
    end
endtask
task run_frame;
    input integer image_width,image_height,image_pattern;
    begin
        begin_frame(image_width,image_height,image_pattern);
        wait(done);
        @(negedge clk);active=0;
        if(output_count!=OUT_W*OUT_H || input_count!=image_width*image_height)
            $fatal(1,"frame count mismatch input=%0d output=%0d",input_count,output_count);
        $display("PASS %0dx%0d -> %0dx%0d pattern=%0d",image_width,image_height,OUT_W,OUT_H,image_pattern);
    end
endtask

// 在消费拍证明无复位/无保持使能的数据仍与基线一致。
always @(negedge clk) if(!rst && !abort) begin
    if(dut.state==5'd10 || dut.state==5'd12 || dut.state==5'd14)
        if({dut.acc_r,dut.acc_g,dut.acc_b} !==
           {reference_dut.acc_r,reference_dut.acc_g,reference_dut.acc_b})
            $fatal(1,"accumulator consumption mismatch");
    if(dut.state==5'd11)
        if(dut.bottom_dout !== reference_dut.p11_q)
            $fatal(1,"stable BRAM corner consumption mismatch");
    if(dut.state==5'd15)
        if({dut.v_r,dut.v_g,dut.v_b} !== {reference_dut.v_r,reference_dut.v_g,reference_dut.v_b})
            $fatal(1,"vertical result consumption mismatch");
end

integer sweep_mode,sweep_state;
task sweep_restart;
    input integer target_state,reset_mode;
    begin
        begin_frame(17,13,target_state%4);
        wait(dut.state==target_state);
        @(negedge clk);active=0;
        if(reset_mode) rst=1;else abort=1;
        repeat(2) @(negedge clk);
        rst=0;abort=0;
        if(busy || dst_valid) $fatal(1,"sweep cancel failed");
        // 取消后无额外复位重启，旧数据必须不可见。
        input_count=0;output_count=0;stalled=0;width_value=1;height_value=1;
        pattern=(target_state+1)%4;start=1;active=1;
        @(negedge clk);start=0;
        wait(done);
        @(negedge clk);active=0;
        if(output_count!=OUT_W*OUT_H) $fatal(1,"sweep restart incomplete");
        $display("PASS cancel state=%0d reset=%0d and restart",target_state,reset_mode);
    end
endtask

initial begin
    if(FULL_SMOKE)begin
        run_frame(MAX_W,MAX_H,2);
        run_frame(17,13,0);
        run_frame(1,1,1);
        run_frame(17,13,3);
        $display("PASS official DSP full-resolution: four complete frames");
        $finish;
    end else if(RESET_SWEEP) begin
        for(sweep_mode=0;sweep_mode<2;sweep_mode=sweep_mode+1)
            for(sweep_state=1;sweep_state<=20;sweep_state=sweep_state+1)
                sweep_restart(sweep_state,sweep_mode);
        $display("PASS all 20 active states reset/abort and restart, cycle equivalence");
        $finish;
    end else begin
    repeat(3) @(negedge clk);
    rst=0;start=1;width_value=0;height_value=1;
    repeat(3) @(negedge clk);
    if(busy) $fatal(1,"accepted zero source width");
    width_value=MAX_W+1;
    repeat(3) @(negedge clk);
    if(busy) $fatal(1,"accepted oversized source width");
    width_value=1;height_value=MAX_H+1;
    repeat(3) @(negedge clk);
    if(busy) $fatal(1,"accepted oversized source height");
    start=0;
    begin_frame(MAX_W,MAX_H,0);
    repeat(4) @(negedge clk);
    abort=1;
    @(negedge clk);abort=0;active=0;
    if(busy || dst_valid) $fatal(1,"initialization abort did not return to idle");
    if(RUN_BOUNDARIES) begin
        run_frame(MAX_W,MAX_H,0);
        run_frame(MAX_W-1,MAX_H-1,2);
        run_frame(1,MAX_H,0);
        run_frame(MAX_W,1,0);
        run_frame(2,2,2);
    end
    run_frame(640,480,0);
    run_frame(17,13,3);
    run_frame(17,13,0);
    run_frame(1,1,1);
    begin_frame(17,13,2);
    // 1x1 输出只有一个像素，不能沿用普通帧等待第三个输出的条件。
    wait(output_count==((OUT_W*OUT_H>3)?3:1));
    @(negedge clk);abort=1;
    @(negedge clk);abort=0;active=0;
    if(busy || dst_valid) $fatal(1,"abort did not return to idle");
    // 不复位重新启动，确认旧坐标、相位和插值结果不会污染下一帧。
    @(negedge clk);input_count=0;output_count=0;stalled=0;start=1;active=1;
    @(negedge clk);start=0;
    wait(done);
    @(negedge clk);active=0;
    if(output_count!=OUT_W*OUT_H) $fatal(1,"restart frame incomplete");
    $display("PASS scaler arithmetic, source gaps, backpressure, abort and restart");
    $finish;
    end
end
initial begin
    #500000000;
    $fatal(1,"timeout");
end
endmodule
