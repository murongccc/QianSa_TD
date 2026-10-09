// 8N1 接收器：valid/error 为单拍脉冲，串口输入只进入第一级同步寄存器。
module uart_byte_rx #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD = 115_200
)(
    input wire clk, input wire rst, input wire rxd,
    output reg [7:0] data, output reg valid, output reg error
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
localparam [TICK_BITS-1:0] HALF_LIMIT = CLK_HZ / BAUD / 2 - 1;
localparam [1:0] IDLE=2'd0, START=2'd1, DATA=2'd2, STOP=2'd3;
reg rx_meta, rx_sync, rx_prev;
reg [1:0] state;
reg [TICK_BITS-1:0] ticks;
reg [2:0] bit_index;
reg [7:0] shift_data;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        rx_meta<=1'b1; rx_sync<=1'b1; rx_prev<=1'b1;
        state<=IDLE; ticks<={TICK_BITS{1'b0}}; bit_index<=3'd0; shift_data<=8'd0;
        data<=8'd0; valid<=1'b0; error<=1'b0;
    end else begin
        rx_meta<=rxd; rx_sync<=rx_meta; rx_prev<=rx_sync;
        valid<=1'b0; error<=1'b0;
        case (state)
            IDLE: if (rx_prev && !rx_sync) begin state<=START; ticks<=HALF_LIMIT; end
            START: if (ticks!={TICK_BITS{1'b0}}) ticks<=ticks-1'b1;
                else if (!rx_sync) begin state<=DATA; ticks<=BIT_LIMIT; bit_index<=3'd0; end
                else state<=IDLE;
            DATA: if (ticks!={TICK_BITS{1'b0}}) ticks<=ticks-1'b1;
                else begin
                    shift_data[bit_index]<=rx_sync; ticks<=BIT_LIMIT;
                    if (bit_index==3'd7) state<=STOP;
                    else bit_index<=bit_index+3'd1;
                end
            STOP: if (ticks!={TICK_BITS{1'b0}}) ticks<=ticks-1'b1;
                else begin
                    state<=IDLE;
                    if (rx_sync) begin data<=shift_data; valid<=1'b1; end
                    else error<=1'b1;
                end
            default: state<=IDLE;
        endcase
    end
end
endmodule
