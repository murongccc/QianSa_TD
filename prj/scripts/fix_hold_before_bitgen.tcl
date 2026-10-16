# 不生成 bitstream。GUI 完成 P&R 后可直接 source，脚本加载该物理运行的 pr.db。
# 独立构建器预设 startup_hold_run_dir，表示直接使用当前完成布线的内存设计。
# 原有物理数据库先备份，修复并通过 DRC/最终 STA 后才更新供 bitgen 读取的 pr.db。
set startup_hold_use_current [info exists startup_hold_run_dir]
if {!$startup_hold_use_current} {
    set startup_hold_run_dir [file join [file dirname [file dirname [file normalize [info script]]]] SD_to_Video_Runs phy_1]
}
set startup_hold_run_dir [file normalize $startup_hold_run_dir]
if {![file isdirectory $startup_hold_run_dir]} {
    error "Missing physical run directory: $startup_hold_run_dir"
}
set startup_hold_previous_dir [pwd]
cd $startup_hold_run_dir
if {!$startup_hold_use_current} {
    foreach startup_hold_input {SD_to_Video.prj SD_to_Video_pr.db} {
        if {![file exists [file join $startup_hold_run_dir $startup_hold_input]]} {
            error "Missing $startup_hold_input; finish P&R in the current GUI project first"
        }
    }
    import_device eagle_s20.db -package EG4S20BG256
    open_project SD_to_Video.prj -noanalyze
    import_db SD_to_Video_pr.db
}
# 运行目录内采用固定文件名，兼容 TD 原生命令的嵌套脚本执行。
export_db SD_to_Video_hold_input.db
set startup_hold_backup SD_to_Video_before_hold_fix_[clock microseconds].db
file rename -force SD_to_Video_hold_input.db $startup_hold_backup

# 普通 buffer_opt 在此器件 Slice 利用率超过 90% 时跳过；clock_opt 支持引脚延迟修复。
# 不改 PLL、SDC 或 HDL，不对违例设置 false_path，也不执行增量布局/布线恢复。
fix_hold -clock_opt
report_route_status -drc
update_timing -mode final
set startup_hold_status SD_to_Video_phy.ts
report_timing_status -file SD_to_Video_phy.ts
report_timing_summary -file SD_to_Video_pr.timing
report_area -io_info -file SD_to_Video_phy.area

# TD 命令成功不等于时序通过；不允许把仍有负裕量的结果写回 bitgen 的输入数据库。
set startup_hold_channel [open $startup_hold_status r]
set startup_hold_text [read $startup_hold_channel]
close $startup_hold_channel
if {![regexp {SWNS: *([-+0-9.]+)ns} $startup_hold_text startup_hold_match startup_hold_setup] ||
    ![regexp {HWNS: *([-+0-9.]+)ns} $startup_hold_text startup_hold_match startup_hold_min]} {
    error "Cannot parse final timing status: $startup_hold_status; backup: $startup_hold_backup"
}
if {$startup_hold_setup < 0.0 || $startup_hold_min < 0.0} {
    error "Timing is not closed (setup=$startup_hold_setup ns, hold=$startup_hold_min ns); backup: $startup_hold_backup"
}
export_db SD_to_Video_pr.db
puts "PASS pre-bitgen hold fix: setup=$startup_hold_setup ns, hold=$startup_hold_min ns; no bitstream generated"
cd $startup_hold_previous_dir
if {!$startup_hold_use_current} {
    unset startup_hold_run_dir
}
