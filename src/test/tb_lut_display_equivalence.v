`timescale 1ns/1ps
module tb_lut_display_equivalence;
    reg clk=0,rst=1,frame_start=0,auto_mode=1;
    reg [3:0] state=0,error=0;
    reg [9:0] x=0,y=0;
    reg [7:0] radius=90;
    reg [639:0] bars=0;
    reg [255:0] bands=0;
    wire on_dsp,on_lut;
    wire [23:0] rgb_dsp,rgb_lut;
    wire [7:0] char_rom,char_lut;
    wire area_rom,area_lut;
    wire [9:0] rx0,ry0,rx1,ry1;
    integer s,m,i,j,r;
    always #5 clk=~clk;
    ring_spectrum_renderer #(.REFERENCE_MODE(1),.DSP_GEOMETRY(1)) dsp(.bars_read_address(),.bars_read_data(8'd0),.bars_read_valid(1'b0),.bars_active(1'b0),
        .clk(clk),.rst(rst),.breath_radius(radius),.pixel_x(x),.pixel_y(y),.bars(bars),.bands(bands),.pixel_on(on_dsp),.pixel_rgb(rgb_dsp));
    ring_spectrum_renderer #(.REFERENCE_MODE(1),.DSP_GEOMETRY(0)) lut(.bars_read_address(),.bars_read_data(8'd0),.bars_read_valid(1'b0),.bars_active(1'b0),
        .clk(clk),.rst(rst),.breath_radius(radius),.pixel_x(x),.pixel_y(y),.bars(bars),.bands(bands),.pixel_on(on_lut),.pixel_rgb(rgb_lut));
    rhythm_hud #(.BLOCK_CHARACTERS(1),.TEXT_ROM(1)) rom_hud(
        .clk(clk),.rst(rst),.frame_start(frame_start),.state(state),.error_code(error),.auto_mode(auto_mode),
        .score(20'd987654),.combo(16'd321),.max_combo(16'd432),.perfect_count(16'd543),.good_count(16'd65),.bad_count(16'd7),.miss_count(16'd8),
        .metadata_valid(1'b0),.metadata_data(8'd0),.metadata_address(),.title(192'h32313039383736353433323130393837363534333231303938),.difficulty(128'h46454443424139383736353433323130),
        .x(x),.y(y),.text_area(area_rom),.rel_x(rx0),.rel_y(ry0),.character(char_rom));
    rhythm_hud #(.BLOCK_CHARACTERS(1),.TEXT_ROM(0)) lut_hud(
        .clk(clk),.rst(rst),.frame_start(frame_start),.state(state),.error_code(error),.auto_mode(auto_mode),
        .score(20'd987654),.combo(16'd321),.max_combo(16'd432),.perfect_count(16'd543),.good_count(16'd65),.bad_count(16'd7),.miss_count(16'd8),
        .metadata_valid(1'b0),.metadata_data(8'd0),.metadata_address(),.title(192'h32313039383736353433323130393837363534333231303938),.difficulty(128'h46454443424139383736353433323130),
        .x(x),.y(y),.text_area(area_lut),.rel_x(rx1),.rel_y(ry1),.character(char_lut));
    wire write0=rom_hud.character_we,write1=lut_hud.character_we;
    wire [7:0] wa0=rom_hud.address,wa1=lut_hud.address;
    wire [7:0] wd0=rom_hud.character_write,wd1=lut_hud.character_write;
    always @(posedge clk)if(!rst && (write0 || write1))begin
        if({write0,wa0,wd0}!=={write1,wa1,wd1})$fatal(1,"HUD write mismatch state=%d mode=%d address=%d data=%h/%h",state,auto_mode,wa0,wd0,wd1);
    end
    always @(negedge clk)if(!rst)begin
        if({on_dsp,rgb_dsp}!=={on_lut,rgb_lut})$fatal(1,"ring pixel mismatch at %d,%d",x,y);
        if({area_rom,rx0,ry0,char_rom}!=={area_lut,rx1,ry1,char_lut})$fatal(1,"HUD pixel/character mismatch");
    end
    initial begin
        repeat(3)@(negedge clk);rst=0;
        for(m=0;m<2;m=m+1)for(s=0;s<16;s=s+1)begin
            state=s;error=s;auto_mode=m;frame_start=1;
            @(negedge clk);frame_start=0;
            repeat(500)@(negedge clk);
        end
        // 每个像素遍历半径、强弱柱、静音及帧变化；坐标覆盖角度分界两侧。
        for(r=90;r<=110;r=r+1)begin
            radius=r;
            for(i=0;i<80;i=i+1)bars[i*8 +:8]=(r==90)?0:(i*37+r);
            for(j=0;j<480;j=j+1)for(i=0;i<640;i=i+1)begin
                x=i;y=j;@(negedge clk);
            end
        end
        repeat(3)@(negedge clk);
        $display("PASS HUD 32 state/mode snapshots, every character/pixel; ring 21 full frames exact");$finish;
    end
    initial begin #100000000;$fatal(1,"display equivalence timeout");end
endmodule
