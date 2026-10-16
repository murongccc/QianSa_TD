# 游戏结束后的触摸输入退场修复（2026-10-16）

## 问题与改动

音符全部判定且分数计算完成后，`judge_done` 变为 1，判定器停止接受触摸事件。旧的触摸桥仍在 PLAY/TAIL 中生产事件，继续按下/松开可能积满队列，触发 `touch_game_fault`，会话显示 ERROR EA。项目当前歌曲的最后音符早于音频结束，因此存在正常的音频余段。

本次只改两个产品逻辑位置：

- `top_tf_hdmi_audio.v`：触摸桥使能增加 `!judge_done`，全部判定完成后立即启动跨时钟停用，使用桥已有的源域清队列和重新启用确认逻辑。
- `rhythm_game_engine.v`：外部输入 `event_ready = use_external && (done || core_ready)`。done 后接收并丢弃跨域停用前的在途事件，即使 `run` 被渲染快照暂停也可完成退场。判定器自身的 ready 仍为 0，不处理这些事件，计数和分数保持不变。

会话的 PLAY→TAIL→RESULT 条件、音频播放、尾部时间、错误检测与错误锁存均未改动。正常游戏期间 done 为 0，原触摸反压与溢出检测完整保留；音符队列的溢出检测也未屏蔽。顶层端口、时钟、PLL、管脚、厂商 IP、SDC 和上轮临时关闭的 D/F/C 诊断配置保持原状。

## 仿真

新增 `tb_rhythm_end_retirement.v` 和 `run_game_end_regression.py`，使用板级相同的窄队列、DSP 引擎、触摸 CDC 桥和会话控制器，日志在 `prj/log/game_end_regression_20261016/`。

已通过的九个收尾场景：最后 Tap、Hold、Miss，最后 Tap 在 TAIL 中完成，延迟谱面 EOF，最后 Miss 在真实 7200 采样的 TAIL 窗口内完成，以及三个补充时钟相位/频率关系。每个场景都验证：

- 帧快照阻塞时的在途输入退出；触摸源停用、待提交事件/按住状态/源队列清空。
- 音频余段仍继续，收尾后进入 RESULT，连续触摸不改变最终分数、判定计数和连击。
- 结果页重开后恢复输入，上一局数据不泄露。
- 游戏中故意阻塞触摸队列，真实溢出仍锁存 ERROR EA。
- 游戏中填满同轨音符队列，真实溢出仍锁存 ERROR EA。

九个场景共检查 171 次结果稳定性。旧 `f4fd3fa` 引擎不能通过“done 后快照期间排空”断言；恢复旧的桥使能也不能通过“触摸源退场”断言，两个反例都按预期被拒绝。

既有桥、会话、判定边界、窄队列快照和窄队列判定回归通过。全分辨率渲染会话复位兼容性检查了九个场景，每场逐一验证 307200 个对齐像素，均通过，覆盖有效区中重开、行/场消隐、低 VS 及清理屏蔽 VS 边沿。该原有用例耗时 3 分 46 秒，测试上限沿用原视频回归的 600 秒，两个既有未连接端口告警未扩大到新收尾用例；新增收尾用例均零告警。

`run_startup_timing_regression.py --output prj/log/game_end_media_regression_20261016` 通过真实 SD/PCM/游戏闭环、暂停/断粮/重开/退出、每轮 10000 个连续 PCM 帧，及普通/音游媒体外壳的 BMP/FIFO/双线性缩放/帧提交回归。

## 综合与最终时序

独立综合：`prj/log/game_end_retire_syn_20261016/`。LUT 17681，比上轮减少 13；REG 10477，BRAM9K 38＋FIFO9K 16、BRAM32K 11、DSP 18 不变。综合告警类别和数量与上轮相同。

独立完整物理流程：`prj/log/game_end_retire_phy_20261016/`，从 `opt_place` 至 `opt_route`，包含上轮已交付的显式 `--clock-hold-fix` 步骤；退出码 0，`.opt_route.end.f` 存在，路由 DRC 通过。

| 时钟域 | setup WNS / TNS（ns） | hold/removal WNS / TNS（ns） |
| --- | --- | --- |
| 全局 | +0.647 / 0 | +0.030 / 0 |
| 50 MHz 控制/SD | +1.425 / 0 | +0.030 / 0 |
| 25 MHz 视频 | +0.647 / 0 | +0.030 / 0 |
| 100 MHz SDRAM | +1.452 / 0 | +0.147 / 0 |

最差 setup 为视频像素 x 计数至频谱环 `inside_side_stage`，预算 40 ns，数据路径 39.001 ns、18 级逻辑；视频域报告 Fmax 25.411 MHz。新的结束条件不在该最差路径上。布局变化会影响其他模块的布线余量，仍以本轮最终报告为准。

最终 LUT 17775、REG 10605、BRAM9K 38＋FIFO9K 16、BRAM32K 11、DSP 18。显式 hold 修复通过引脚延迟处理 2 个端点，最终 setup/hold 均非负。没有通过 false_path 或放宽时钟掩盖违例，没有生成 bitstream，也没有覆盖 GUI 的旧运行目录。

## 复现与上板

```text
python src/test/run_game_end_regression.py
python src/test/run_resource_build.py game_end_recheck_syn
python src/test/run_resource_build.py game_end_recheck_phy --route --parent game_end_recheck_syn --clock-hold-fix
```

GUI 使用时重新加载磁盘工程，从综合开始运行 P&R；随后沿用上轮步骤，在 TD 控制台执行：

```tcl
source {E:/AnLuTD_Project/SD_to_Video/prj/scripts/fix_hold_before_bitgen.tcl}
```

确认输出 `PASS pre-bitgen hold fix`、最终 setup/hold 非负，再由用户生成位流并下载。实板重点检查最后一次按下/松开后的音乐余段、正常进入结算、结算页连续触摸以及重开首颗音符。本轮未进行实板验证。保留了其他用户未提交改动。
