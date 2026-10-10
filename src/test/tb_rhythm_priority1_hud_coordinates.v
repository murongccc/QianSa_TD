`timescale 1ns/1ps
// 全坐标域与主要页面对照，包含块 RAM 预取的左侧负两像素与地址回绕。
module tb_rhythm_priority1_hud_coordinates;
    reg clk=0,rst=1;
    reg [9:0] x=0,y=0;
    genvar g;
    generate for(g=0;g<2;g=g+1)begin: modes
        wire area,old_area;wire [9:0] rx,ry,old_rx,old_ry;
        rhythm_hud #(.BLOCK_CHARACTERS(g),.STREAM_METADATA(1)) dut(
            .clk(clk),.rst(rst),.frame_start(1'b0),.state(4'd0),.error_code(4'd0),.auto_mode(1'b0),
            .score(20'd0),.combo(16'd0),.max_combo(16'd0),.perfect_count(16'd0),.good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),
            .metadata_valid(1'b0),.metadata_data(8'd0),.metadata_address(),.title(192'd0),.difficulty(128'd0),
            .x(x),.y(y),.text_area(area),.rel_x(rx),.rel_y(ry),.character());
        rhythm_hud_baseline #(.BLOCK_CHARACTERS(g),.STREAM_METADATA(1)) reference(
            .clk(clk),.rst(rst),.frame_start(1'b0),.state(4'd0),.error_code(4'd0),.auto_mode(1'b0),
            .score(20'd0),.combo(16'd0),.max_combo(16'd0),.perfect_count(16'd0),.good_count(16'd0),.bad_count(16'd0),.miss_count(16'd0),
            .metadata_valid(1'b0),.metadata_data(8'd0),.metadata_address(),.title(192'd0),.difficulty(128'd0),
            .x(x),.y(y),.text_area(old_area),.rel_x(old_rx),.rel_y(old_ry),.character());
    end endgenerate
    integer xx,yy,s,cases=0;
    initial begin
        #2;clk=1;#2;clk=0;rst=0;
        for(s=0;s<4;s=s+1)begin
            case(s)
                0:begin modes[0].dut.saved_state=6;modes[0].reference.saved_state=6;modes[1].dut.saved_state=6;modes[1].reference.saved_state=6;end
                1:begin modes[0].dut.saved_state=10;modes[0].reference.saved_state=10;modes[1].dut.saved_state=10;modes[1].reference.saved_state=10;end
                2:begin modes[0].dut.saved_state=11;modes[0].reference.saved_state=11;modes[1].dut.saved_state=11;modes[1].reference.saved_state=11;end
                3:begin modes[0].dut.saved_state=2;modes[0].reference.saved_state=2;modes[1].dut.saved_state=2;modes[1].reference.saved_state=2;end
            endcase
            for(yy=0;yy<1024;yy=yy+1)for(xx=0;xx<1024;xx=xx+1)begin
                x=xx;y=yy;#1;
                if({modes[0].dut.text_area,modes[0].dut.rel_x,modes[0].dut.rel_y,modes[0].dut.read_address}!==
                   {modes[0].reference.text_area,modes[0].reference.rel_x,modes[0].reference.rel_y,modes[0].reference.read_address} ||
                   {modes[1].dut.text_area,modes[1].dut.rel_x,modes[1].dut.rel_y,modes[1].dut.read_address}!==
                   {modes[1].reference.text_area,modes[1].reference.rel_x,modes[1].reference.rel_y,modes[1].reference.read_address})
                    $fatal(1,"HUD coordinate mismatch state_case=%0d x=%0d y=%0d",s,xx,yy);
                cases=cases+2;
            end
        end
        $display("PASS HUD shared arithmetic: %0d full-domain state/mode coordinate comparisons",cases);$finish;
    end
    initial begin #5000000;$fatal(1,"HUD coordinates timeout");end
endmodule
