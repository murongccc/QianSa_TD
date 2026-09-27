# BMP 内部完成标志复位布线修复

## 问题及定位

GUI 默认 P&R 失败，报 PHY-8023：`x29y10_w2beg4` 上
`u_audio_playback_control/u_key/rst` 与
`sd_media_pipeline_m0/u_bmp_catalog/rst_dup_22_holdbuf` 争用布线，随后 RUN-8102。

读取该次 `SD_to_Video_eco_pr.db` 的网络连接后确认：第二条网络虽然命名在目录器下，
实际唯一负载是 BMP 读取器的 `frame_seen_reg_syn_17.sr`；它是工具插入的复位 hold 修复缓冲。
连接检查保存在 `prj/log/reset_conflict_inspect.log`。

## 修改

只移除 `bmp_read` 内部 `frame_seen` 在异步复位分支的清零；保留 `ST_IDLE` 接受
`load_start` 时的清零和最后一个源像素到达时的置位。复位时状态机和输出仍照常复位，
该标志只在加载数据状态用于截断检测，进入该状态前必定经过加载初始化。
无需修改顶层、时钟、管脚、厂商 IP 或 P&R 策略。

## 验证

- BMP 边界回归通过：1920×1080 全帧、行填充、负高度、非法尺寸、截断图片。
- 新增完整帧后无复位加载截断帧，以及完整帧后复位再加载截断帧，两者都正确失败。
- BMP/FIFO/scaler/frame commit 集成回归通过；12 条既有 FIFO 可选端口告警。
- 综合 0 错误，告警数与上次均为 57；LUT 14717、REG 9617。
- 使用 GUI 生成的流程、工程文件及默认参数，在独立目录完成全新综合与默认 P&R；
  只调整独立运行目录的综合数据库来源，不调用外部恢复脚本。
- 默认流程正常生成 `.opt_route.end.f` 和最终 `SD_to_Video_pr.db`，无 RUN-8102。
  中间出现两条 `x22y44_local2` 的 PHY-8023 诊断，但工具在同一次默认运行内部自动解决，
  最终明确报告 `All routing violations have been resolved`。这不等于日志中零 ERROR 字样。
- 最终数据库另行执行 `report_route_status -drc` 检查。

最终资源：LUT 15092、REG 9716、BRAM9K（含 FIFO）40、BRAM32K 6、DSP 18、PLL 2。

**时序尚未闭合**：setup WNS −1.323 ns、TNS −2.379 ns；hold WNS +0.003 ns、TNS 0。
最差视频路径为 `u_video_presentation/add2_syn_184` 至 `subtitle_text_pixel_syn_121`，
SD 域 WNS −0.249 ns。本次修复布线失败，不能据此宣称时序或板级稳定性通过。
既有 SDRAM 位置及局部时钟布线告警仍存在。

日志：`prj/log/reset_fix_syn.log`、`prj/log/reset_fix_phy.log`、
`prj/log/reset_fix_final_drc.log`；最终报告位于 `prj/log/reset_fix_phy/`。
未生成 bitstream。用户需在 GUI 从综合开始重新运行，以使用修改后的 RTL。
