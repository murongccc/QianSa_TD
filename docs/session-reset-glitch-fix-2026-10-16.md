# 会话复位毛刺修复与验证

## 问题及改动

游戏末尾曾出现短暂 BUFFERING，随后总分和 COMBO 清零、无结算、无重新播放，但轨道仍能响应。缺陷版会话控制器用二进制状态组合译码产生 `engine_reset`，直接驱动判定器异步复位。PLAY=0110 切换 BUFFER=1000 或 TAIL=1001 时，状态位传播先后可能短暂命中复位条件。判定器清空后，会话并未重开，也不会重新加载已消费的音符，导致 `judge_done` 无法再次成立。

产品改动仅在 `src/rhythm_session_controller.v`：

- `engine_reset` 与 `resource_reset` 改为下降沿寄存输出，使用上升沿状态更新后已经稳定的译码值；状态组合输出不再直接进入异步复位端。
- 全局 `rst` 仍可异步断言引擎复位，停钟时同样有效；会话复位撤销与上升沿消费者之间保留半周期。
- 资源清理同样寄存，避免误清 PCM、谱面 FIFO 和 HUD；清理仍覆盖完整 16 个上升沿。
- 保留原有状态转移、计分算法、触摸退场及正常游戏溢出检测。顶层、时钟、管脚约束和厂商 IP 均未修改。

## 仿真

新增 `src/test/run_session_reset_regression.py`、`src/test/tb_rhythm_session_reset_phase.v`，并扩展已有 `tb_game_background_playback.v`，默认场景仍保留原闭环回归。

最终专项日志：`prj/log/session_reset_final_regression_20261016/`。

- 三种非零计分场景：EOF 前真实 SD 断粮、EOF 后末尾 PCM 取数阻塞、无断粮正常收尾。先命中 lane1 Tap 得到 62500 分，要求完整输出 10000 帧，最终 Perfect=1、Miss=15、总分=62500、`judge_done=1` 并进入 RESULT；主动重开后正确清零。
- 修复版在正常输入及带状态位传播延迟的测试副本中，以上三种场景全部通过；期间监视两路复位的异步边沿，任何意外断言立即失败。
- 修改前提交 `240375a` 的同类传播延迟副本，在三种场景均被断言检出意外复位，证明测试能检出旧问题。
- 三种计分场景还使用项目生成的音频 FIFO 物理仿真网表、原厂 `EG_PHY_FIFO` 及原厂 DSP 模型复核，均通过。模型/IP 存在 134 条未连接端口类告警，无仿真错误。
- 全局停钟异步复位、下降沿输出相位、完整 16 拍清理、正常停机和重开均通过，无仿真告警。

传播延迟测试来自缺陷版 GUI 布线的状态位 clock-to-Q 与网络延迟，副本只延迟复位译码输入；不是完整板级 SDF 时序仿真。最终实现另外通过物理网表结构核对与 STA 验证。

完整既有回归：

- `prj/log/session_reset_media_regression_20261016/`：SD/PCM 游戏闭环、暂停/断粮/重开/退出，媒体及音游 BMP/FIFO/双线性缩放/帧提交，碎片 FAT、精确扇区 EOF、取消恢复，谱面 FIFO 基线等价与全局复位测试均通过。
- `prj/log/session_reset_end_regression_20261016/`：9 个 Tap/Hold/Miss/尾段/EOF/双时钟相位收尾场景、171 次计分稳定检查、触摸在途事件退场、正常游戏触摸和音符队列溢出检测、判定器及窄队列回归均通过。渲染器 9 个完整帧场景，每场景比较 307200 个像素，均通过。
- 媒体外壳的 14 条、资源测试的 3 条及渲染测试的 2 条既有告警与上轮相同。

## 综合、布局布线与网表核对

综合：`prj/log/session_reset_fix_syn_20261016/`。LUT=17676（比上轮减少 5），REG=10479（增加 2）；BRAM9K=38、FIFO9K=16、BRAM32K=11、DSP=18。综合告警类别与数量和上轮一致：SYN-5011=20、SYN-5013=3、SYN-5025=3、SYN-6562=10、SYN-6577=1。

物理流程：`prj/log/session_reset_fix_phy_20261016/`。从新综合网表执行完整布局布线和显式 hold 修复，`.opt_route.end.f` 存在，路由 DRC 通过，无多驱动及异常时序路径。保留既有 SDRAM 输出时钟使用局部线路的告警；未更改该时钟或约束。

| 项目 | WNS | TNS |
|---|---:|---:|
| 全局 Setup/Recovery | +1.384 ns | 0 |
| 全局 Hold/Removal | +0.024 ns | 0 |
| video_clk Setup | +3.707 ns | 0 |
| video_clk Hold | +0.027 ns | 0 |

各主时钟报告 Fmax：50 MHz 域 59.773 MHz，25 MHz 视频域 27.554 MHz，100 MHz 内存域 118.287 MHz。全局最差最大延迟检查为内存域已有复位恢复路径 `u_reset_mem/release_sync_reg[1] → u_scaler/mul_a0_b1[7].sr`，余量 +1.384 ns；未放宽时钟或增加 false_path。

最终物理资源：LUT=17773、REG=10621，存储和 DSP 数量保持上述综合配置。STA coverage=99.95%。

只读导出 `reset_netlist_check.v`，检查引擎复位、资源清理和物理复制输出共 8 路，全部来自 `DFFMODE=FF`、`CLKMUX=INV` 的寄存器 Q。结果与源文件、物理数据库、约束及网表 SHA256 保存在 `reset_netlist_check.log/json`，消除了旧版“组合译码直接接异步复位”的结构。

## 复现与实板使用

```text
python src/test/run_session_reset_regression.py
python src/test/run_startup_timing_regression.py --output prj/log/session_reset_media_recheck
python src/test/run_game_end_regression.py --output prj/log/session_reset_end_recheck
python src/test/run_resource_build.py session_reset_recheck_syn
python src/test/run_resource_build.py session_reset_recheck_phy --route --parent session_reset_recheck_syn --clock-hold-fix
```

流程止于 opt_route，未生成位流，未覆盖 GUI 运行目录。用户后续在 GUI 重新综合和布局布线后，仍需执行既有脚本再自行生成位流：

```tcl
source {E:/AnLuTD_Project/SD_to_Video/prj/scripts/fix_hold_before_bitgen.tcl}
```

确认出现 `PASS pre-bitgen hold fix` 且最终 setup/hold 非负。实板应重点检查末尾 BUFFERING 恢复、分数保持、RESULT 页面、结算后触摸及主动重开。本轮未进行实板下载验证。
