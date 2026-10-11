`timescale 1ns/1ps
module tb_touch_lane_serial;
reg clk=0;always #10 clk=~clk;
reg rst=1,valid=0,fault=0;reg [3:0] d=3,p=3,r=0;
wire drop;wire tx;wire [15:0] md,ed;
touch_serial_monitor #(.CLK_HZ(1000000),.BAUD(100000),.SNAPSHOT_MS(50)) dut(
    .clk(clk),.rst(rst),.update_valid(1'b0),
    .a_id(4'd0),.a_down(1'b0),.a_x(16'd0),.a_y(16'd0),.b_id(4'd0),.b_down(1'b0),.b_x(16'd0),.b_y(16'd0),
    .press_mask(2'd0),.release_mask(2'd0),.frame_seq(8'd0),
    .good_count(16'd0),.checksum_error_count(16'd0),.format_error_count(16'd0),.sequence_gap_count(16'd0),
    .timeout_count(16'd0),.uart_error_count(16'd0),.ack_count(16'd0),
    .lane_valid(valid),.lane_down(d),.lane_press(p),.lane_release(r),.lane_fault(fault),.lane_monitor_overflow(drop),
    .echo_valid(1'b0),.echo_data(8'd0),.uart_txd(tx),.monitor_drop_count(md),.echo_drop_count(ed));
reg [8*23-1:0] line=0;integer chars=0,lines=0;
always @(posedge clk)if(!rst && dut.tx_valid && dut.tx_ready)begin
    line={line[8*22-1:0],dut.tx_data};chars=chars+1;
    if(dut.tx_data==10)begin
        if(chars==23)begin
            if(lines==0 && line!=={"L D:3 P:3 R:0 Q:0 O:0",8'h0d,8'h0a})$fatal(1,"L line format %s",line);
            if(lines==1 && line!=={"L D:2 P:0 R:1 Q:1 O:1",8'h0d,8'h0a})$fatal(1,"L fault/drop format %s",line);
            lines=lines+1;
        end
        chars=0;
    end
end
task push;begin @(negedge clk);valid=1;@(negedge clk);valid=0;end endtask
initial begin
    repeat(4)@(negedge clk);rst=0;push;wait(lines==1);
    d=2;p=0;r=1;fault=1;push;push;
    wait(lines==2);if(!drop || md || ed)$fatal(1,"diagnostic congestion not separated");
    $display("PASS lane serial formatting, shared transmitter, distinct diagnostic overflow");$finish;
end
initial begin #2000000;$fatal(1,"timeout");end
endmodule
