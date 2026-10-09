`timescale 1ns/1ps
// 严格对照未修改的视频呈现：除命中的十字像素外，RGB 每拍一致。
module tb_touch_video_overlay;
reg clk=0;always #10 clk=~clk;
reg rst=1,de=0,vs=0,game_active=0;
reg [23:0] rgb_in=24'h406080;
reg [39:0] packet=0;
reg [9:0] driver_x=0,driver_y=0;
wire [23:0] rgb_marked,rgb_disabled,rgb_baseline;
wire display_marked,display_baseline;
video_presentation #(.INITIAL_WARMUP_FRAMES(0),.ENABLE_RHYTHM(1),.ENABLE_TOUCH_MARKERS(1)) marked(
    .clk(clk),.rst(rst),.display_valid(1'b1),.display_slot_async(3'd0),.display_switch_toggle_async(1'b0),
    .display_slot_applied_toggle(),.display_active(display_marked),.brightness_level_async(3'd4),
    .image_brightness_async(7'd50),.image_contrast_async(7'd50),.image_sharpness_async(7'd50),.image_selected_async(2'd0),
    .image_select_toggle_async(1'b0),.image_adjust_toggle_async(1'b0),
    .spectrum_bands(256'd0),.spectrum_bars(640'd0),.spectrum_radius(8'd90),
    .spectrum_read_address(),.spectrum_read_data(8'd0),.spectrum_read_valid(1'b0),.spectrum_active(1'b0),
    .game_active(game_active),.game_pixel_on(1'b1),.game_pixel_rgb(24'h123456),.touch_frame_packet(packet),
    .de(de),.vs(vs),.rgb_in(rgb_in),.rgb_out(rgb_marked));
video_presentation #(.INITIAL_WARMUP_FRAMES(0),.ENABLE_RHYTHM(1),.ENABLE_TOUCH_MARKERS(0)) disabled(
    .clk(clk),.rst(rst),.display_valid(1'b1),.display_slot_async(3'd0),.display_switch_toggle_async(1'b0),
    .display_slot_applied_toggle(),.display_active(),.brightness_level_async(3'd4),
    .image_brightness_async(7'd50),.image_contrast_async(7'd50),.image_sharpness_async(7'd50),.image_selected_async(2'd0),
    .image_select_toggle_async(1'b0),.image_adjust_toggle_async(1'b0),
    .spectrum_bands(256'd0),.spectrum_bars(640'd0),.spectrum_radius(8'd90),
    .spectrum_read_address(),.spectrum_read_data(8'd0),.spectrum_read_valid(1'b0),.spectrum_active(1'b0),
    .game_active(game_active),.game_pixel_on(1'b1),.game_pixel_rgb(24'h123456),.touch_frame_packet(packet),
    .de(de),.vs(vs),.rgb_in(rgb_in),.rgb_out(rgb_disabled));
baseline_video_presentation #(.INITIAL_WARMUP_FRAMES(0),.ENABLE_RHYTHM(1)) baseline(
    .clk(clk),.rst(rst),.display_valid(1'b1),.display_slot_async(3'd0),.display_switch_toggle_async(1'b0),
    .display_slot_applied_toggle(),.display_active(display_baseline),.brightness_level_async(3'd4),
    .image_brightness_async(7'd50),.image_contrast_async(7'd50),.image_sharpness_async(7'd50),.image_selected_async(2'd0),
    .image_select_toggle_async(1'b0),.image_adjust_toggle_async(1'b0),
    .spectrum_bands(256'd0),.spectrum_bars(640'd0),.spectrum_radius(8'd90),
    .spectrum_read_address(),.spectrum_read_data(8'd0),.spectrum_read_valid(1'b0),.spectrum_active(1'b0),
    .game_active(game_active),.game_pixel_on(1'b1),.game_pixel_rgb(24'h123456),
    .de(de),.vs(vs),.rgb_in(rgb_in),.rgb_out(rgb_baseline));
integer scenario,x,y,checked=0,marked_pixels=0;
reg previous_a=0,previous_b=0,previous_de=0;
reg current_a,current_b;
reg [23:0] expected;
function hit;
    input integer px,py,cx,cy;
    input down;
    integer dx,dy;
    begin dx=px-cx;dy=py-cy;if(dx<0)dx= -dx;if(dy<0)dy= -dy;
        hit=de && down && ((dx==0 && dy<=15) || (dy==0 && dx<=15));end
endfunction
always @(posedge clk)begin
    if(rst)begin previous_a=0;previous_b=0;previous_de=0;end
    else begin
        current_a=hit(driver_x,driver_y,packet[37:28],packet[27:19],packet[39]);
        current_b=hit(driver_x,driver_y,packet[18:9],packet[8:0],packet[38]);
        #1;
        if(rgb_disabled!==rgb_baseline || display_marked!==display_baseline)begin
            $display("FAIL disabled overlay/baseline startup equivalence");$stop;
        end
        expected=(previous_a || previous_b) ? {{8{previous_b}},{8{previous_a}},8'hff} : rgb_baseline;
        if(rgb_marked!==expected)begin
            $display("FAIL overlay pipeline scenario=%0d x=%0d y=%0d expected=%h actual=%h",scenario,driver_x,driver_y,expected,rgb_marked);$stop;
        end
        if(previous_de)begin checked=checked+1;if(previous_a || previous_b)marked_pixels=marked_pixels+1;end
        previous_a=current_a;previous_b=current_b;previous_de=de;
    end
end
task frame_begin;
    begin @(negedge clk);vs=1;de=0;repeat(2)@(negedge clk);vs=0;repeat(24)@(negedge clk);end
endtask
initial begin #100000000; $display("FAIL video timeout");$stop;end
initial begin
    repeat(5)@(negedge clk);rst=0;repeat(5)@(negedge clk);
    for(scenario=0;scenario<5;scenario=scenario+1)begin
        case(scenario)
            0:begin packet={2'b11,10'd0,9'd0,10'd639,9'd479};game_active=0;end
            1:begin packet={2'b11,10'd319,9'd241,10'd310,9'd226};game_active=1;end
            2:begin packet={2'b11,10'd320,9'd240,10'd320,9'd240};game_active=1;end
            3:begin packet={2'b01,10'd320,9'd240,10'd639,9'd0};game_active=0;end
            default:begin packet={2'b00,10'd320,9'd240,10'd639,9'd0};game_active=0;end
        endcase
        frame_begin;
        for(y=0;y<480;y=y+1)begin
            for(x=0;x<640;x=x+1)begin
                @(negedge clk);de=1;driver_x=x[9:0];driver_y=y[9:0];rgb_in={x[7:0],y[7:0],8'h70};
            end
            @(negedge clk);de=0;repeat(4)@(negedge clk);
        end
    end
    repeat(4)@(negedge clk);
    if(checked!=1536000 || marked_pixels==0)begin $display("FAIL video coverage %0d",checked);$stop;end
    $display("PASS touch video: %0d active pixels, two-cycle alignment, first/last rows, image/game preservation, colors and release",checked);
    $finish;
end
endmodule
