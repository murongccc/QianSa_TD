`timescale 1ns/1ps
// 原版渲染器/视频呈现与一拍 BRAM 读取同时逐像素比较。
module tb_fft_display_pixels;
reg clk=0,rst=1,de=0,vs=0,publish=0,front=0,published=0;
reg [6:0] write_index=0;
reg [7:0] write_data=0,radius=90;
reg write_enable=0;
reg [9:0] x=0,y=0;
reg [639:0] bars=0,building=0;
reg nonzero=0,ring_valid=0,video_valid=0;
wire [6:0] ring_address,video_address;
wire [7:0] ring_data,video_data;
wire on_new,on_old;
wire [23:0] ring_new,ring_old,rgb_new,rgb_old;
wire display_new,display_old;
reg [23:0] rgb_in=0;
integer r,i,j;
always #5 clk=~clk;
rhythm_block_ram #(.IMPLEMENT("9K"),.WIDTH(8),.ADDRESS_BITS(8),.DEPTH(256)) ring_ram(
    .write_clk(clk),.write_enable(write_enable),.write_address({!front,write_index}),.write_data(write_data),
    .read_clk(clk),.read_address({front,ring_address}),.read_data(ring_data));
rhythm_block_ram #(.IMPLEMENT("9K"),.WIDTH(8),.ADDRESS_BITS(8),.DEPTH(256)) video_ram(
    .write_clk(clk),.write_enable(write_enable),.write_address({!front,write_index}),.write_data(write_data),
    .read_clk(clk),.read_address({front,video_address}),.read_data(video_data));
always @(posedge clk)begin
    ring_valid<=published && ring_address<80;
    video_valid<=published && video_address<80;
    if(publish)begin front<=!front;published<=1;bars<=building;nonzero<=|building;end
end
ring_spectrum_renderer #(.REFERENCE_MODE(1),.BLOCK_BARS(1)) dut(
    .clk(clk),.rst(rst),.breath_radius(radius),.pixel_x(x),.pixel_y(y),.bars(640'd0),.bands(256'd0),
    .bars_read_address(ring_address),.bars_read_data(ring_data),.bars_read_valid(ring_valid),.bars_active(nonzero),
    .pixel_on(on_new),.pixel_rgb(ring_new));
baseline_ring_spectrum_renderer #(.REFERENCE_MODE(1)) golden(
    .clk(clk),.rst(rst),.breath_radius(radius),.pixel_x(x),.pixel_y(y),.bars(bars),.bands(256'd0),
    .pixel_on(on_old),.pixel_rgb(ring_old));
video_presentation #(.REFERENCE_SPECTRUM(1),.BLOCK_BARS(1),.INITIAL_WARMUP_FRAMES(0)) video(
    .clk(clk),.rst(rst),.display_valid(1'b1),.display_slot_async(3'd0),.display_switch_toggle_async(1'b0),
    .display_slot_applied_toggle(),.display_active(display_new),.brightness_level_async(3'd4),
    .image_brightness_async(7'd50),.image_contrast_async(7'd50),.image_sharpness_async(7'd0),
    .image_selected_async(2'd0),.image_select_toggle_async(1'b0),.image_adjust_toggle_async(1'b0),
    .spectrum_bands(256'd0),.spectrum_bars(640'd0),.spectrum_radius(radius),
    .spectrum_read_address(video_address),.spectrum_read_data(video_data),.spectrum_read_valid(video_valid),.spectrum_active(nonzero),
    .game_active(1'b0),.game_pixel_on(1'b0),.game_pixel_rgb(24'd0),.de(de),.vs(vs),.rgb_in(rgb_in),.rgb_out(rgb_new));
baseline_video_presentation #(.REFERENCE_SPECTRUM(1),.INITIAL_WARMUP_FRAMES(0)) old_video(
    .clk(clk),.rst(rst),.display_valid(1'b1),.display_slot_async(3'd0),.display_switch_toggle_async(1'b0),
    .display_slot_applied_toggle(),.display_active(display_old),.brightness_level_async(3'd4),
    .image_brightness_async(7'd50),.image_contrast_async(7'd50),.image_sharpness_async(7'd0),
    .image_selected_async(2'd0),.image_select_toggle_async(1'b0),.image_adjust_toggle_async(1'b0),
    .spectrum_bands(256'd0),.spectrum_bars(bars),.spectrum_radius(radius),
    .game_active(1'b0),.game_pixel_on(1'b0),.game_pixel_rgb(24'd0),.de(de),.vs(vs),.rgb_in(rgb_in),.rgb_out(rgb_old));
always @(posedge clk)begin
    #1;
    if(!rst)begin
        if({on_new,ring_new}!=={on_old,ring_old})$fatal(1,"ring pipeline mismatch radius=%d at %d,%d",radius,x,y);
        if({display_new,rgb_new}!=={display_old,rgb_old})$fatal(1,"video RGB/latency mismatch radius=%d at %d,%d",radius,x,y);
    end
end
initial begin
    repeat(4)@(negedge clk);rst=0;
    repeat(10)@(negedge clk);
    for(r=90;r<=110;r=r+1)begin
        // 下一银行构建期间继续读原前台，发布前后像素均参与对照。
        for(i=0;i<80;i=i+1)begin
            write_enable=1;write_index=i;write_data=r==90 ? 0 : i*37+r;
            building[i*8 +:8]=write_data;@(negedge clk);
        end
        write_enable=0;publish=1;vs=1;
        // 半径与发布数据同一个时钟沿更新，第一像素仍采用旧值。
        @(posedge clk);radius<=r;
        @(negedge clk);publish=0;vs=0;
        for(j=0;j<480;j=j+1)begin
            de=1;
            for(i=0;i<640;i=i+1)begin x=i;y=j;rgb_in={i[7:0],j[7:0],i[7:0]^j[7:0]};@(negedge clk);end
            de=0;repeat(2)@(negedge clk);
        end
        repeat(3)@(negedge clk);
    end
    $display("PASS pixel equivalence: ring and video 21 full frames, RGB/flags/latency, bank/radius publication");$finish;
end
initial begin #100000000;$fatal(1,"pixel timeout");end
endmodule
