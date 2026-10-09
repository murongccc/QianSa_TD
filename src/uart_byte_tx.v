// 8N1 发送器：仅在 valid && ready 时接收一个字节。
module uart_byte_tx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 115_200
)(
    input wire clk, input wire rst, input wire valid, input wire [7:0] data,
    output wire ready, output reg txd
);
function integer counter_width;
    input integer value;
    integer remaining;
    begin
        remaining=value-1;counter_width=0;
        while(remaining>0)begin counter_width=counter_width+1;remaining=remaining>>1;end
        if(counter_width==0)counter_width=1;
    end
endfunction
localparam integer TICK_BITS=counter_width(CLK_HZ / BAUD);
localparam [TICK_BITS-1:0] BIT_LIMIT = CLK_HZ / BAUD - 1;
reg busy;
reg [TICK_BITS-1:0] ticks;
reg [3:0] bit_index;
reg [9:0] shift_frame;
assign ready = !busy;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        busy<=1'b0; ticks<={TICK_BITS{1'b0}}; bit_index<=4'd0;
        shift_frame<=10'h3ff; txd<=1'b1;
    end else if (!busy) begin
        txd<=1'b1;
        if (valid) begin
            shift_frame<={1'b1,data,1'b0}; txd<=1'b0;
            ticks<=BIT_LIMIT; bit_index<=4'd0; busy<=1'b1;
        end
    end else if (ticks!={TICK_BITS{1'b0}}) ticks<=ticks-1'b1;
    else begin
        ticks<=BIT_LIMIT;
        if (bit_index==4'd9) begin busy<=1'b0; txd<=1'b1; end
        else begin bit_index<=bit_index+4'd1; txd<=shift_frame[bit_index+4'd1]; end
    end
end
endmodule
