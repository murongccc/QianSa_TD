// 独立串口检查顶层：用板载 CH340 查看 CH9350 的原始串口数据。
// 两条通路直接转接电平，不解码、不回显、不插入协议应答。
// 波特率及 8N1 格式由电脑和 CH9350 设置；无需时钟、复位或新 IP。
module touch_uart_debug (
    input  wire uart_rxd,   // F12：板载 CH340 TX -> FPGA
    output wire uart_txd,   // D12：FPGA -> 板载 CH340 RX
    input  wire touch_rxd,  // P4：J2 第 1 脚，CH9350 TX -> FPGA
    output wire touch_txd   // N4：J2 第 2 脚，FPGA -> CH9350 RX
);

assign uart_txd  = touch_rxd;
assign touch_txd = uart_rxd;

endmodule
