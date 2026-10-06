# 音块样式版本的默认布线失败修复

## 失败与定位

用户 18:33 的 GUI 运行从 `opt_route` 导入 18:24 的 place DB，最终报四条 open nets，以及局部线段冲突 `x21y35_e2beg4`：

- 缩放器 `x_fp[20] / [19]`；
- 刷新调度器 `refresh_gap[0] / [4]`；
- 冲突线段：`refresh_gap_meta[9]` 与 `u_video_presentation/u_ring_spectrum_renderer/sub7_syn_4[7]`。

只读导入失败 `SD_to_Video_eco_pr.db` 并通过 `report_nets -connection` 确认实际驱动/负载。TD 打包后的物理 slice 可能包含不同逻辑模块的 LUT，故不能根据物理 slice 的实例名推断错误信号连进了其他模块。

原版 4810 MSlice 未超过 4900 容量。用修复前同一综合网表、GUI 默认流程和参数，在独立目录重新执行完整布局/布线，仍出现同一四条 open nets 和同一线段冲突，最终 `.opt_route.error.f`。因此，重新布局本身不足以修复，不能把此次根因断言为旧 DB 缓存。

用户失败日志另存 `prj/log/route_fix_20261006/user_route_failure.log`，网络连接检查为 `connections.log`；原版完整失败对照在 `prj/log/rhythm_note_style_clean_phy_20261006/`。

## 最小 RTL 修改

新样式原本分别保留每轨头部六位和尾帽三位的行描述，两份工作/发布缓存各占一组。修改后共用每轨六位：

- 头部：`{Hold,图案行[4:0]}`；
- 长条：`{3'd0,尾帽有效,图案行[1:0]}`。

合法谱面已由读取器保证同轨 Hold 不重叠，后一条音符开始不早于前一 Hold 结束。头部优先，长条只在没有头部覆盖该行时使用共用描述。Tap 紧接 Hold 尾部时二者圆角边界一致，由独立逐像素参考验证。取消工作/发布尾帽描述共 **24 个寄存器**，改变网表打包与布局；未改图案规格、算法、采样时刻或像素延迟。

此次不修改报错网络所属的缩放器/刷新调度器，也不修改顶层、管脚、PLL、时钟、SD 子系统、厂商 IP 或约束。双线性缩放、频谱、媒体与游戏功能保留。

## 仿真及工具脚本

原样式独立逐像素参考继续通过，块 RAM/分布式几何两种模式共 **618240** 个游戏区像素；新增同轨 Tap 位于 Hold 尾部的圆角重合边界。原有重叠、裁剪、宽条、配色、箭头/短横和保持锚定继续验证。

八项游戏回归全部通过，连续真实 VS 的九场景/2764800 坐标回归也通过。编译零错误/零告警；仅播放集成保留三条既有可选端口未连接告警。

```powershell
python src/test/run_rhythm_stage4.py --output prj/log/route_fix_20261006/regression
```

独立构建脚本发现两个流程问题并修正：

1. 不应继承 GUI 最后一次操作的 `start_step=opt_route`。新独立目录没有已有布局；现在综合固定从 `read_design`，物理固定从 `opt_place` 开始，仍使用默认综合/布局/布线参数。
2. 原 `source SD_to_Video.tcl; exit` 在 source 失败时跳过 exit，TD 留在提示符，Python 等待进程无法结束。现在捕获错误、输出消息后 `exit 1`，成功 `exit 0`。从实际 Python 源码提取生成的 Tcl，在 TD 原生运行受控成功/失败两种 smoke，确认退出状态0/1且无挂起。

测试输出在 `prj/log/route_fix_20261006/`。原版失败后停留在提示符的辅助进程已按隔离目录 PID、程序路径和父 Python 脚本核对后关闭，没有关闭用户 GUI。

## 综合、完整默认 P&R 与 DRC

```powershell
python src/test/run_resource_build.py rhythm_route_fix_syn_20261006
python src/test/run_resource_build.py rhythm_route_fix_phy_20261006 --route --parent rhythm_route_fix_syn_20261006
```

候选整板综合 **LUT17713 / REG10505**，相对原版 LUT 保持、REG减少24；BRAM9K36＋FIFO9K16=52、BRAM32K11、DSP24。70条综合告警类别/数量与原版一致，零错误。综合 setup −0.213 / −3.408 ns，hold +0.471 / 0 ns。

候选从新网表完整布局到布线，采用 GUI 默认流程和参数，约4分11秒完成，正常生成 `.opt_route.end.f` 及最终 `SD_to_Video_pr.db`。本次未调用额外 ECO 恢复脚本、修改 seed/effort 或放宽时序。最终日志无 PHY-8023、PHY-8096、RUN-8102。

独立再导入最终 DB 做 `report_route_status -drc`：无多驱动、无异常时序路径、无未完全布线诊断。既有 PHY-7002 SDRAM 位置与 PHY-5079 SDRAM_CLK 局部布线告警仍保留。DRC 输出 `prj/log/route_fix_20261006/candidate_drc.log`。

| 实际物理结果 | 数值 |
| --- | --- |
| MSlice / LSlice | 4834 / 4842（各容量4900） |
| route QoR 合计 slice | 9676 / 9800（98.73%） |
| 最终 LUT / REG | 17885 / 10615 |
| BRAM9K + FIFO9K | 36 + 16 = 52 / 64 |
| BRAM32K | 11 / 16 |
| DSP | 24 / 29 |
| 全域 routed setup WNS / TNS | −2.706 / −214.362 ns |
| 全域 hold/removal WNS / TNS | −0.020 / −0.069 ns |
| 视频 setup | +0.225 / 0 ns |
| SD setup | −2.706 / −212.328 ns，Fmax78.703 MHz |
| 内存 setup | −2.034 / −2.034 ns |

**这次验证证明默认布线报错已消除，没有证明时序或实板稳定性通过。** 尽管寄存器减少，实际物理 slice 并未减少；不能由 REG/LUT 变化推算物理容量。当前容量余量很小，最终时序仍明显违例，需要后续独立处理。

本轮未生成 bitstream，未改变用户已有工程/PLL/debug 修改（四文件 SHA256 核对不变）。用户 GUI 应从综合开始重新运行，再重新布局、布线；只对旧 place DB 继续 route 不会载入本次 RTL 修复。检查新的最终时序报告后再判断是否具备稳定上板条件。
