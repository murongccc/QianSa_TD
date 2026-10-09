`timescale 1ns/1ps
// 压力验证监视队列：拥堵显式计数，已入队快照不会被后续坐标覆盖。
module tb_touch_serial_monitor;
reg clk=1'b0;
always #10 clk=~clk;
reg rst=1'b1,update_valid=1'b0,echo_valid=1'b0;
reg [7:0] frame_seq=8'd0,echo_data=8'd0;
reg [15:0] a_x=16'd0;
wire uart_txd;
wire [15:0] monitor_drop_count,echo_drop_count;
touch_serial_monitor #(.CLK_HZ(3686400)) dut(
    .clk(clk),.rst(rst),.update_valid(update_valid),
    .a_id(4'd1),.a_down(1'b1),.a_x(a_x),.a_y(16'h2222),
    .b_id(4'd0),.b_down(1'b0),.b_x(16'd0),.b_y(16'd0),
    .press_mask(2'b01),.release_mask(2'b00),.frame_seq(frame_seq),
    .good_count(16'd20),.checksum_error_count(16'd0),.format_error_count(16'd0),.sequence_gap_count(16'd0),
    .timeout_count(16'd0),.uart_error_count(16'd0),.ack_count(16'd0),
    .echo_valid(echo_valid),.echo_data(echo_data),.uart_txd(uart_txd),
    .monitor_drop_count(monitor_drop_count),.echo_drop_count(echo_drop_count));
reg [7:0] console[0:1023];
reg [7:0] sample;
integer count=0,errors=0,bit_index,i,j;
task fail;
    input [511:0] message;
    begin $display("FAIL %0s count=%0d drop=%0d echo=%0d",message,count,monitor_drop_count,echo_drop_count); $stop; end
endtask
always begin
    @(negedge uart_txd);
    repeat(16) @(negedge clk);
    if(uart_txd!==1'b0) errors=errors+1;
    for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
        repeat(32) @(negedge clk); sample[bit_index]=uart_txd;
    end
    repeat(32) @(negedge clk);
    if(uart_txd!==1'b1) errors=errors+1;
    console[count]=sample; count=count+1;
end
task check_text;
    input integer offset;
    input [1023:0] text;
    input integer length;
    integer k;
    begin
        for(k=0;k<length;k=k+1)
            if(console[offset+k]!==text[(length-1-k)*8 +: 8]) begin
                $display("Byte mismatch at %0d expected=%h actual=%h",offset+k,text[(length-1-k)*8 +: 8],console[offset+k]);
                fail("queued console text");
            end
    end
endtask
initial begin #100000000; fail("timeout"); end
initial begin
    repeat(5) @(negedge clk); rst=1'b0;
    for(i=1;i<=20;i=i+1) begin
        @(negedge clk); update_valid=1'b1; frame_seq=i[7:0]; a_x=i[15:0];
    end
    @(negedge clk); update_valid=1'b0; a_x=16'habcd;
    repeat(100) @(negedge clk);
    for(i=0;i<20;i=i+1) begin
        @(negedge clk); echo_valid=1'b1; echo_data=8'h61+i[7:0];
    end
    @(negedge clk); echo_valid=1'b0;
    repeat(3800000) @(negedge clk);
    if(monitor_drop_count!=16'd15 || echo_drop_count!=16'd4 || errors!=0 || count!=329) fail("overflow counts/framing");
    check_text(0,"T 01 A:1,1,0001,2222 B:0,0,0000,0000 P:1 R:0\015\012",46);
    for(j=0;j<16;j=j+1) if(console[46+j]!==8'h61+j[7:0]) fail("echo queue order");
    check_text(62,"T 02 A:1,1,0002,2222 B:0,0,0000,0000 P:1 R:0\015\012",46);
    check_text(108,"T 03 A:1,1,0003,2222 B:0,0,0000,0000 P:1 R:0\015\012",46);
    check_text(154,"T 04 A:1,1,0004,2222 B:0,0,0000,0000 P:1 R:0\015\012",46);
    check_text(200,"T 05 A:1,1,0005,2222 B:0,0,0000,0000 P:1 R:0\015\012",46);
    check_text(246,"S ok=0014 sum=0000 fmt=0000 gap=0000 rx=0000 to=0000 ack=0000 drop=000F echo=0004\015\012",83);
    $display("PASS monitor: overflow diagnostics, immutable FIFO snapshots, line-atomic echo, periodic statistics");
    $finish;
end
endmodule
