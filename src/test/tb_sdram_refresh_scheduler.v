`timescale 1ns/1ps

module tb_sdram_refresh_scheduler;
reg clk = 1'b0;
reg rst = 1'b1;
reg sdr_init_done = 1'b0;
reg sdr_init_ref_vld = 1'b0;
wire app_ref_req;
wire refresh_hold;
wire refresh_fault;
wire [13:0] refresh_max_gap;

always #5 clk = ~clk;

sdram_refresh_scheduler #(
    .REFRESH_INTERVAL_CYCLES(14'd2500),
    .EARLY_GUARD_CYCLES(14'd512)
) dut (
    .clk(clk), .rst(rst), .sdr_init_done(sdr_init_done),
    .sdr_init_ref_vld(sdr_init_ref_vld), .app_ref_req(app_ref_req),
    .refresh_hold(refresh_hold), .refresh_fault(refresh_fault),
    .refresh_max_gap(refresh_max_gap)
);

task reset_dut;
    begin
        rst = 1'b1;
        sdr_init_done = 1'b0;
        sdr_init_ref_vld = 1'b0;
        repeat (256) @(posedge clk);
        rst = 1'b0;
    end
endtask

task start_after_init;
    begin
        @(negedge clk);
        sdr_init_done = 1'b1;
        repeat (3) @(posedge clk);
        if (app_ref_req || refresh_hold)
            $fatal(1, "refresh request started before the early window");
    end
endtask

initial begin
    reset_dut;

    // 初始化完成前绝不能发起手动刷新。
    repeat (5) @(posedge clk);
    if (app_ref_req || refresh_hold)
        $fatal(1, "refresh request started before SDRAM initialization");

    start_after_init;

    // 模拟正在执行的 burst、读数据尾部和控制器接受请求的延迟。
    // 延迟小于 512-cycle 保护窗时，确认必须仍在 2500-cycle 截止前完成。
    wait (app_ref_req);
    if (!refresh_hold)
        $fatal(1, "refresh hold was not asserted with the request");
    repeat (256) @(posedge clk);
    #1;
    if (!app_ref_req || !refresh_hold)
        $fatal(1, "refresh request was not held until confirmation");
    if (refresh_fault)
        $fatal(1, "guard window did not cover the modeled drain delay");
    @(negedge clk);
    sdr_init_ref_vld = 1'b1;
    @(posedge clk);
    #1;
    if (app_ref_req || refresh_hold)
        $fatal(1, "refresh request did not clear after confirmation");
    @(negedge clk);
    sdr_init_ref_vld = 1'b0;
    repeat (3) @(posedge clk);
    if (refresh_fault)
        $fatal(1, "normal confirmed refresh raised a fault");
    if ((refresh_max_gap < 14'd1988) || (refresh_max_gap > 14'd2500))
        $fatal(1, "refresh gap monitor recorded an invalid confirmed interval");

    reset_dut;
    start_after_init;
    wait (refresh_fault);
    #1;
    if (!app_ref_req || !refresh_hold || !refresh_fault)
        $fatal(1, "unconfirmed refresh did not hold traffic and raise a fault");

    // 超限后的迟到确认只结束刷新请求，不得重新开放数据通路。
    @(negedge clk);
    sdr_init_ref_vld = 1'b1;
    @(posedge clk);
    #1;
    if (app_ref_req || !refresh_hold || !refresh_fault)
        $fatal(1, "late confirmation reopened traffic after a refresh fault");

    $display("PASS sdram refresh scheduler: hold-until-confirm and timeout protection");
    $finish;
end

initial begin
    #100000;
    $fatal(1, "sdram refresh scheduler timeout");
end
endmodule
