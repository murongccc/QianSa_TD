`timescale 1ns/1ps
module tb_video_glow_blend;
reg clk=0;always #20 clk=~clk;
reg rst=1,de=0,vs=0;
reg [23:0] backdrop=24'h808080,source=0;
reg source_on=0,source_light=0;
reg [23:0] source_stage=0;reg on_stage=0,light_stage=0;
wire [23:0] rgb;
video_presentation #(.ENABLE_RHYTHM(1),.INITIAL_WARMUP_FRAMES(0)) dut(
    .clk(clk),.rst(rst),.display_valid(1'b1),.display_slot_async(3'd0),.display_switch_toggle_async(1'b0),
    .display_slot_applied_toggle(),.display_active(),.brightness_level_async(3'd4),
    .image_brightness_async(7'd50),.image_contrast_async(7'd50),.image_sharpness_async(7'd50),
    .image_selected_async(2'd0),.image_select_toggle_async(1'b0),.image_adjust_toggle_async(1'b0),
    .spectrum_bands(256'd0),.spectrum_bars(640'd0),.spectrum_radius(8'd100),
    .spectrum_read_address(),.spectrum_read_data(8'd0),.spectrum_read_valid(1'b0),.spectrum_active(1'b0),
    .game_active(1'b1),.game_pixel_on(on_stage),.game_pixel_light(light_stage),.game_pixel_rgb(source_stage),
    .touch_frame_packet(40'd0),.de(de),.vs(vs),.rgb_in(backdrop),.rgb_out(rgb));
reg [23:0] expected1=0,expected2=0,base1=0,base2=0;
reg d1=0,d2=0,check=0,l1=0,l2=0;
function [7:0] expected_background;
    input [7:0] value;
    begin expected_background=(value*5)/16;end
endfunction
wire [23:0] dimmed={expected_background(backdrop[23:16]),expected_background(backdrop[15:8]),expected_background(backdrop[7:0])};
always @(posedge clk)begin
    source_stage<=source;on_stage<=source_on;light_stage<=source_light;
    expected1<=source_on ? (source_light ? source | dimmed : source) : dimmed;
    expected2<=expected1;base1<=dimmed;base2<=base1;
    d1<=de;d2<=d1;l1<=source_on && source_light;l2<=l1;
end
integer checks=0,i;reg [31:0] rng=32'h8452679;
always @(negedge clk)if(check && d2)begin
    if(rgb!==expected2)$fatal(1,"composite alignment %h expected %h",rgb,expected2);
    if(l2 && (rgb[23:16]<base2[23:16] || rgb[15:8]<base2[15:8] || rgb[7:0]<base2[7:0]))
        $fatal(1,"glow darkened background");
    checks=checks+1;
end
initial begin
    repeat(4)@(negedge clk);rst=0;repeat(12)@(negedge clk);
    vs=1;@(negedge clk);vs=0;repeat(8)@(negedge clk);check=1;
    for(i=0;i<10000;i=i+1)begin
        @(negedge clk);de=1;
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};backdrop=i<256 ? {3{i[7:0]}} : rng[23:0];
        source={rng[7:0],rng[15:8],rng[23:16]};source_on=rng[24];source_light=rng[25];
        if(i%128==127)begin @(negedge clk);de=0;repeat(3)@(negedge clk);end
    end
    @(negedge clk);de=0;repeat(4)@(negedge clk);
    if(checks!=10000)$fatal(1,"sample count %0d",checks);
    $display("PASS glow compositor: 10000 two-stage pixels, bright-only channels, opaque notes and plain background");$finish;
end
initial begin #10000000;$fatal(1,"timeout");end
endmodule
