# 这是两条独立的异步输入到输出通路，没有内部采样时钟。
# 最快串口 3 Mbaud 的单 bit 为约 333 ns，给板内转接预留 100 ns 上限。
set_max_delay 100.000 -from [get_ports {uart_rxd}] -to [get_ports {touch_txd}]
set_max_delay 100.000 -from [get_ports {touch_rxd}] -to [get_ports {uart_txd}]
