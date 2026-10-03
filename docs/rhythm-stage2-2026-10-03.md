# 音游第二阶段：共享 SD 读取与有效 PCM 计时

## 范围与状态

完成可复用 RTL 加载组件、PCM 计时接口、局部仿真和综合核对。
尚未接入 SW11 音游会话、判定和界面；当前板级继续运行媒体模式。
后续必须把加载组件接到现有 SD/音频通路，并完成会话清理及 CDC 元数据握手，
不能直接把独立组件资源数加到整板资源，也不能用旧路由时序代表本次源码。

没有改外部顶层端口、管脚、时钟、厂商 IP 或加密源码，没有生成 bitstream。
顶层唯一改动是显式留空新增 PCM 输出，媒体管线显式连接关闭的游戏选项。
现有工程、PLL、debug 工程和 docs/history 修改保留。

## 模块与接口

### fat32_chart_reader

在 SD 时钟域复用 BMP 目录器已经验证并保持稳定的 FAT32 卷信息。
精确读取根目录 8.3 名称 GAME.BIN，支持多扇区簇和碎片 FAT 链；屏蔽 FAT 高四位。
根目录扫描最多 1024 扇区，避免坏链无限扫描。遇到目录结束项停止搜索。
使用八拍移位加法计算簇地址，没有新 DSP。

每次请求文件扇区前必须 reserve_ready，表示缓存至少有 64 个空记录槽。
请求和地址保持到 sd_done；note_we 单拍，不可在扇区中反压。
文件头提供音乐帧数、音符/Hold 数、偏移和 ASCII 标题/难度。
校验版本、采样率、文件严格长度、头部计数、字符串末尾零、记录类型、排序、
偏移后的时间边界、同轨重复/重叠及最终记录计数。类型和原始时间保持 R4B1 编码。
利用字节采集间隔分开时间/长度算术；已接受记录的历史在 note_we 提交时更新。
最后一条记录提交后才发布 eof，支持最后字节与 sd_done 同拍。

四轨各 8 槽的实际游戏活动队列属于下一阶段；本阶段缓存不会替代它。
转换器检查活动密度，未来游戏核心还要检测超容量，不信任任意外部 BIN。

### rhythm_chart_buffer

128×64 双时钟 RAM，写入在 SD 域，note_valid/ready 在消费者域。
Gray 指针双级同步，写侧占用保守估算；消费停顿时 note_data 保持稳定。
读口使用同步 RAM 预取，只有消费者实际接受才前移读指针。
RAM 不逐项复位，控制指针使未写入内容不可见；综合确认为块 RAM，实际使用 4 个 BRAM9K。
溢出置 sticky overflow；正常调用必须遵循整扇区 64 槽预留。

会话复位同时到两个时钟域，必须在读取取消及总线退场完成后进行。
最终集成需按现有复位同步规范释放复位，并复核 Gray 指针物理 CDC 路径，
独立仿真和综合不能代替最终布局布线 CDC 检查。

### fat32_wav_reader 扩展

ENABLE_GAME 默认 0，原媒体模式仍选择首个 WAV 并循环。
ENABLE_GAME=1 时 game_mode 在开始前稳定并保持至取消/结束；游戏模式精确 GAME.WAV，
校验规范 44 字节 PCM 头、RIFF/目录/data 长度和对齐，输出 song_frames_valid 与 song_frames。
播放一次，生产端 stream_eof 持续至复位；提前 FAT 结束或坏 PCM 置 format_error。
保留媒体模式 LIST/JUNK 等 chunk 跳过行为，修正 EOF 字节边界与 FAT 高位屏蔽。

ENABLE_GAME=1 的 cancel 必须保持到 cancelled，不能直接复位一个还在等待 done 的客户端。
取消期间停止新数据发布，保留当前请求到整扇区 done 后退出。
硬复位仍可立即中止整个系统，但会话重启要用取消握手。

### pcm_audio_player 扩展

新增输出均在视频时钟域，与注册的 audio_valid/左右 PCM 同拍：

| 信号 | 含义 |
| --- | --- |
| sample_emitted | 只有真正输出有效歌曲 PCM 时为 1，单拍 |
| sample_index | 本拍输出帧编号，首帧 0，仅 sample_emitted 时有效 |
| emitted_count | 已输出帧总数，停止归零，暂停/欠载保持 |
| sample_missing | PLAY 时采样节拍缺 PCM 的单拍标记，输出静音 |
| prefetch_ready | 内部同步读预取已完成，持续电平 |

音量为零仍算有效歌曲帧；FIFO 读取属于预取，不能用作歌曲时间。
audio_valid 继续维持 HDMI 48 kHz 节拍，STOP/PAUSE/欠载时仍可能有效。
PREFETCH_PAUSED 默认 0，兼容原行为；游戏可置 1，让 PAUSE 期间预取但不消费。
开始前必须先让 STOP→PAUSE 跨域模式同步完成，再启用新会话生产者，
否则 STOP 清旧 FIFO 的窗口可能吞掉新音乐。恢复和停止都必须考虑模式同步延迟。

实际音乐结束条件是 emitted_count 到达已验证的 song_frames，并处理最后一个
sample_emitted；WAV stream_eof 仅代表生产者结束，不能提前触发游戏结算。
负两秒预滚、播放欠载后的 BUFFER 状态、帧发布和暂停按键属于后续会话控制。

### rhythm_sd_resources

独立组件把共享卷的两个游戏读取器、预取缓存和三客户端仲裁组合起来。
BMP 请求作为第三客户端接入。音频水位低于 1024 帧时优先，非音频之间公平，
扇区归属锁定到 done，响应只发给拥有者。
ENABLE_CHART 默认 0，原 sd_sector_arbiter 的两客户端行为保留。

resources_ready 属于 SD 域，表示头部/音频帧数一致、无错误、至少 64 条谱面记录
和至少 2048 PCM 帧已缓冲；短资源允许 EOF 后用实际数量达到就绪。
metadata 在 header_valid 后保持至会话复位。除 note_* 消费接口外，其他状态均为 SD 域；
下一阶段必须同步 valid 并采集保持总线，不能把整条 metadata 当作任意多位同步器。

cancelled 要求两个读取器已取消且共享端口空闲。取消清理期间必须停止新 BMP 请求，
否则端口仍可能开始新的 BMP 事务。cancel 不清缓存，只有握手完成后的会话复位才清。

| error_code | 含义 |
| --- | --- |
| 0 | 无错误 |
| 1 | GAME.BIN 未找到或目录搜索结束/超过上限 |
| 2 | 卷/文件目录元数据非法或状态异常 |
| 3 | R4B1 头部/文件长度错误 |
| 4 | 音符类型/时间/排序/重叠或最终计数错误 |
| 5 | 谱面 FAT 链提前结束或坏簇 |
| 6 | 预取缓存溢出 |
| 7 | GAME.WAV 未找到 |
| 8 | 游戏 WAV 格式/长度/链错误 |
| 9 | BIN/WAV 音频采样帧数不一致 |

## 验证与复现

```powershell
python src/test/run_rhythm_stage2.py
python src/test/run_resource_regression.py --output prj/log/rhythm_stage2_media_regression --skip-video
python src/test/run_rhythm_resource_synthesis.py
python src/test/run_resource_build.py rhythm_stage2_media_final_syn
```

本机 Python 可使用第一阶段记录中的 bundled runtime，ModelSim 和 TD 已安装。
真实谱面默认使用 `prj/log/rhythm_assets/brave_shine_normal/GAME.BIN`；没有资源时
会显式跳过真实谱面测试，需要先运行转换工具。真实谱面仅作为日志目录中的 fixture，
没有把歌曲或谱面版权资源写入仓库。

- 11 项 ModelSim 仿真、编译均通过，第二阶段日志 0 错误/0 告警。
- 集成加载：130 条合成 Tap/Hold、3000 PCM 帧、碎片簇、128 条缓存停顿与绕环、
  随机消费反压、诱饵 WAV 排除、单次 EOF、三客户端公平/音频优先。
- 真实 Dell's Normal：413 条/49 Hold，七个碎片扇区，每条 64 bit 记录与实际 BIN 相等。
- 错误：坏魔数、缺 WAV/BIN、提前 FAT 结束、Hold 总数错误、非法类型、负偏移、
  WAV 对齐错误、BIN/WAV 长度不符；错误后整扇区取消与重启。
- 整扇区尾部：56 条记录/117 PCM 帧，各文件恰好 512 字节，末字节和 done 同拍完整保留。
- PCM：真实 25 MHz / 48 kHz 节拍、暂停预填充、从零帧编号、欠载冻结、恢复、
  零音量有效计时、停止清理与重新开始。
- 相关媒体回归：MBR/直接卷/共享卷、WAV chunks/FIFO 水位、BMP 五候选目录/FAT、
  BMP 边界/缩放边界/640×480、帧提交均通过。12 条既有厂商 FIFO 可选端口告警保留。
  本阶段没有重跑完整 FFT/视频动态重放，不把 skip-video 当作这些测试通过的证据。

## 综合与限制

独立加载组件：LUT 3597、REG 2024、BRAM9K 4、DSP 0。
它包含一个游戏 WAV 读取器，最终会替换/扩展现有实例，不能简单全量相加。
1 条 RAM INIT 被忽略的工具告警；设计不依赖初始化内容，没有新 latch/多驱动。
综合 setup WNS -0.819 ns / TNS -2.640 ns，hold +0.509 ns / TNS 0。
首条关键路径为仲裁器 state 到 WAV chunk_header_pos；谱面时间和长度加法已分拍，
WAV/仲裁交界仍需最终集成时收敛，不能仅凭仿真宣称满足 100 MHz。
该独立组件尚未闭合时序，后续集成必须处理实际关键路径，不放宽时钟。

当前媒体顶层兼容性综合：LUT 14700、REG 9880、BRAM9K/FIFO9K 55、BRAM32K 6、DSP 15，
相比 2026-09-30 综合 LUT +62、REG +22，RAM/DSP 不变。
0 错误、59 条告警，与基线综合告警数量一致；setup WNS -0.515 ns / TNS -19.868 ns，
hold +0.471 ns / TNS 0。日志为 `prj/log/rhythm_stage2_media_final_syn/`。
这个工程尚未包含独立游戏加载组件，是原媒体通路扩展接口后的兼容性检查。
未进行本次 P&R，因此不能判断真实布局布线后裕量，也不能沿用历史正裕量宣布通过。

本阶段只综合、不布局布线；最终 P&R/DRC、真实歌曲完整播放、AUTO 判定和板级显示
属于后续阶段。原彩色/白色横线问题保留未关闭。
