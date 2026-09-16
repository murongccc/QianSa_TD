# SD_to_Video 当前状态

更新时间：2026-09-16 21:56（当前源码，未生成 bitstream）

## 已完成修复

- `bmp_bilinear_scaler` 已修复奇偶行缓存推进落后一行的问题；行可用性检查和水平/垂直插值均已流水化，并增加 `abort` 恢复入口。
- `sd_media_pipeline` 已对 `write_req_ack` 做两级同步，保持 `write_finish` toggle CDC；BMP、缩放器和 SDRAM 两个完成事件任意先后都由保持型提交状态汇合。
- 加载失败会中止缩放器并释放媒体控制器，避免永久卡在加载态。
- 数码管新增阶段码：`A`=源 FIFO/扇区节流，`B`=BMP 已结束而缩放器仍在排空，`C`=等待 SDRAM 写完成，`D`=加载失败/中止。原 0–4 含义保留。
- `key2` 仍为手动下一张，`swkey2` 仍为自动播放电平开关；未修改顶层外部端口和管脚映射。
- 两个 PLL 的 reset 已接板级复位；50 MHz、100 MHz、125 MHz SDRAM、25 MHz 视频域分别使用异步置位、同步释放并保持 1024 个本地域周期的复位。
- FAT32/WAV 文件定位中的乘法和多级地址加法已拆拍，避免与图像链路共用的 100 MHz SD 域出现长组合路径。

## 工程和时序约束

- `prj/timing.sdc` 已加入 `prj/SD_to_Video.al` 的 `constraint_1`，顺序 1；`pin.adc` 顺序 2。
- SDC 已删除不存在的 `u_audio_pll` 和错误的 video/HDMI exclusive 关系。
- TD 实际读取约束后能看到全部 6 个时钟：50 MHz `clk`、100 MHz `sd_card_clk`、125 MHz `ext_mem_clk`、125 MHz/180° `ext_mem_clk_sft`、25 MHz `video_clk`、125 MHz `hdmi_5x_clk`。
- 当前源码可以成功 analyze/elaborate/optimize gate，无 black box；新复位模块已被工程识别。

## 已通过仿真

- 2×2→4×4：四角、行末、帧末和输出反压通过。
- 640×480→640×480：输入/输出均为 307200 像素，逐行标识、首末行和 `done` 通过。
- 完整 `BMP -> FIFO -> scaler -> frame_commit` 通过；只有厂商 FIFO 未连接可选端口的已知警告。
- 媒体控制器：首帧、手动三槽循环、加载中排队和 SW2 自动播放通过；SW2 测试已消除 NBA 取样竞态。
- FAT32/WAV reader 回归通过。

## 时序现状（必须如实保留）

旧报告只分析 50 MHz 输入时钟，不能作为时序通过证据。加载真实 SDC 后，问题已从隐藏状态变为可见：

- 最近一次当前源码综合估算：100 MHz SD 域 WNS `-1.733 ns`、Fmax `85.230 MHz`；相比最初 `-4.075 ns`/`71.048 MHz` 已明显改善，但仍未闭合。
- 50 MHz、25 MHz 和 HDMI 125 MHz 域为正裕量。
- 125 MHz SDRAM 逻辑域综合估算约 `-2.293 ns`；180°相移硬宏 I/O 路径约 `-5.291 ns`。
- 较早一次完整布局布线（后续 RTL 优化前）全局 setup WNS `-6.565 ns`、hold WNS `+0.003 ns`。最差为厂商 `EG_PHY_SDRAM_2M_32` 数据输入硬宏路径；该报告不是最终当前源码报告。
- 未添加虚假的 false-path/exclusive 约束来隐藏这些路径，因此目前不能宣称满足“所有 WNS 非负、目标 0.5 ns”。

## 用户下一步

1. 不要使用旧 bitstream。当前源码尚未由 Codex 生成 bitstream。
2. 在 TD GUI 中重新运行综合和布局布线，确认日志包含 `read_sdc ../../timing.sdc`，Clock Summary 必须显示上述 6 个时钟。
3. 在 100 MHz SD 域和厂商 SDRAM 硬宏时序均闭合前，不应把板级随机黑屏视为已经完全解决。
4. 时序闭合后由用户生成并烧录 bitstream，连续上电/复位至少 10 次；再分别测试 `key2` 连切 10 次及 `swkey2` 自动轮播。
5. 若仍停滞，记录数码管码：`A/B/C/D` 可分别定位 SD/FIFO、缩放排空、SDRAM 完成或加载失败阶段。

## Git 与工作区

- 已提交：`eaa2cdf Fix scaler row progression and media handshakes`。
- 已提交：`9de54f4 Add synchronized resets and real timing constraints`。
- 工作区内其他既有修改不得覆盖或清理。
