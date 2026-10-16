`timescale 1ns/1ps

// 本地复位隔离器回归：异步断言必须立即生效，撤销必须经过保持窗和
// 三级同步后在下降沿放行，上升沿负载始终有半周期的复位撤销余量。
module tb_domain_reset_sync;
reg clk = 1'b0;
reg clock_enabled = 1'b1;
reg async_reset = 1'b1;
wire reset;
integer edge_count;

always #5 if (clock_enabled) clk = ~clk;
always @(negedge reset) begin
    if (clk !== 1'b0)
        $fatal(1, "reset release did not occur on the falling clock phase");
end

domain_reset_sync #(.COUNTER_WIDTH(5), .HOLD_CYCLES(16)) dut (
    .clk(clk), .async_reset(async_reset), .reset(reset)
);

initial begin
    #1;
    if (reset !== 1'b1)
        $fatal(1, "asynchronous reset assertion was not propagated");

    @(negedge clk);
    async_reset = 1'b0;
    edge_count = 0;
    while (edge_count < 17) begin
        @(posedge clk);
        #1;
        edge_count = edge_count + 1;
        if (reset !== 1'b1)
            $fatal(1, "reset released before local hold/synchronizer completed");
    end
    @(negedge clk);
    #1;
    if (reset !== 1'b0)
        $fatal(1, "reset did not release on the falling edge after three synchronizer stages");

    @(negedge clk);
    async_reset = 1'b1;
    #1;
    if (reset !== 1'b1)
        $fatal(1, "second asynchronous assertion was not immediate");
    // PLL 停钟期间撤销外部复位，输出仍须保持；恢复后重新完成保持窗。
    clock_enabled = 1'b0;
    #2;async_reset = 1'b0;
    #23;
    if (reset !== 1'b1)
        $fatal(1, "reset released while its clock was stopped");
    clock_enabled = 1'b1;
    repeat (17) @(posedge clk);
    #1;
    if (reset !== 1'b1)
        $fatal(1, "restart bypassed the local hold window");
    @(negedge clk);#1;
    if (reset !== 1'b0)
        $fatal(1, "reset did not release after clock restart");
    // 不覆盖任一时钟沿的短脉冲也必须重新断言和保持输出。
    #1;async_reset=1'b1;#1;
    if (reset !== 1'b1)
        $fatal(1, "short asynchronous pulse was lost");
    async_reset=1'b0;
    repeat (17) @(posedge clk);#1;
    if (reset !== 1'b1)
        $fatal(1, "short pulse bypassed the local hold window");
    @(negedge clk);#1;
    if (reset !== 1'b0)
        $fatal(1, "reset did not release after the short pulse");
    $display("PASS domain_reset_sync falling-edge release, asynchronous assertion, stopped clock and short pulse");
    $finish;
end
initial begin #2000;$fatal(1,"reset regression timeout");end
endmodule
