# 从仓库根目录运行：独立测试工程的综合及布局布线检查，不生成 bitstream。
file mkdir prj/log/touch_uart_debug
cd prj/touch_uart_debug

import_device eagle_s20.db -package EG4S20BG256
open_project touch_uart_debug.al -single_run
load_run_param -run syn_1
commit_param -step design
elaborate -top touch_uart_debug
read_adc touch_uart_debug.adc
read_sdc touch_uart_debug.sdc
cd ../log/touch_uart_debug
commit_param -step rtl
optimize_rtl
commit_param -step gate
optimize_gate -packarea touch_uart_debug_gate.area
legalize_phy_inst
load_run_param -run phy_1
commit_param -step place
place
commit_param -step route
route
report_route_status -drc
report_area -io_info -file touch_uart_debug_phy.area
update_timing -mode final
report_timing_status -file touch_uart_debug_phy.ts
report_timing_summary -file touch_uart_debug_pr.timing
export_db touch_uart_debug_pr.db
exit
