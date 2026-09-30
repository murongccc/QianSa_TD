`timescale 1ns/1ps

module tb_touch_uart_debug;
reg pc_drive;
reg touch_drive;
reg loopback;
wire uart_txd;
wire touch_txd;
wire touch_rxd = loopback ? touch_txd : touch_drive;
integer touch_received;
integer pc_received;
integer errors;
integer pc_index;
integer touch_index;

touch_uart_debug dut (
    .uart_rxd(pc_drive), .uart_txd(uart_txd),
    .touch_rxd(touch_rxd), .touch_txd(touch_txd)
);

// 外部发送器产生连续 8N1 帧；测试工程不参与字节编解码。
task send_pc;
    input [7:0] data;
    input integer bit_ns;
    integer bit_index;
    begin
        pc_drive = 1'b0;
        #(bit_ns);
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            pc_drive = data[bit_index];
            #(bit_ns);
        end
        pc_drive = 1'b1;
        #(bit_ns);
    end
endtask

task send_touch;
    input [7:0] data;
    input integer bit_ns;
    integer bit_index;
    begin
        touch_drive = 1'b0;
        #(bit_ns);
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            touch_drive = data[bit_index];
            #(bit_ns);
        end
        touch_drive = 1'b1;
        #(bit_ns);
    end
endtask

// 独立接收器按位中心采样，核对端到端字节和停止位。
task check_at_touch;
    input [7:0] expected;
    input integer bit_ns;
    integer bit_index;
    reg [7:0] actual;
    begin
        @(negedge touch_txd);
        #(bit_ns + bit_ns / 2);
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            actual[bit_index] = touch_txd;
            #(bit_ns);
        end
        if ((actual !== expected) || (touch_txd !== 1'b1)) begin
            errors = errors + 1;
            $display("FAIL PC->touch expected=%h actual=%h stop=%b", expected, actual, touch_txd);
        end
        touch_received = touch_received + 1;
    end
endtask

task check_at_pc;
    input [7:0] expected;
    input integer bit_ns;
    integer bit_index;
    reg [7:0] actual;
    begin
        @(negedge uart_txd);
        #(bit_ns + bit_ns / 2);
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            actual[bit_index] = uart_txd;
            #(bit_ns);
        end
        if ((actual !== expected) || (uart_txd !== 1'b1)) begin
            errors = errors + 1;
            $display("FAIL touch->PC expected=%h actual=%h stop=%b", expected, actual, uart_txd);
        end
        pc_received = pc_received + 1;
    end
endtask

initial begin
    // 防止遗漏起始位后测试静默挂起。
    #50000000;
    $display("FAIL timeout");
    $stop;
end

initial begin
    pc_drive = 1'b1;
    touch_drive = 1'b1;
    loopback = 1'b0;
    errors = 0;
    touch_received = 0;
    pc_received = 0;
    #100;
    if ((uart_txd !== 1'b1) || (touch_txd !== 1'b1)) errors = errors + 1;

    // 同时双向发送全部 256 种字节，连续帧，模拟独立发送器的不同相位。
    fork
        begin
            #20;
            for (pc_index = 0; pc_index < 256; pc_index = pc_index + 1)
                send_pc(pc_index[7:0], 8681);
        end
        begin : monitor_touch
            integer index;
            for (index = 0; index < 256; index = index + 1)
                check_at_touch(index[7:0], 8681);
        end
        begin
            #251;
            for (touch_index = 0; touch_index < 256; touch_index = touch_index + 1)
                send_touch(8'hff - touch_index[7:0], 8681);
        end
        begin : monitor_pc
            integer index;
            for (index = 0; index < 256; index = index + 1)
                check_at_pc(8'hff - index[7:0], 8681);
        end
    join

    // 板上 J2 第 1、2 脚短接的自检路径，在最高配置速率 3 Mbaud 下核对。
    #1000;
    loopback = 1'b1;
    fork
        begin
            #20;
            send_pc(8'h00, 333);
            send_pc(8'h57, 333);
            send_pc(8'hab, 333);
            send_pc(8'h82, 333);
            send_pc(8'hff, 333);
        end
        begin
            check_at_pc(8'h00, 333);
            check_at_pc(8'h57, 333);
            check_at_pc(8'hab, 333);
            check_at_pc(8'h82, 333);
            check_at_pc(8'hff, 333);
        end
    join

    if ((errors != 0) || (touch_received != 256) || (pc_received != 261)) begin
        $display("FAIL errors=%0d touch_received=%0d pc_received=%0d", errors, touch_received, pc_received);
        $stop;
    end
    $display("PASS touch_uart_debug: simultaneous 256-byte streams in both directions; 3-Mbaud GPIO loopback");
    $finish;
end
endmodule
