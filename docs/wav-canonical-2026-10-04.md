# WAV 规范格式裁剪与旧文件清理（2026-10-04）

本轮按用户要求删除通用 WAV chunk 解析和未使用的旧 SD/音频模块。保留双线性缩放、五图预装、2048 点 FFT/Hann、环形频谱、音游、媒体循环、游戏单次播放及原诊断。板级外部端口、管脚、PLL、时钟和厂商 IP 未修改，未生成 bitstream。

## 新的资源格式

普通媒体与游戏统一接受 44 字节 RIFF/WAVE PCM 头：48 kHz、16 bit、双声道；fmt 长度 16、PCM 标识 1、字节率 192000、块对齐 4；data 位于偏移 36，PCM 从 44 开始。数据必须非空且按完整采样帧对齐，RIFF 长度为目录文件长度减 8，data 长度为目录文件长度减 44。

不再接受 LIST/JUNK/fact、扩展 fmt、尾随块或长度不一致的 WAV。文件格式错误后不输出 PCM，排空当前不可暂停扇区并释放 SD；簇链提前结束时报告截断，媒体不再循环损坏文件。

FAT32 MBR/直接卷、碎片文件和共享卷元数据保留。现有游戏转换器已经生成规范 WAV；实际 GAME.WAV 的 17293728 字节/4323421 帧及完整头字段已核对，无需重复转换。

## RTL 实现

- 删除 chunk ID、chunk 搜索/跳过、奇数填充状态与寄存器。
- 两个长度在目录事务结束后预计算，44 个头字节流式比较，覆盖全部 32 位长度。最终长度高字节检查包含当前输入，不能使用上一拍值。
- 规范 data 完整覆盖 `[44,file_size)`，复用文件位置边界，删除重复的 32 位 data 剩余计数器。
- 新增 DATA_END，在扇区 done 下一拍检查完整更新后的文件位置、PCM 相位和错误标志。删除末字节位置寄存器及同拍旧值补偿链，切断 SD 返回字节经头校验驱动扇区地址使能的路径。末字节同拍 done、取消及共享端口排空均回归。
- 模块外部接口保留。状态寄存器扩为 5 位，以容纳结束检查状态。

## 删除的旧文件

删除 11 个未在当前板级层级实例化的模块：fat32_audio_pipeline、fat32_audio_controller、fat32_wav_data_stream、fat32_sd_audio_arbiter、fat32_single_audio_controller、fat32_boot_parser、fat32_dir_search、fat32_fat_reader、sd_audio_reader、wav_header_parser、wav_data_parser。

删除仅服务上述旧模块的 tb_fat32_audio_controller、tb_fat32_fat_reader；原 tb_wav_streaming_headers 改为 tb_wav_canonical_headers。同步删除工程引用，未清理历史报告/用户历史目录。旧模块此前不占当前板级资源，不能把源码删除量算作 LUT 收益。

独立构建脚本改从当前 `.al` 获取 Verilog 源集，避免 GUI 旧运行目录中的 `.prj` 再引用已删除文件。只提交本轮工程源集删除；既有工程策略/编译顺序、PLL/debug 用户修改保留在工作区。

## 正式保留结果

基线 `prj/log/lut_sd_accepted_syn/`；最终 `prj/log/wav_canonical_accepted_syn/`。LUT 为层级 lut+ripple 口径，父子不可重复相加。小型快照为 `docs/reports/wav-canonical-2026-10-04.json`。

| 项目 | 基线 | 最终 | 差值 |
|---|---:|---:|---:|
| 整板 LUT / 19600 | 19261 | 18671（95.26%） | -590，剩余 929 |
| REG | 12315 | 12190 | -125 |
| BRAM9K + FIFO9K / 64 | 34 + 16 = 50 | 34 + 16 = 50 | 0 |
| BRAM32K / 16 | 11 | 11 | 0 |
| DSP / 29 | 24 | 24 | 0 |
| WAV LUT | 1743 | 1164 | -579（33.22%） |
| WAV SEQ | 848 | 723 | -125 |
| SD 媒体链 LUT | 7762 | 7173 | -589 |
| 综合 setup WNS / ns | -0.243 | -0.363 | 恶化 0.120 |
| 综合 setup TNS / ns | -9.545 | -8.115 | 改善 1.430 |
| 综合 hold WNS / TNS / ns | +0.471 / 0 | +0.471 / 0 | 0 |
| 实际打包 MSlice | 5649 | 5495 | -154，仍超出 595 |

综合零错误、67 条告警，与基线分类及数量一致。SD 域 setup WNS -0.363 ns、TNS -4.707 ns、Fmax 96.497 MHz，最差路径为 BMP 目录器 scan_done → WAV cluster[28]，8 级，延迟 10.247 ns，连线 6.703 ns。视频 +6.820 ns，相移 SDRAM 仍 -0.213 ns/TNS -3.408 ns。setup 尚未闭合，不放宽约束。

实际物理检查在 `prj/log/wav_canonical_pack/`，已启用 -packarea；Place Packing 得到 5495 MSlice/5495 LSlice、1701 个单独 LUT、2099 个单独 SEQ，报 PHY-9009。MSlice 上限 4900，仍超出 595（12.14%），没有完成布局布线，也没有本轮路由时序结论。打包需求下降不能视为已可上板。

两轮中间候选 `wav_canonical_syn`（19193 LUT，WNS -0.898）与 `wav_canonical_final_syn`（19077 LUT，WNS -0.372）均非最终结果；正式源码与报告以 accepted 目录为准。

## 验证

- `wav_canonical_accepted_stage2/`：13 项仿真，包含 122 个媒体/游戏规范头向量、44 个字节逐个故障注入、长度高位/接近 4 GiB 的正例、附加块拒绝、截断链、碎片、循环/EOF、末字节同拍 done、无效卷/重启；原共享 SD、PCM、真实碎片谱和 FAT 末项回归通过。
- `wav_canonical_accepted_stage4/`：五项会话、渲染、播放闭环、媒体冻结和图像隔离回归通过，覆盖暂停、欠载、恢复、重开、退出及结果。
- `wav_canonical_accepted_media/`：18 项媒体/目录/BMP、双线性边界与 640×480、真实源 FIFO 两种集成回归通过；未修改的 FFT/视频算法仅编译，复用此前等价结果。
- 所有上述局部仿真零错误；规范 WAV 测试零告警。第二阶段保留 11 条测试台未连接端口告警，第四阶段保留 3 条；两项真实厂商 FIFO 集成各有 12 条既有可选端口告警。告警涉及的测试台端口与 FIFO 均未在本轮修改。
- 音乐转换工具三项测试通过：去附加块并逐字节保持规范输入 PCM、24 kHz 单声道转 48 kHz 双声道、失败或未授权覆盖时保留原输出。
- 现有 GAME.WAV 规范头与全部长度核对通过；静态检索无已删除模块的有效实例/工程引用，git diff --check 通过。

## 转换与复现

普通音乐使用 `src/python/normalize_wav.py`。FFmpeg 解码为 s16le 后由脚本显式生成 44 字节头，避免 FFmpeg WAV 封装器附加元数据。原文件保留，输出默认不覆盖，替换须显式 --force；转换失败不会破坏已有输出。

本机 WindowsApps 的 python 命令别名不能启动，本轮使用以下可用解释器。ModelSim 32 位程序在执行沙箱内报 WinError 623，回归经执行权限审查在沙箱外运行，日志仍写入工程目录。

```powershell
$taskPython = 'C:/Users/murong/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
& $taskPython src/python/normalize_wav.py '原音乐.mp3' '输出目录/MUSIC.WAV'
& $taskPython src/test/test_normalize_wav.py
& $taskPython src/test/run_rhythm_stage2.py --output prj/log/wav_canonical_accepted_stage2
& $taskPython src/test/run_rhythm_stage4.py --output prj/log/wav_canonical_accepted_stage4
& $taskPython src/test/run_resource_regression.py --output prj/log/wav_canonical_accepted_media --skip-video
& $taskPython src/test/run_resource_build.py wav_canonical_accepted_syn --rhythm
& $taskPython src/test/run_resource_build.py wav_canonical_pack --route --parent wav_canonical_accepted_syn --rhythm
```

普通媒体音乐不要命名为 GAME.WAV，该名称属于游戏资源。最后一个物理命令目前预期在 MSlice 检查失败，不能把工具返回/综合完成标志当成物理实现通过。彩色/白色横线、时序与实板复验继续未关闭。
