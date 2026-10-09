`timescale 1ns/1ps
// 真实串口位流验证自动应答、双点文本及原快捷键；时钟/波特率等比例加速。
module tb_touch_uart_integration;
localparam integer CLK_HZ=3686400;
localparam integer BIT_TICKS=32;
reg clk=1'b0;
always #10 clk=~clk;
reg rst=1'b1, touch_drive=1'b1, pc_drive=1'b1;
wire touch_txd,uart_txd,update_valid,a_down,b_down;
wire [3:0] a_id,b_id;
wire [15:0] a_x,a_y,b_x,b_y;
wire [1:0] press_mask,release_mask;
wire [7:0] frame_seq;
wire [15:0] good_count,checksum_error_count,format_error_count,sequence_gap_count,timeout_count,uart_error_count,ack_count;
wire [15:0] monitor_drop_count,echo_drop_count;
wire echo_valid;
wire [7:0] echo_data;
wire [2:0] brightness,volume,playback;
wire playback_toggle;
reg [7:0] capture[0:61975];
reg [7:0] pc_bytes[0:4095];
reg [7:0] ack_bytes[0:63];
integer pc_count=0,ack_bytes_count=0,console_errors=0,ack_errors=0;
integer i;
ch9350_touch_input #(.CLK_HZ(CLK_HZ)) dut(
    .clk(clk),.rst(rst),.touch_rxd(touch_drive),.touch_txd(touch_txd),.update_valid(update_valid),
    .a_id(a_id),.a_down(a_down),.a_x(a_x),.a_y(a_y),.b_id(b_id),.b_down(b_down),.b_x(b_x),.b_y(b_y),
    .press_mask(press_mask),.release_mask(release_mask),.frame_seq(frame_seq),
    .good_count(good_count),.checksum_error_count(checksum_error_count),.format_error_count(format_error_count),
    .sequence_gap_count(sequence_gap_count),.timeout_count(timeout_count),.uart_error_count(uart_error_count),.ack_count(ack_count));
uart_command_control #(.CLK_HZ(CLK_HZ)) commands(
    .clk(clk),.rst(rst),.uart_rxd(pc_drive),.brightness_level(brightness),.volume_level(volume),
    .playback_command(playback),.playback_command_toggle(playback_toggle),.echo_valid(echo_valid),.echo_data(echo_data));
touch_serial_monitor #(.CLK_HZ(CLK_HZ)) monitor(
    .clk(clk),.rst(rst),.update_valid(update_valid),
    .a_id(a_id),.a_down(a_down),.a_x(a_x),.a_y(a_y),.b_id(b_id),.b_down(b_down),.b_x(b_x),.b_y(b_y),
    .press_mask(press_mask),.release_mask(release_mask),.frame_seq(frame_seq),
    .good_count(good_count),.checksum_error_count(checksum_error_count),.format_error_count(format_error_count),
    .sequence_gap_count(sequence_gap_count),.timeout_count(timeout_count),.uart_error_count(uart_error_count),.ack_count(ack_count),
    .echo_valid(echo_valid),.echo_data(echo_data),.uart_txd(uart_txd),.monitor_drop_count(monitor_drop_count),.echo_drop_count(echo_drop_count));
task fail;
    input [511:0] message;
    begin $display("FAIL %0s pc=%0d ack=%0d",message,pc_count,ack_bytes_count); $stop; end
endtask
task send_touch_byte;
    input [7:0] data;
    input integer ticks;
    input stop_ok;
    integer j;
    begin
        @(negedge clk); touch_drive=1'b0;
        repeat(ticks) @(negedge clk);
        for(j=0;j<8;j=j+1) begin touch_drive=data[j]; repeat(ticks) @(negedge clk); end
        touch_drive=stop_ok;
        repeat(ticks) @(negedge clk);
        touch_drive=1'b1;
    end
endtask
task send_pc_byte;
    input [7:0] data;
    integer j;
    begin
        @(negedge clk); pc_drive=1'b0;
        repeat(BIT_TICKS) @(negedge clk);
        for(j=0;j<8;j=j+1) begin pc_drive=data[j]; repeat(BIT_TICKS) @(negedge clk); end
        pc_drive=1'b1;
        repeat(BIT_TICKS) @(negedge clk);
    end
endtask
task send_frame;
    input integer n;
    integer j;
    begin for(j=0;j<61;j=j+1) send_touch_byte(capture[(n-1)*61+j],BIT_TICKS,1'b1); end
endtask
task expect_text;
    input [1023:0] text;
    input integer length;
    integer start,j;
    reg found,match;
    begin
        found=1'b0;
        for(start=0;start<=pc_count-length;start=start+1) begin
            match=1'b1;
            for(j=0;j<length;j=j+1) if(pc_bytes[start+j]!==text[(length-1-j)*8 +: 8]) match=1'b0;
            if(match) found=1'b1;
        end
        if(!found) begin $display("Expected text: %0s",text); fail("missing/corrupted console line"); end
    end
endtask
// 独立外部接收器，按发送位中心采样，不使用 DUT 接收器作为参考。
reg [7:0] pc_sample,ack_sample;
integer pc_bit,ack_bit;
always begin
    @(negedge uart_txd);
    repeat(BIT_TICKS/2) @(negedge clk);
    if(uart_txd!==1'b0) console_errors=console_errors+1;
    for(pc_bit=0;pc_bit<8;pc_bit=pc_bit+1) begin
        repeat(BIT_TICKS) @(negedge clk); pc_sample[pc_bit]=uart_txd;
    end
    repeat(BIT_TICKS) @(negedge clk);
    if(uart_txd!==1'b1) console_errors=console_errors+1;
    pc_bytes[pc_count]=pc_sample; pc_count=pc_count+1;
end
always begin
    @(negedge touch_txd);
    repeat(BIT_TICKS/2) @(negedge clk);
    if(touch_txd!==1'b0) ack_errors=ack_errors+1;
    for(ack_bit=0;ack_bit<8;ack_bit=ack_bit+1) begin
        repeat(BIT_TICKS) @(negedge clk); ack_sample[ack_bit]=touch_txd;
    end
    repeat(BIT_TICKS) @(negedge clk);
    if(touch_txd!==1'b1) ack_errors=ack_errors+1;
    ack_bytes[ack_bytes_count]=ack_sample; ack_bytes_count=ack_bytes_count+1;
end
reg [87:0] expected_ack=88'h57ab1200000000ff800020;
initial begin #150000000; fail("timeout"); end
initial begin
    $readmemh("src/test/data/touch_double.hex",capture);
    repeat(5) @(negedge clk); rst=1'b0;
    repeat(5) @(negedge clk);
    // 短毛刺应被起始位确认滤掉。
    touch_drive=1'b0; repeat(2) @(negedge clk); touch_drive=1'b1; repeat(40) @(negedge clk);
    // 两个请求一个早于应答完成；同时验证输入波特率约 +/-3% 的偏差。
    send_touch_byte(8'h57,31,1'b1); send_touch_byte(8'hab,31,1'b1);
    send_touch_byte(8'h82,31,1'b1); send_touch_byte(8'ha3,31,1'b1);
    send_touch_byte(8'h57,33,1'b1); send_touch_byte(8'hab,33,1'b1);
    send_touch_byte(8'h82,33,1'b1); send_touch_byte(8'ha3,33,1'b1);
    repeat(8000) @(negedge clk);
    if(ack_bytes_count!=22 || ack_count!=16'd2 || ack_errors!=0 || uart_error_count!=16'd0) fail("automatic ACK");
    for(i=0;i<22;i=i+1) if(ack_bytes[i]!==expected_ack[(10-(i%11))*8 +: 8]) fail("ACK bytes");
    fork
        begin send_frame(1); send_frame(2); send_frame(818); send_frame(819); send_frame(1016); end
        begin
            wait(update_valid); repeat(100) @(negedge clk);
            send_pc_byte("B"); send_pc_byte("V"); send_pc_byte("N"); send_pc_byte("A");
            send_pc_byte("1"); send_pc_byte("2"); send_pc_byte("3"); send_pc_byte("4");
        end
    join
    send_touch_byte(8'h55,BIT_TICKS,1'b0);
    repeat(BIT_TICKS*2) @(negedge clk);
    if(good_count!=16'd5 || uart_error_count!=16'd1 || a_down || b_down || checksum_error_count!=16'd0 || format_error_count!=16'd0)
        fail("serial parser state/errors");
    if(brightness!=3'd5 || volume!=3'd5 || playback!=3'd6 || playback_toggle!=1'b0) fail("legacy control commands");
    repeat(3700000) @(negedge clk);
    if(console_errors!=0 || monitor_drop_count!=16'd0 || echo_drop_count!=16'd0) fail("monitor UART/drop");
    expect_text("T 40 A:1,1,0C10,1980 B:0,0,0000,0000 P:1 R:0\015\012",46);
    expect_text("T 41 A:1,1,0C10,1980 B:2,1,0BD0,0FC0 P:2 R:0\015\012",46);
    expect_text("T 71 A:1,1,29B0,18B0 B:2,0,2AF0,0F90 P:0 R:2\015\012",46);
    expect_text("T 37 A:1,0,29D0,18B0 B:2,0,2AF0,0F90 P:0 R:1\015\012",46);
    expect_text("BVNA1234",8);
    expect_text("S ok=0005 sum=0000 fmt=0000 gap=0002 rx=0001 to=0000 ack=0002 drop=0000 echo=0000\015\012",83);
    $display("PASS UART integration: ACK bytes, baud skew, false start, bad stop, touch lines, statistics and legacy controls");
    $finish;
end
endmodule
