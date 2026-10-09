`timescale 1ns/1ps
// 全量回放真实日志；按编号核对参考坐标，不依赖 DUT 的 A/B 分配顺序。
module tb_ch9350_touch_parser;
reg clk=1'b0;
always #10 clk=~clk;
reg rst=1'b1, byte_valid=1'b0, byte_error=1'b0;
reg [7:0] byte_data=8'd0;
wire ack_request, update_valid, a_down, b_down;
wire [3:0] a_id,b_id;
wire [15:0] a_x,a_y,b_x,b_y;
wire [1:0] press_mask,release_mask;
wire [7:0] frame_seq;
wire [15:0] good_count,checksum_error_count,format_error_count,sequence_gap_count,timeout_count,uart_error_count;
reg [7:0] single_bytes[0:14883];
reg [7:0] double_bytes[0:61975];
reg [7:0] work_frame[0:60];
integer frame_index,byte_index,press_total,release_total,ack_total,checks;
reg [73:0] committed;
reg monitor_atomic;
wire [73:0] live_state={a_id,a_down,a_x,a_y,b_id,b_down,b_x,b_y};
ch9350_touch_parser #(.CLK_HZ(1000),.FRAME_TIMEOUT_MS(20)) dut(
    .clk(clk),.rst(rst),.byte_valid(byte_valid),.byte_data(byte_data),.byte_error(byte_error),
    .ack_request(ack_request),.update_valid(update_valid),.a_id(a_id),.a_down(a_down),.a_x(a_x),.a_y(a_y),
    .b_id(b_id),.b_down(b_down),.b_x(b_x),.b_y(b_y),.press_mask(press_mask),.release_mask(release_mask),.frame_seq(frame_seq),
    .good_count(good_count),.checksum_error_count(checksum_error_count),.format_error_count(format_error_count),
    .sequence_gap_count(sequence_gap_count),.timeout_count(timeout_count),.uart_error_count(uart_error_count));
task fail;
    input [511:0] message;
    begin $display("FAIL %0s frame=%0d good=%0d",message,frame_index+1,good_count); $stop; end
endtask
always @(negedge clk) begin
    if (rst) begin committed=74'd0; press_total=0; release_total=0; ack_total=0; end
    else begin
        if (monitor_atomic && !update_valid && live_state!==committed) fail("non-atomic state update");
        committed=live_state;
        if (update_valid) begin
            press_total=press_total+press_mask[0]+press_mask[1];
            release_total=release_total+release_mask[0]+release_mask[1];
        end
        if (ack_request) ack_total=ack_total+1;
    end
end
task reset_dut;
    begin
        @(negedge clk); rst=1'b1; byte_valid=1'b0; byte_error=1'b0;
        repeat(3) @(negedge clk);
        rst=1'b0;
        repeat(2) @(negedge clk);
    end
endtask
task send_byte;
    input [7:0] value;
    begin
        @(negedge clk); byte_data=value; byte_valid=1'b1;
        @(negedge clk); byte_valid=1'b0;
        #1;
    end
endtask
task load_double;
    input integer number;
    integer i;
    begin for(i=0;i<61;i=i+1) work_frame[i]=double_bytes[(number-1)*61+i]; end
endtask
task recalc;
    integer i;
    reg [7:0] sum;
    begin
        sum=8'd0;
        for(i=5;i<60;i=i+1) sum=sum+work_frame[i];
        work_frame[60]=sum;
    end
endtask
task send_work;
    integer i;
    begin for(i=0;i<61;i=i+1) send_byte(work_frame[i]); end
endtask
task check_contact;
    input [3:0] id;
    input down;
    input [15:0] x,y;
    begin
        if(a_id==id) begin
            if(a_down!==down || a_x!==x || a_y!==y) fail("contact A mismatch");
        end else if(b_id==id) begin
            if(b_down!==down || b_x!==x || b_y!==y) fail("contact B mismatch");
        end else if(down) fail("active contact missing");
    end
endtask
task check_work;
    reg [1:0] expected_down;
    begin
        if(!update_valid) fail("missing valid frame update");
        if(frame_seq!==work_frame[59]) fail("frame_seq mismatch");
        expected_down={work_frame[11][0],work_frame[6][0]};
        if(work_frame[58]==8'd1) expected_down[1]=1'b0;
        if(({1'b0,a_down}+{1'b0,b_down}) != ({1'b0,expected_down[0]}+{1'b0,expected_down[1]})) fail("active count mismatch");
        if(work_frame[58]!=8'd0)
            check_contact(work_frame[6][7:4],work_frame[6][0],{work_frame[8],work_frame[7]},{work_frame[10],work_frame[9]});
        if(work_frame[58]==8'd2)
            check_contact(work_frame[11][7:4],work_frame[11][0],{work_frame[13],work_frame[12]},{work_frame[15],work_frame[14]});
        checks=checks+1;
    end
endtask
task expect_bad_format;
    reg [15:0] before_good,before_format;
    reg [73:0] before_state;
    begin
        recalc;
        before_good=good_count; before_format=format_error_count; before_state=live_state;
        send_work;
        if(update_valid || good_count!=before_good || format_error_count!=before_format+16'd1 || live_state!==before_state)
            fail("invalid format published state");
        checks=checks+1;
    end
endtask
reg [15:0] before_good;
reg [73:0] before_state;
initial begin
    #10000000; fail("timeout");
end
initial begin
    monitor_atomic=1'b1; checks=0;
    $readmemh("src/test/data/touch_single.hex",single_bytes);
    $readmemh("src/test/data/touch_double.hex",double_bytes);
    reset_dut;
    for(frame_index=0;frame_index<244;frame_index=frame_index+1) begin
        for(byte_index=0;byte_index<61;byte_index=byte_index+1) work_frame[byte_index]=single_bytes[frame_index*61+byte_index];
        send_work; check_work;
    end
    @(negedge clk); #1;
    if(good_count!=16'd244 || checksum_error_count!=16'd0 || sequence_gap_count!=16'd0 ||
       press_total!=3 || release_total!=3 || a_down || b_down) fail("single capture totals");
    reset_dut;
    for(frame_index=0;frame_index<1016;frame_index=frame_index+1) begin
        load_double(frame_index+1); send_work; check_work;
        if(frame_index==817 && (a_id!=4'd1 || !a_down || b_id!=4'd2 || b_down || release_mask!=2'b10)) fail("first finger release");
        if(frame_index==818 && (a_id!=4'd1 || !a_down || b_down || press_mask!=2'd0 || release_mask!=2'd0)) fail("record compression changed identity");
    end
    @(negedge clk); #1;
    if(good_count!=16'd1016 || checksum_error_count!=16'd0 || sequence_gap_count!=16'd0 ||
       press_total!=2 || release_total!=2 || a_down || b_down) fail("double capture totals");

    reset_dut; load_double(2); send_work; check_work;
    before_good=good_count; before_state=live_state;
    work_frame[60]=work_frame[60]^8'h01; send_work;
    if(update_valid || checksum_error_count!=16'd1 || good_count!=before_good || live_state!==before_state) fail("CRC failure");
    load_double(2); work_frame[5]=8'h0e; expect_bad_format;
    load_double(2); work_frame[4]=8'h20; expect_bad_format;
    load_double(2); work_frame[58]=8'd3; expect_bad_format;
    load_double(2); work_frame[16]=8'h31; expect_bad_format;
    load_double(2); work_frame[11]=work_frame[6]; expect_bad_format;
    load_double(2); work_frame[6]=8'h23; expect_bad_format;
    load_double(2); work_frame[58]=8'd1; expect_bad_format;
    // 无触点的完整报告必须清除两点，不能以非零旧坐标判断按住。
    load_double(2); for(byte_index=6;byte_index<57;byte_index=byte_index+1) work_frame[byte_index]=8'd0;
    work_frame[58]=8'd0; recalc; send_work;
    if(!update_valid || a_down || b_down || release_mask!=2'b11) fail("empty report release");
    checks=checks+1;
    // 标识允许上层/下层口；编号不限于 1/2，交换记录保持已分配输出。
    load_double(2); work_frame[4]=8'h41; work_frame[6]=8'h71; work_frame[11]=8'h91; recalc; send_work; check_work;
    if(a_id!=4'd7 || b_id!=4'd9) fail("new identifiers");
    for(byte_index=0;byte_index<5;byte_index=byte_index+1) begin
        byte_data=work_frame[6+byte_index]; work_frame[6+byte_index]=work_frame[11+byte_index]; work_frame[11+byte_index]=byte_data;
    end
    recalc; send_work; check_work;
    if(a_id!=4'd7 || b_id!=4'd9 || press_mask!=2'd0 || release_mask!=2'd0) fail("swapped records");
    reset_dut;
    send_byte(8'h57); send_byte(8'h57); send_byte(8'hab); send_byte(8'h82); send_byte(8'ha3);
    @(negedge clk); #1; if(ack_total!=1) fail("status request");
    send_byte(8'h57); send_byte(8'hab); send_byte(8'h88); send_byte(8'hff);
    if(format_error_count!=16'd1) fail("bounded length");
    load_double(1); send_work; check_work;
    before_state=live_state;
    send_byte(8'h57); send_byte(8'hab); send_byte(8'h88); send_byte(8'h39); send_byte(8'h40);
    repeat(24) @(negedge clk); #1;
    if(timeout_count!=16'd1 || live_state!==before_state) fail("partial frame timeout");
    load_double(2); send_work; check_work;
    send_byte(8'h57); send_byte(8'hab);
    @(negedge clk); byte_error=1'b1;
    @(negedge clk); byte_error=1'b0; #1;
    if(uart_error_count!=16'd1) fail("UART error abort");
    load_double(2); send_work; check_work;
    // 缺字节、嵌入帧头及噪声后，有限长度解析必须重新找到后续合法帧。
    before_good=good_count;
    for(byte_index=0;byte_index<61;byte_index=byte_index+1) if(byte_index!=20) send_byte(work_frame[byte_index]);
    send_work; send_work; check_work;
    if(good_count<=before_good) fail("missing byte resynchronization");
    load_double(2); work_frame[20]=8'h57; work_frame[21]=8'hab; work_frame[22]=8'h88;
    // 故意保留旧校验，载荷中的帧头不能提前提交。
    before_good=good_count; send_work;
    if(good_count!=before_good) fail("embedded header");
    load_double(2); send_work; check_work;
    send_byte(8'h57); send_byte(8'hab); send_byte(8'h88);
    reset_dut; load_double(2); send_work; check_work;
    // 序号回绕正常；跳号计数，但合法的新快照继续提交。
    reset_dut; load_double(2); work_frame[59]=8'hff; recalc; send_work; check_work;
    work_frame[59]=8'h00; recalc; send_work; check_work;
    if(sequence_gap_count!=16'd0) fail("frame_seq wrap");
    work_frame[59]=8'h02; recalc; send_work; check_work;
    if(sequence_gap_count!=16'd1) fail("frame_seq gap");
    send_byte(8'h57); send_byte(8'hab); send_byte(8'h82); send_byte(8'ha3);
    if(!update_valid || a_down || b_down || release_mask!=2'b11) fail("module restart retained contacts");
    load_double(2); send_work; check_work;
    if(sequence_gap_count!=16'd1) fail("module restart sequence epoch");
    $display("PASS parser: 1260 captured frames plus malformed/timeout/reorder/reset/wrap cases; checks=%0d",checks);
    $finish;
end
endmodule
