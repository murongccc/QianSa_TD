# 启动相关时序修复与帧签名诊断临时关闭（2026-10-16）

## 范围

针对用户提供的 `Timing.txt`，处理复位 removal、谱面 FIFO RAM 地址 hold，并按用户后续要求暂时关闭帧签名诊断。没有修改游戏出块、预滚动、音频采样计时、判定、PLL、时钟频率、管脚或 SDC。没有修改厂商 IP，没有生成 bitstream。

## 改动

- `top_tf_hdmi_audio.v`：`VIDEO_SIGNATURE_DIAGNOSTICS` 默认改为 0，裁剪 D/F/C 三处帧签名诊断，隐藏对应数码管页；FIFO 空读 B 页和 AXIS 反压 A 页保留。原 SDRAM 签名比较到计数器 CE 的负 setup 路径随诊断关闭而移除。
- `domain_reset_sync.v`：保持原保持计数，前两级在上升沿同步，末级在下降沿撤销。负载的上升沿与复位撤销之间有半周期余量；末级的异步断言来自上一级，停钟与短复位脉冲仍有效。相对原来的末级上升沿，释放边界提前半个周期。
- `rhythm_chart_buffer.v`：在写时钟下降沿锁存写地址，随后上升沿仍使用原来的数据和握手写 RAM，避免写指针刚递增就改变 BRAM 地址。读侧及 Gray 指针跨域不变。
- `prj/scripts/fix_hold_before_bitgen.tcl`：显式执行 `fix_hold -clock_opt`、路由 DRC 和最终 STA，先备份物理数据库，仅在 setup/hold WNS 均非负时写回 `SD_to_Video_pr.db`，不生成位流。
- `run_resource_build.py`：增加显式 `--clock-hold-fix` 选项，将上述步骤放在正常 `opt_route` 的 `route` 与最终报告/导出之间。默认行为不变，没有自动重试或增量恢复。

## 时序结果

| 结果 | setup WNS / TNS（ns） | hold/removal WNS / TNS（ns） |
| --- | --- | --- |
| 用户提供的 routed 报告 | -0.401 / -0.401 | -0.060 / -0.530 |
| 诊断关闭与 RTL 修复后，默认 P&R | +1.124 / 0 | -0.004 / -0.004 |
| 显式 `fix_hold -clock_opt` 修复后 | +1.124 / 0 | +0.024 / 0 |

默认 P&R 的唯一剩余违例位于 HDMI 厂商 IP 内部音频 FIFO 地址端口。TD 日志明确说明 Slice 利用率超过 90% 时跳过普通自动 hold 修复；普通定向 buffer 修复也跳过。布局前 hold 修复选项在此器件上不受支持，因此未写入主工程。`clock_opt` 实际通过 LUT bridge/引脚延迟处理该路径，频率、PLL、SDC、时钟偏斜不变，路由 DRC 通过。不能把默认 GUI P&R 的 -0.004 ns 报告描述成已经闭合。

最终完整流程在 `prj/log/startup_timing_final_phy_20261016/` 从 `opt_place` 开始、以 `opt_route` 结束，退出码 0，`.opt_route.end.f` 已生成。`route` 后直接执行脚本，再由正常流程导出最终报告与物理数据库；未通过额外导入数据库续跑来替代此验收。日志确认 `6 out of 6 EP fixed by pin delay` 和 `PASS pre-bitgen hold fix`，最终结果与表格第三行一致，路由 DRC 通过，没有 bitstream。

最终资源为 LUT 17792、REG 10619、BRAM9K 38＋FIFO9K 16、BRAM32K 11、DSP 18；STA coverage 99.95%。相对原 routed 结果，LUT 减少 400、REG 减少 266、BRAM32K 减少 4。最差 setup 为 `u_reset_mem/release_final` 到 SDRAM `rw_vld`，预算 5 ns、数据路径 3.571 ns、裕量 +1.124 ns；视频域 setup +3.812 ns、hold +0.024 ns，50 MHz 域 setup +3.068 ns、hold +0.067 ns。

综合网表来自 `prj/log/startup_timing_diag_off_syn_20261016/`，综合告警数量和类别与原 `syn_1` 一致：73 条，未引入新类别。局部脚本验证在 `prj/log/startup_timing_hold_script_test_20261016/`。保留的 PHY-5079 为既有 SDRAM 相移时钟单扇出局部路由，未修改相关硬宏或约束。

## 功能验证

`src/test/run_startup_timing_regression.py --output prj/log/startup_timing_diag_off_regression_20261016` 已通过：

- 谱面 FIFO 与修改前 `2fcd138` 的逐拍等价：681 次写、427 次读，双时钟、满/空、溢出、指针回卷、取消复位。
- 复位保持窗、下降沿释放、立即异步断言、停钟后恢复、不覆盖时钟沿的短脉冲。
- 手动会话的预滚动、PCM 驱动时间、暂停、缓冲、尾部、结果、重启与退出。
- D/F/C 诊断页的禁用和其他页轮换。
- 真实 SD/PCM/游戏闭环，每轮连续输出 10000 个 PCM 帧，覆盖暂停、断粮、重启和退出。
- 普通/音游媒体外壳的 BMP/FIFO/双线性缩放/帧提交，以及碎片谱面、精确扇区边界、EOF、取消与重启。

脚本失败保护另用真实 -0.004 ns 数据库验证：保留负 hold 时，拒绝导出 `SD_to_Video_pr.db`。日志在 `prj/log/startup_timing_hold_guard_test_20261016/console.log`。

## 用户后续操作

1. TD GUI 重新加载磁盘工程，从综合开始运行 P&R，确保使用本次源码和关闭诊断的默认参数。
2. P&R 完成后，在 TD 控制台执行：

   ```tcl
   source {E:/AnLuTD_Project/SD_to_Video/prj/scripts/fix_hold_before_bitgen.tcl}
   ```

   默认加载并备份 `prj/SD_to_Video_Runs/phy_1/SD_to_Video_pr.db`，通过修复与 DRC/STA 后更新该数据库，并输出 `PASS pre-bitgen hold fix`。失败时不能继续生成位流。
3. 检查 `SD_to_Video_phy.ts` 的 setup/hold 均非负，再由用户生成、下载 bitstream。若重新运行 P&R，需要再次执行上述脚本。
4. 实板观察第一批音块能否从 READY 连续下落到判定线，以及音乐/频谱开始时是否仍出现空档。本轮时序与功能仿真不能代替该验证。

独立命令行复现（均不生成位流）：

```text
python src/test/run_resource_build.py startup_timing_recheck_syn
python src/test/run_resource_build.py startup_timing_recheck_phy --route --parent startup_timing_recheck_syn --clock-hold-fix
```

后续若把 `VIDEO_SIGNATURE_DIAGNOSTICS` 恢复为 1，必须重新验证资源及签名诊断路径的时序，不能沿用关闭诊断时的结论。保留了用户原有未提交改动，没有覆盖 GUI 的旧运行结果或用户的 `current-state.md`。
