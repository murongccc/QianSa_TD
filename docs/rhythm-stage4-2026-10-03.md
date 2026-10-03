# 音游第四阶段：板级会话与显示集成

2026-10-04 已完成 [队列打包与 RAM 重分配](rhythm-ram-optimization-2026-10-04.md)。本记录的容量与时序为优化前基线，当前结果以新记录及 current-state.md 顶部为准。双线性插值缩放为比赛要求，必须保留。

本阶段把前三阶段的资源读取、PCM 计时、四轨判定接入现有媒体工程，完成可仿真的 AUTO/TEST 原型。外部端口、管脚、PLL、时钟和厂商 IP 不变；使用已有器件 RAM/DSP 原语，没有生成新 IP，也没有生成 bitstream。

## 用户可见行为

| 控件 | 游戏模式 | 媒体模式 |
| --- | --- | --- |
| SW3/SW4 | 两者为 1 时进入游戏 | 其余组合按原逻辑选择图像参数 |
| SW1 | 0 停止；1 从头启动 | 控制原媒体音频停止/启动 |
| KEY2 | 重开；错误页重试 | 原手动切图 |
| KEY3 | 暂停/恢复 | 原参数增加 |
| KEY4 | AUTO/TEST 切换，运行中切换会重开 | 原参数减少 |
| SW2 / UART 切图 | 游戏中冻结并消费命令，退出后不补执行 | 恢复原轮播和 UART 控制 |

默认 AUTO。TEST 不产生四轨击打，供检查下落与 Miss；板级尚未连接触摸屏或键盘。游戏与媒体切换时保留当前显示图片/预装槽，等待在途切图提交后锁定背景。退出时等待 SD 整扇区排空，清理共享读取器/FIFO，再启动普通媒体 WAV。媒体查找排除 GAME.WAV，避免把游戏歌曲选成轮播音乐。

界面为 640×480：四轨 x=96..543，每轨 112 像素；判定线 y=384；音符在两秒内从 y=64 落到判定线。白色判定线、青色 Tap/Hold 头、蓝色 Hold 身体、弱轨道分隔、顶端进度、左上暂停标记、中央连击、右上百万分、底部标题与难度。背景为当前 BMP 的四分之一亮度；缺少背景时保持黑底游戏界面。游戏中隐藏环形频谱与参数 OSD；退出恢复媒体呈现。

当前字体为 ASCII 5×7、小写转大写，保持资源转换阶段的英文标题/难度。结果页显示 P/G/B/M 计数和最大连击，等待用户重开；错误页显示 E 与错误码。此版不含选曲菜单、判定闪光、中文字体、触摸交互和动态判定线。

## 实现与握手

- `rhythm_session_controller` 运行于视频域，统一控制媒体/游戏音频。流程为 RETIRE → CLEAR → STOP → SETTLE → LOAD → 两秒 PREROLL → PLAY → 150 ms TAIL → RESULT；支持 PAUSE、BUFFER、ERROR。
- RETIRE 保持 cancel，等待读取器取消确认和图片/SD 空闲后才清 FIFO。不可暂停的 SD 扇区继续传输到 done；不能因首显已经提交就立即清理。CLEAR/SETTLE 各留 16 个视频时钟，避免播放器停止排空消耗新会话数据。
- LOAD 等待谱头/歌曲长度一致、至少 64 条谱面预取（短谱 EOF 例外）和至少 2048 帧 PCM（短曲 EOF 例外），并等待播放器自身预取。就绪状态保持到取消/复位，避免跨域漏过水位条件。
- 歌曲时间来自 `pcm_audio_player` 实际输出的有效采样序号。暂停和欠载不推进歌曲时间；预滚与末尾宽限才使用本地 48 kHz 节拍。BUFFER 预填充分水位或生产端 EOF 后恢复，最后一帧的暂停/恢复也能正确进入 TAIL。
- `sd_media_pipeline` 复用一个 WAV 读取器和三客户端扇区仲裁，保留 BMP 五槽预装、碎片 FAT 链、低水位音频优先和在途事务归属。谱面元数据用单写/同步读 RAM 传到视频域，宽标题总线不进入板级 HUD。
- 引擎的四轨活动队列采用两份同步块 RAM，分别服务判定和显示/AUTO 查询。AUTO 串行轮询四轨，查询口切换后等待数据有效；外部输入接口仍在引擎中保留。
- 每个视频帧在消隐期间冻结判定和谱面消费，串行读取 32 槽并转换几何，发布双缓冲结果。音乐输出继续运行；冻结时长约 50–70 µs，远小于 50 ms 判定窗。行消隐在 64 拍内计算下一行的四轨覆盖掩码，避免逐像素比较 32 个音符。
- HUD 在消隐内串行转换分数与各项计数；判定暂停期间直接复用稳定计数，分数长除法在第一次数字读取前完成。字符缓存和字库同步读取，提前两像素预取下一字符，在字符末尾的空白区完成切换；仍保持原 RGB/DE/VS 两拍对齐。
- 几何/字符缓存使用 BRAM9K，字库推断为一块 1024×9 ROM；活动队列与标题缓存使用 BRAM32K。计分分子使用一颗 DSP，进度分子使用两颗 DSP；精确分数仍通过整数长除法归一化。
- 谱面最多 65535 条，文件计数采用 20 位。目录超过 1 MiB 的文件在截位前拒绝；魔数/采样率/计数高位逐字节校验。四轨历史 RAM 不复位内容，首次记录由 lane_seen 隔离，排序与 Hold 重叠校验保留。

## 验证结果

- 第四阶段五项 ModelSim 回归通过，编译及各项仿真 0 错误/0 告警：会话状态/控制、实际 RAM 显示、SD/PCM/判定/显示共享查询闭环、媒体冻结、图像按键隔离。
- 显示检查覆盖青色头、蓝色 Hold、判定线、背景压暗/黑底、HUD 数字/元数据、实际字符 RAM 同步延迟、文字首像素与两拍 RGB 对齐。额外检查 DSP 进度高位、负预滚与 32 位歌曲长度边界。RTL 导出的预览位于 `prj/log/rhythm_stage4_regression/game.png`、`result.png`、`fallback.png`；这是固定测试场景，并非实板照片。
- 播放闭环使用携带帧号的 10000 帧立体声 PCM、真实 FAT/WAV/谱面读取器、双时钟 FIFO、16 条音符（含两个 Hold）、实际同步队列和显示快照；逐帧核对从零开始的帧号/左右声道。覆盖暂停、SD 饥饿后 BUFFER、恢复、AUTO/TEST 切换、重开、音乐 EOF/结果和退出。
- 第三阶段四项回归通过：边界/和弦/偏移/Hold/暂停、65535 音符的计数和精确百万分、真实 Dell's Normal 全曲 AUTO **413 Perfect / 413 combo / 1000000 分**、TEST **413 Miss / 0 分**。真实整曲检查的是资源与判定引擎，未声称已完整板级播放 90 秒 GAME.WAV。
- 第二阶段十一项回归通过，覆盖真实 413 条/49 Hold 的碎片谱面、缓存绕环/反压、错误/取消重启、同时末字节与 done、媒体排除 GAME.WAV。新增超大文件、计数高位和采样率高位错误回归通过。
- 相关 WAV/BMP/FAT、五槽控制、缩放边界/640×480、真实厂商源像素 FIFO 与帧提交回归通过；新增 ENABLE_RHYTHM=1 的媒体壳层安全退场检查通过。该集成仿真保留原有厂商 FIFO 12 条可选端口告警。视频/2048 点 FFT/频谱兼容回归亦已通过。

## 综合与尚待完成的收敛

最终综合 LUT **19540/19600（99.69%，仅余 60）**、REG 12150、BRAM9K 47 + FIFO9K 16 = **63/64**、BRAM32K **15/16**、DSP **18/29**。报告目录为 `prj/log/rhythm_stage4_release_syn/`。资源压缩前曾超出 LUT 和 BRAM32K，不能使用中间报告代表最终候选。最终仅进行综合，不 P&R。

综合估计 setup WNS **−0.846 ns**、TNS **−16.163 ns**；hold WNS **+0.471 ns**、TNS 0；STA coverage 99.93%。视频域 setup +6.258 ns/Fmax 29.637 MHz；SD 域 setup −0.846 ns/Fmax 92.200 MHz，未满足 100 MHz。ext_mem_clk_sft 组也有 −0.213 ns 裕量。只有综合估计，尚无本次路由结论。

SD 首条最差路径为三客户端仲裁器 `state_reg[1]` → BMP 目录器 `dir_end_pending_reg`，数据延迟 10.730 ns、逻辑 8 级，网延迟占约 67%。下一阶段应检查共享扇区 valid/done 的组合扇出与目录捕获路径，不能直接宽泛设置 false-path/multicycle。

最终综合 0 错误、66 条告警，新增文件编译序号冲突已消除。告警包含既有厂商 IP/加密源/兼容 FFT 分支、RAM 初始化/字节使能提示和常量 ROM 驱动提示。动态 RAM 使用有效指针/标志隔离未写内容；字库全部 INIT 已核对。仍需后续 P&R、DRC 和板级复验，不能把告警数量或 RTL 仿真替代物理验证。

容量接近上限，综合通过不保证布局布线能容纳或收敛时序。下一阶段必须先降低资源占用并处理 SD 域关键路径，再进行默认 P&R，核对 setup/hold/removal、DRC 和实际 RAM/DSP 数量。不能把综合估计或历史正裕量作为当前板级通过结论。旧的偶发彩色/白色横线继续保留未关闭。

## SD 卡资源及复现

使用 FAT32 卡，根目录放转换产物 `GAME.BIN` 和 `GAME.WAV`；建议保留原五张 BMP 和一个普通媒体 WAV。当前原型每次使用一首精确名称的歌曲；替换歌曲需重新转换并覆盖这两个资源。Brave Shine / Dell's Normal 产物仍在 `prj/log/rhythm_assets/brave_shine_normal/`，没有提交歌曲或修改原 `.osz`。

```powershell
python src/test/run_rhythm_stage2.py
python src/test/run_rhythm_stage3.py
python src/test/run_rhythm_stage4.py
python src/test/run_resource_regression.py --output prj/log/rhythm_stage4_media_regression
python src/test/run_resource_build.py rhythm_stage4_release_syn --rhythm
python src/test/verify_rhythm_font_rom.py
```

需要可用的 Python、ModelSim 和安路 TD。所有日志写入 `prj/log/`；构建到 opt_gate，字库检查从综合网表解码全部 1024 个 INIT 项。由用户在完成后续资源/时序收敛后自行生成 bitstream 并上板。

工程 `.al` 已加入音游 RTL；Git 仅提交本次源集增量，保留原工程属性、PLL、debug 工程和 `docs/history/` 的既有未提交修改。
