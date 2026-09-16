// Per-clock-domain reset conditioner.  Assertion is asynchronous so a stopped
// PLL output still resets its logic.  Deassertion waits for the local clock,
// holds reset for HOLD_CYCLES, then passes through three synchronizer stages.
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
reg [2:0] release_sync;

assign reset = release_sync[2];

always @(posedge clk or posedge async_reset) begin
    if (async_reset) begin
        hold_count <= {COUNTER_WIDTH{1'b0}};
        release_sync <= 3'b111;
    end else if (hold_count != HOLD_LIMIT) begin
        hold_count <= hold_count + {{(COUNTER_WIDTH-1){1'b0}},1'b1};
        release_sync <= 3'b111;
    end else begin
        release_sync <= {release_sync[1:0],1'b0};
    end
end
endmodule
