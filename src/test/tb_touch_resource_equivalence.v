`timescale 1ns/1ps
// 与修改前保存的RTL逐拍对照，检查非法协议输入、双点分配、串口波形及映射抢占。
module tb_touch_resource_equivalence;
reg clk=0;always #10 clk=~clk;
reg parser_rst=1,byte_valid=0,byte_error=0;
reg [7:0] byte_data=0;
wire [183:0] parser_actual,parser_expected;
`define PARSER_PORTS(bus) \
    .clk(clk),.rst(parser_rst),.byte_valid(byte_valid),.byte_data(byte_data),.byte_error(byte_error), \
    .ack_request(bus[183]),.update_valid(bus[182]), \
    .a_id(bus[181:178]),.a_down(bus[177]),.a_x(bus[176:161]),.a_y(bus[160:145]), \
    .b_id(bus[144:141]),.b_down(bus[140]),.b_x(bus[139:124]),.b_y(bus[123:108]), \
    .press_mask(bus[107:106]),.release_mask(bus[105:104]),.frame_seq(bus[103:96]), \
    .good_count(bus[95:80]),.checksum_error_count(bus[79:64]),.format_error_count(bus[63:48]), \
    .sequence_gap_count(bus[47:32]),.timeout_count(bus[31:16]),.uart_error_count(bus[15:0])
ch9350_touch_parser #(.CLK_HZ(1000),.FRAME_TIMEOUT_MS(20)) parser_dut(`PARSER_PORTS(parser_actual));
baseline_ch9350_touch_parser #(.CLK_HZ(1000),.FRAME_TIMEOUT_MS(20)) parser_ref(`PARSER_PORTS(parser_expected));
`undef PARSER_PORTS

reg monitor_rst=1,update_valid=0,echo_valid=0;
reg [85:0] event_packet=0;
reg [7:0] echo_data=0;
reg [15:0] counters=0;
wire [32:0] monitor_actual,monitor_expected;
`define MONITOR_PORTS(bus) \
    .clk(clk),.rst(monitor_rst),.update_valid(update_valid), \
    .frame_seq(event_packet[85:78]),.a_id(event_packet[77:74]),.a_down(event_packet[73]), \
    .a_x(event_packet[72:57]),.a_y(event_packet[56:41]),.b_id(event_packet[40:37]), \
    .b_down(event_packet[36]),.b_x(event_packet[35:20]),.b_y(event_packet[19:4]), \
    .press_mask(event_packet[3:2]),.release_mask(event_packet[1:0]), \
    .good_count(counters),.checksum_error_count(counters^16'ha55a),.format_error_count(counters+16'd17), \
    .sequence_gap_count(counters-16'd31),.timeout_count(counters^16'hff00),.uart_error_count(~counters), \
    .ack_count(counters+16'd257),.echo_valid(echo_valid),.echo_data(echo_data), \
    .uart_txd(bus[32]),.monitor_drop_count(bus[31:16]),.echo_drop_count(bus[15:0])
touch_serial_monitor #(.CLK_HZ(100000),.BAUD(10000),.SNAPSHOT_MS(7)) monitor_dut(.lane_valid(1'b0),.lane_down(4'd0),.lane_press(4'd0),.lane_release(4'd0),.lane_fault(1'b0),.lane_monitor_overflow(),`MONITOR_PORTS(monitor_actual));
baseline_touch_serial_monitor #(.CLK_HZ(100000),.BAUD(10000),.SNAPSHOT_MS(7)) monitor_ref(`MONITOR_PORTS(monitor_expected));
`undef MONITOR_PORTS

reg mapper_rst=1,mapper_update=0;
reg [65:0] mapper_inputs=0;
wire [41:0] mapper_actual0,mapper_expected0,mapper_actual1,mapper_expected1;
`define MAPPER_PORTS(bus) \
    .clk(clk),.rst(mapper_rst),.update_valid(mapper_update),.a_down(mapper_inputs[65]),.b_down(mapper_inputs[64]), \
    .a_x(mapper_inputs[63:48]),.a_y(mapper_inputs[47:32]),.b_x(mapper_inputs[31:16]),.b_y(mapper_inputs[15:0]), \
    .busy(bus[41]),.pixel_valid(bus[40]),.pixel_packet(bus[39:0])
touch_pixel_mapper #(.ATOMIC_OUTPUT(0)) mapper_dut0(`MAPPER_PORTS(mapper_actual0));
baseline_touch_pixel_mapper #(.ATOMIC_OUTPUT(0)) mapper_ref0(`MAPPER_PORTS(mapper_expected0));
touch_pixel_mapper #(.ATOMIC_OUTPUT(1)) mapper_dut1(`MAPPER_PORTS(mapper_actual1));
baseline_touch_pixel_mapper #(.ATOMIC_OUTPUT(1)) mapper_ref1(`MAPPER_PORTS(mapper_expected1));
`undef MAPPER_PORTS

integer cycles=0,frames=0;
reg parser_done=0,monitor_done=0,mapper_done=0;
always @(posedge clk) begin
    #1;
    cycles=cycles+1;
    if(parser_actual!==parser_expected)begin $display("FAIL parser equivalence cycle=%0d frame=%0d actual=%h expected=%h",cycles,frames,parser_actual,parser_expected);$stop;end
    if(monitor_actual!==monitor_expected)begin $display("FAIL monitor waveform/count equivalence cycle=%0d",cycles);$stop;end
    if(mapper_actual0!==mapper_expected0 || mapper_actual1!==mapper_expected1)begin $display("FAIL mapper equivalence cycle=%0d",cycles);$stop;end
end

reg [7:0] body[0:56];
integer parser_seed=32'h31415926,p,i,j,value;
reg [7:0] sum;
task send_byte;input [7:0] data;
    begin @(negedge clk);byte_data=data;byte_valid=1;@(negedge clk);byte_valid=0;end
endtask
task send_report;
    begin
        send_byte(8'h57);send_byte(8'hab);send_byte(8'h88);send_byte(8'd57);
        sum=0;for(j=1;j<56;j=j+1)sum=sum+body[j];body[56]=sum;
        if(frames%11==0)body[56]=sum^8'h01;
        for(j=0;j<57;j=j+1)send_byte(body[j]);
        frames=frames+1;
    end
endtask
initial begin
    repeat(5)@(negedge clk);parser_rst=0;
    // 遍历标识、报告ID、数量和两份状态字节，覆盖每种非法保留位组合。
    for(p=0;p<5;p=p+1)for(i=0;i<256;i=i+1)begin
        for(j=0;j<57;j=j+1)body[j]=0;
        body[0]=8'h40;body[1]=8'h0d;body[54]=2;body[55]=frames;
        body[2]=8'h11;body[7]=8'h21;
        if(p==0)body[0]=i;else if(p==1)body[1]=i;else if(p==2)body[54]=i;
        else if(p==3)body[2]=i;else body[7]=i;
        send_report;
    end
    for(i=0;i<6000;i=i+1)begin
        for(j=0;j<57;j=j+1)body[j]=0;
        body[0]=i[0] ? 8'h40:8'h41;body[1]=8'h0d;body[54]=2;body[55]=$random(parser_seed);
        value=$random(parser_seed);body[2]={value[3:0],3'd0,value[4]};
        value=$random(parser_seed);body[7]={value[3:0],3'd0,value[4]};
        for(j=3;j<=11;j=j+1)if(j!=7)body[j]=$random(parser_seed);
        if(i%13==0)body[2][2]=1;
        if(i%17==0)body[12]=1;
        send_report;
    end
    for(i=0;i<256;i=i+1)begin
        send_byte(8'h57);send_byte(8'hab);send_byte(8'h88);send_byte(i);
        repeat(25)@(negedge clk);
    end
    for(i=0;i<50000;i=i+1)begin
        @(negedge clk);value=$random(parser_seed);byte_valid=value[0];byte_error=(value[7:0]==8'hff);byte_data=value[15:8];
        if(i%4096==0)parser_rst=1;else parser_rst=0;
    end
    @(negedge clk);byte_valid=0;byte_error=0;parser_rst=0;parser_done=1;
end
integer monitor_seed=32'h12345678,m,random_monitor;
initial begin
    repeat(5)@(negedge clk);monitor_rst=0;
    for(m=0;m<220000;m=m+1)begin
        @(negedge clk);random_monitor=$random(monitor_seed);
        counters=counters+16'h1237;
        update_valid=(m%300==0 || (m>2000 && m<2040));
        echo_valid=(m%1301==0 || (m>3000 && m<3040));echo_data=random_monitor[7:0];
        if(update_valid)event_packet={random_monitor[21:0],$random(monitor_seed),$random(monitor_seed)};
    end
    @(negedge clk);update_valid=0;echo_valid=0;monitor_done=1;
end
integer mapper_seed=32'h87654321,n,random_mapper;
initial begin
    repeat(5)@(negedge clk);mapper_rst=0;
    for(n=0;n<100000;n=n+1)begin
        @(negedge clk);random_mapper=$random(mapper_seed);
        mapper_update=(random_mapper[4:0]==5'd0 || (n%97<4));
        if(mapper_update)mapper_inputs={random_mapper[1:0],$random(mapper_seed),$random(mapper_seed)};
        mapper_rst=(n%4096==0);
    end
    @(negedge clk);mapper_update=0;mapper_rst=0;mapper_done=1;
end
initial begin
    wait(parser_done && monitor_done && mapper_done);
    repeat(30)@(negedge clk);
    $display("PASS touch resource equivalence: %0d cycles, %0d reports, UART waveforms/counters and both mapper modes",cycles,frames);$finish;
end
initial begin #100000000;$display("FAIL resource equivalence timeout");$stop;end
endmodule
