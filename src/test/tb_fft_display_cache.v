`timescale 1ns/1ps
// 直接控制缓存生产状态，覆盖真实 BRAM 的银行、同步延迟和同拍边界。
module tb_fft_display_cache;
reg clk=0,rst=1,frame_start=0;
reg [6:0] address=0;
wire [7:0] data,radius;
wire valid,active;
wire [639:0] unused_bars;
reg [639:0] expected=0,building=0;
reg published=0;
integer i;
always #5 clk=~clk;
reference_fft_spectrum #(.FFT_POINTS(512),.BLOCK_BARS(1)) dut(
    .clk(clk),.rst(rst),.sample_valid(1'b0),.sample_pcm(24'd0),.frame_start(frame_start),
    .bars(unused_bars),.breath_radius(radius),.bars_read_address(address),
    .bars_read_data(data),.bars_read_valid(valid),.bars_active(active));
task reads;
    integer a;
    begin
        for(a=0;a<128;a=a+1)begin
            @(negedge clk);address=a;
            @(posedge clk);#1;
            if(valid!==(published && a<80))$fatal(1,"read validity address=%d",a);
            if(data!==((published && a<80)?expected[a*8 +:8]:8'd0))$fatal(1,"read/order mismatch address=%d",a);
        end
        if(active!==(published && (|expected)))$fatal(1,"nonzero flag mismatch");
        if(unused_bars!==640'd0)$fatal(1,"block mode retained wide output");
    end
endtask
task begin_build;
    input publish_old;
    begin
        @(negedge clk);dut.state=5'd16;dut.scan_bin=9'd256;frame_start=publish_old;
        @(posedge clk);#1;
        if(publish_old)begin expected=building;published=1;end
        @(negedge clk);frame_start=0;
        building=0;
    end
endtask
task write_bars;
    input integer pattern;
    input integer count;
    input last_frame;
    integer n;
    reg [7:0] value;
    reg previous_bank;
    begin
        for(n=0;n<count;n=n+1)begin
            value=pattern==0 ? 8'd0 : (n*37+pattern);
            @(negedge clk);dut.state=5'd23;dut.bar_index=n;dut.bar_level=value;
            frame_start=last_frame && n==79;
            building[n*8 +:8]=value;
            previous_bank=dut.block_bars.front_bank;
            @(posedge clk);#1;
            if(last_frame && n==79 && dut.block_bars.front_bank!==previous_bank)
                $fatal(1,"last write incorrectly published on same edge");
            if(active!==(published && (|expected)))$fatal(1,"front changed while writing");
        end
        @(negedge clk);frame_start=0;dut.state=0;
    end
endtask
task publish;
    begin
        @(negedge clk);frame_start=1;
        @(posedge clk);#1;expected=building;published=1;
        @(negedge clk);frame_start=0;
    end
endtask
task reset_cache;
    begin
        @(negedge clk);rst=1;frame_start=0;published=0;expected=0;building=0;
        repeat(3)@(negedge clk);rst=0;dut.state=0;
    end
endtask
initial begin
    reset_cache;reads;
    begin_build(0);write_bars(11,80,1);reads;publish;reads;
    // 已发布前台保持；一份待发布结果在开始新构建时失效。
    begin_build(0);write_bars(23,80,0);
    begin_build(0);write_bars(41,80,0);reads;publish;reads;
    // 发布旧结果与启动新构建同拍，后续写入不得覆盖新前台。
    begin_build(0);write_bars(57,80,0);
    begin_build(1);write_bars(73,80,1);reads;publish;reads;
    begin_build(0);write_bars(0,80,0);publish;reads;
    begin_build(0);write_bars(17,20,0);reset_cache;reads;
    begin_build(0);write_bars(29,80,0);reset_cache;reads;
    begin_build(0);write_bars(39,80,0);publish;reads;
    $display("PASS cache: 0..127 reads, order, sync, overwrite, simultaneous edges, silence, reset/restart");$finish;
end
initial begin #1000000;$fatal(1,"cache timeout");end
endmodule
