# GUI 布线冲突恢复与自动 P&R 流程

## 本次 GUI 故障

2026-09-27 16:19:53 的 GUI ECO 数据库重复报告：

```text
PHY-8023: x29y10_w2beg4
u_audio_playback_control/u_key/rst
sd_media_pipeline_m0/u_bmp_catalog/rst_dup_22_holdbuf
RUN-8102: Incremental route failed
```

这两条复位网络在工具的 hold 修复后发生物理布线冲突。当前综合为 14,747 LUT，未超过器件 LUT 总容量；错误消息中的容量提示不是超容量的证据。

本轮直接对用户最新的 GUI 失败数据库执行 `recover_incremental_route.tcl`，使用 `route -incremental` 允许调整已合法布线的网络，保留当前管脚、时钟、SDC 和 hold 检查，不修改 RTL 来随机扰动布局。

续跑完成，日志 `prj/log/gui_route_recovery_20260927.log` 无 ERROR，最终报告位于 GUI 的 `phy_1/recovered_*`：15,125 LUT、9,702 REG、40 BRAM9K（含 FIFO）、6 BRAM32K、18 DSP、2 PLL；`SWNS=+0.115 ns、STNS=0、HWNS=+0.003 ns、HTNS=0`。

外部续跑不会自动将 GUI 原失败 Run 的状态改为成功，因此不能把仍显示红色的原 Run 状态当作续跑再次失败，也不能在后续运行中混用旧报告。

## 自动流程

新增 `prj/scripts/run_verified_pnr.ps1`，使用最近一次 GUI 生成的 `.prj`、流程和设置，在独立 `prj/log/verified_pnr_syn`、`verified_pnr_phy` 中执行：

1. 从源码完整综合到 `opt_gate`。
2. 从本次综合数据库布局布线到 `opt_route`。
3. 只有同时出现 `PHY-8023` 和 `RUN-8102` 时，才从本次 ECO 数据库自动执行重布线脚本。
4. 检查阶段退出码及日志 ERROR；拒绝旧 ECO 数据库和旧报告；最终确认 setup/hold 不为负。

不生成 bitstream，不改原 GUI 运行配置，不关闭 hold 检查、不放宽约束。输出日志和最终报告路径明确区分初次失败与最终成功，其他失败直接报错。

使用方式（PowerShell）：

```powershell
& "E:\AnLuTD_Project\SD_to_Video\prj\scripts\run_verified_pnr.ps1"
```

如果 TD 安装位置不同，可通过 `-TdCommand` 指定可执行文件。新增文件或修改工程设置后，应先让 GUI 更新运行配置，再使用此脚本；仅修改既有 RTL 时直接运行即可。

## 全流程验证

本轮从用户最近一次 GUI 配置执行完整自动流程，综合得到 14,747 LUT、9,617 REG。默认布线复现相同冲突后，脚本自动识别并续跑，无需手工介入，进程退出码为 0。

最终报告为 `prj/log/verified_pnr_phy/recovered_phy.area`、`recovered_phy.ts`、`recovered_pr.timing`、`recovered_pr.db`，资源和时序与前述 GUI 数据库恢复结果一致：15,125 LUT、9,702 REG，setup +0.115 ns、hold +0.003 ns，setup/hold TNS 均为 0。最终恢复日志无 ERROR，普通布线与时序检查通过。

驱动日志：`prj/log/verified_pnr_driver.log`；初次 P&R 日志：`verified_pnr_phy.log`（保留原失败）；自动恢复日志：`verified_pnr_recovery.log`。两份阶段日志不能混淆，最终结果应以驱动日志指定的新报告为准。

PowerShell 语法检查通过。额外加入数据库和报告的时间戳检查，防止未来重跑时误用旧结果；本轮最终文件时间戳也已人工确认全部晚于本次运行开始。没有修改 RTL，因此不重复已通过的像素仿真。

仍保留 SDRAM 初始位置和局部时钟布线的既有警告，不通过移除约束掩盖。普通时序通过仍不代表实板彩线问题已经解决，未生成 bitstream、未做实板验证。
