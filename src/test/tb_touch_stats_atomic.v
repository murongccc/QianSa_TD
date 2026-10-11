`timescale 1ns/1ps
// 统计计数每拍改变，验证四个十六进制字符来自同一次16位取样。
module tb_touch_stats_atomic;
reg clk=0;always #10 clk=~clk;
reg rst=1;
reg [15:0] counter=16'd0;
wire txd;
wire [15:0] sum_count=counter^16'ha55a;
wire [15:0] format_count=counter+16'h1234;
wire [15:0] gap_count=counter-16'h0101;
wire [15:0] rx_count=counter^16'hffff;
wire [15:0] timeout_count={counter[7:0],counter[15:8]};
wire [15:0] ack_count=counter+16'h2345;
reg [15:0] expected[0:8];
reg [7:0] bytes[0:82];
integer count=0,bit_index,field_index,n;
reg [7:0] byte_value;
reg [15:0] parsed;
touch_serial_monitor #(.CLK_HZ(3686400)) dut(
    .lane_valid(1'b0),.lane_down(4'd0),.lane_press(4'd0),.lane_release(4'd0),.lane_fault(1'b0),.lane_monitor_overflow(),
    .clk(clk),.rst(rst),.update_valid(1'b0),.a_id(4'd0),.a_down(1'b0),.a_x(16'd0),.a_y(16'd0),
    .b_id(4'd0),.b_down(1'b0),.b_x(16'd0),.b_y(16'd0),.press_mask(2'd0),.release_mask(2'd0),.frame_seq(8'd0),
    .good_count(counter),.checksum_error_count(sum_count),.format_error_count(format_count),.sequence_gap_count(gap_count),
    .timeout_count(timeout_count),.uart_error_count(rx_count),.ack_count(ack_count),.echo_valid(1'b0),.echo_data(8'd0),
    .uart_txd(txd),.monitor_drop_count(),.echo_drop_count());
always @(posedge clk)begin
    if(rst)counter<=16'd0;
    else begin
        counter<=counter+16'h0011;
        if(dut.line_busy && dut.stats_line && dut.tx_ready && dut.stats_state==3'd3)case(dut.stats_field)
            4'd0:expected[0]=counter;
            4'd1:expected[1]=sum_count;
            4'd2:expected[2]=format_count;
            4'd3:expected[3]=gap_count;
            4'd4:expected[4]=rx_count;
            4'd5:expected[5]=timeout_count;
            4'd6:expected[6]=ack_count;
            4'd7:expected[7]=16'd0;
            4'd8:expected[8]=16'd0;
            default:;
        endcase
    end
end
always begin
    @(negedge txd);repeat(16)@(negedge clk);
    for(bit_index=0;bit_index<8;bit_index=bit_index+1)begin repeat(32)@(negedge clk);byte_value[bit_index]=txd;end
    repeat(32)@(negedge clk);
    if(txd!==1'b1)begin $display("FAIL statistics UART stop");$stop;end
    if(count<83)bytes[count]=byte_value;
    count=count+1;
end
function [3:0] decode_hex;
    input [7:0] c;
    begin if(c>=8'h30 && c<=8'h39)decode_hex=c-8'h30;else decode_hex=c-8'h41+8'd10;end
endfunction
initial begin #100000000;$display("FAIL statistics timeout");$stop;end
initial begin
    repeat(4)@(negedge clk);rst=0;
    wait(count==83);
    for(field_index=0;field_index<9;field_index=field_index+1)begin
        case(field_index)
            0:n=5;1:n=14;2:n=23;3:n=32;4:n=40;5:n=48;6:n=57;7:n=67;default:n=77;
        endcase
        parsed={decode_hex(bytes[n]),decode_hex(bytes[n+1]),decode_hex(bytes[n+2]),decode_hex(bytes[n+3])};
        if(parsed!==expected[field_index])begin
            $display("FAIL torn statistics field %0d expected=%h got=%h",field_index,expected[field_index],parsed);$stop;
        end
    end
    $display("PASS statistics: rapidly changing counters, per-field atomic hexadecimal output");$finish;
end
endmodule
