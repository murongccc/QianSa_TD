// Per-clock-domain reset conditioner.  Assertion is asynchronous so a stopped
// PLL output still resets its logic.  Deassertion waits for the local clock,
// holds reset for HOLD_CYCLES, then passes through three synchronizer stages.
// 前两级在上升沿同步，末级在下降沿撤销，为上升沿负载留出半周期余量。
module domain_reset_sync #(
    parameter integer COUNTER_WIDTH = 10,
    parameter integer HOLD_CYCLES = 1024
)(
    input wire clk,
    input wire async_reset,
    output wire reset
);
localparam [COUNTER_WIDTH-1:0] HOLD_LIMIT = HOLD_CYCLES - 1;
reg [COUNTER_WIDTH-1:0] hold_count;
reg [1:0] release_sync;
reg release_final;

assign reset = release_final;

// 上一级仍异步断言，故停钟时最终输出也能立即复位。
// 其撤销只发生在上升沿，末级自身同样拥有半周期 removal 余量。
always @(negedge clk or posedge release_sync[1]) begin
    if (release_sync[1])
        release_final <= 1'b1;
    else
        release_final <= 1'b0;
end

always @(posedge clk or posedge async_reset) begin
    if (async_reset) begin
        hold_count <= {COUNTER_WIDTH{1'b0}};
        release_sync <= 2'b11;
    end else if (hold_count != HOLD_LIMIT) begin
        hold_count <= hold_count + {{(COUNTER_WIDTH-1){1'b0}},1'b1};
        release_sync <= 2'b11;
    end else begin
        release_sync <= {release_sync[0],1'b0};
    end
end
endmodule
