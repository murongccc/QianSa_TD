`timescale 1ns/1ps

// 本地复位隔离器回归：异步断言必须立即生效，撤销必须经过保持窗和
// 三拍同步后才放行。该行为使上层 reset 网的撤销偏斜不会直达大扇出逻辑。
module tb_domain_reset_sync;
reg clk = 1'b0;
reg async_reset = 1'b1;
wire reset;
integer edge_count;

always #5 clk = ~clk;

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
    @(posedge clk);
    #1;
    if (reset !== 1'b0)
        $fatal(1, "reset did not release after 16 hold cycles plus three synchronizer stages");

    @(negedge clk);
    async_reset = 1'b1;
    #1;
    if (reset !== 1'b1)
        $fatal(1, "second asynchronous assertion was not immediate");
    $display("PASS domain_reset_sync local release isolation");
    $finish;
end
endmodule
