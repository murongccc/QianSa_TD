# 在 TD 中对已失败的 ECO 布线数据库重新布线；不改变约束、不生成 bitstream。
# 默认读取 GUI 的 phy_1。其他运行目录可先设置 resource_route_run_dir。
# 示例：source {E:/AnLuTD_Project/SD_to_Video/prj/scripts/recover_incremental_route.tcl}
set resource_project_dir [file dirname [file dirname [file normalize [info script]]]]
if {![info exists resource_route_run_dir]} {
    set resource_route_run_dir [file join $resource_project_dir SD_to_Video_Runs phy_1]
}
set resource_route_run_dir [file normalize $resource_route_run_dir]
foreach resource_input {SD_to_Video.prj SD_to_Video_eco_pr.db} {
    if {![file exists [file join $resource_route_run_dir $resource_input]]} {
        error "Missing $resource_input in $resource_route_run_dir; run P&R first."
    }
}
set resource_previous_dir [pwd]
cd $resource_route_run_dir
set resource_route_result [catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project SD_to_Video.prj -noanalyze
    import_db SD_to_Video_eco_pr.db
    # 与仅处理未布线网络的 ECO 不同，此模式允许调整已合法布线网络。
    route -incremental
    report_route_status -drc
    report_area -io_info -file recovered_phy.area
    update_timing -mode final
    report_timing_status -file recovered_phy.ts
    report_timing_summary -file recovered_pr.timing
    export_db recovered_pr.db
} resource_route_message resource_route_options]
cd $resource_previous_dir
if {$resource_route_result} {
    return -options $resource_route_options $resource_route_message
}
