`timescale 1ns/1ps

module tb_frame_fifo_refresh_gate;
localparam BURST_SIZE = 4;
localparam FIFO_DEPTH = 8;
localparam [9:0] WRITE_FIFO_READY_WORDS = BURST_SIZE;

reg mem_clk = 1'b0;
reg rst = 1'b1;
reg sdr_init_done = 1'b1;
reg sdr_init_ref_vld = 1'b0;
reg sdr_busy = 1'b0;
reg refresh_hold = 1'b0;

reg read_req = 1'b0;
reg write_req = 1'b0;
wire read_req_ack;
wire write_req_ack;
wire app_rd_en;
wire app_wr_en;
wire app_rd_busy;
wire app_wr_busy;
wire read_fifo_aclr;
wire write_fifo_aclr;

always #5 mem_clk = ~mem_clk;

frame_fifo_read #(
    .ADDR_BITS(21),
    .BURST_BITS(9),
    .FIFO_DEPTH(FIFO_DEPTH),
    .BURST_SIZE(BURST_SIZE)
) read_dut (
    .rst(rst), .mem_clk(mem_clk), .Sdr_init_done(sdr_init_done),
    .Sdr_init_ref_vld(sdr_init_ref_vld), .Sdr_busy(sdr_busy),
    .refresh_hold(refresh_hold),
    .Sdr_rd_en(1'b0), .App_wr_busy(1'b0), .O_rd_busy(app_rd_busy),
    .App_rd_en(app_rd_en), .App_rd_addr(), .read_req(read_req),
    .read_req_ack(read_req_ack), .read_finish(),
    .read_addr_0(21'd0), .read_addr_1(21'd0), .read_addr_2(21'd0), .read_addr_3(21'd0),
    .read_addr_index(2'd0), .read_len(21'd8), .fifo_aclr(read_fifo_aclr), .wrusedw(10'd0)
);

frame_fifo_write #(
    .ADDR_BITS(21),
    .BURST_BITS(9),
    .BURST_SIZE(BURST_SIZE),
    .FRAME_WIDTH(4),
    .FRAME_HEIGHT(2)
) write_dut (
    .rst(rst), .mem_clk(mem_clk), .Sdr_init_done(sdr_init_done),
    .Sdr_init_ref_vld(sdr_init_ref_vld), .Sdr_busy(sdr_busy),
    .refresh_hold(refresh_hold),
    .App_rd_busy(1'b0), .O_wr_busy(app_wr_busy), .App_wr_en(app_wr_en), .App_wr_addr(),
    .write_req(write_req), .write_req_ack(write_req_ack), .write_finish(),
    .write_addr_0(21'd0), .write_addr_1(21'd0), .write_addr_2(21'd0), .write_addr_3(21'd0),
    .write_addr_index(2'd0), .write_len(21'd8), .write_v_flip(1'b0),
    .fifo_aclr(write_fifo_aclr), .rdusedw(WRITE_FIFO_READY_WORDS)
);

task reset_duts;
    begin
        read_req = 1'b0;
        write_req = 1'b0;
        sdr_init_ref_vld = 1'b0;
        sdr_busy = 1'b0;
        refresh_hold = 1'b0;
        rst = 1'b1;
        repeat (3) @(posedge mem_clk);
        rst = 1'b0;
        repeat (2) @(posedge mem_clk);
    end
endtask

task verify_read_gate;
    input ref_vld;
    input busy;
    input hold;
    integer cycles;
    reg started;
    begin
        sdr_init_ref_vld = ref_vld;
        sdr_busy = busy;
        refresh_hold = hold;
        read_req = 1'b1;
        cycles = 0;
        while (!read_req_ack) begin
            @(posedge mem_clk);
            cycles = cycles + 1;
            if (cycles > 12)
                $fatal(1, "read request acknowledgement timeout");
        end
        @(negedge mem_clk);
        read_req = 1'b0;
        repeat (8) begin
            @(posedge mem_clk);
            #1;
            if (app_rd_en !== 1'b0)
                $fatal(1, "read burst started while refresh=%0d busy=%0d", ref_vld, busy);
        end
        @(negedge mem_clk);
        sdr_init_ref_vld = 1'b0;
        sdr_busy = 1'b0;
        refresh_hold = 1'b0;
        started = 1'b0;
        repeat (5) begin
            @(posedge mem_clk);
            #1;
            if (app_rd_en)
                started = 1'b1;
        end
        if (!started)
            $fatal(1, "read burst did not resume after refresh/busy released");
    end
endtask

task verify_write_gate;
    input ref_vld;
    input busy;
    input hold;
    integer cycles;
    reg started;
    begin
        sdr_init_ref_vld = ref_vld;
        sdr_busy = busy;
        refresh_hold = hold;
        write_req = 1'b1;
        cycles = 0;
        while (!write_req_ack) begin
            @(posedge mem_clk);
            cycles = cycles + 1;
            if (cycles > 12)
                $fatal(1, "write request acknowledgement timeout");
        end
        @(negedge mem_clk);
        write_req = 1'b0;
        repeat (8) begin
            @(posedge mem_clk);
            #1;
            if (app_wr_en !== 1'b0)
                $fatal(1, "write burst started while refresh=%0d busy=%0d", ref_vld, busy);
        end
        @(negedge mem_clk);
        sdr_init_ref_vld = 1'b0;
        sdr_busy = 1'b0;
        refresh_hold = 1'b0;
        started = 1'b0;
        repeat (5) begin
            @(posedge mem_clk);
            #1;
            if (app_wr_en)
                started = 1'b1;
        end
        if (!started)
            $fatal(1, "write burst did not resume after refresh/busy released");
    end
endtask

initial begin
    reset_duts; verify_read_gate(1'b1, 1'b0, 1'b0);
    reset_duts; verify_read_gate(1'b0, 1'b1, 1'b0);
    reset_duts; verify_read_gate(1'b1, 1'b1, 1'b0);
    reset_duts; verify_read_gate(1'b0, 1'b0, 1'b1);
    reset_duts; verify_write_gate(1'b1, 1'b0, 1'b0);
    reset_duts; verify_write_gate(1'b0, 1'b1, 1'b0);
    reset_duts; verify_write_gate(1'b1, 1'b1, 1'b0);
    reset_duts; verify_write_gate(1'b0, 1'b0, 1'b1);
    $display("PASS frame FIFO refresh gate: read/write wait for IP and scheduler refresh holds");
    $finish;
end

initial begin
    #100000;
    $fatal(1, "frame FIFO refresh gate timeout");
end
endmodule
