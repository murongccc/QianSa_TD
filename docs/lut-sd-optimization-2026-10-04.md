# 保留全部功能的 LUT 与 SD 返回通路优化（2026-10-04）

本轮保留比赛要求的双线性插值、亮度/对比度及参数 OSD、五图预装、2048 点 FFT/Hann、80 柱环形频谱与呼吸、音游及全部诊断。没有改顶层外部接口、管脚、PLL、时钟或约束，没有生成新厂商 IP、布局布线或 bitstream。用户已有工程、PLL、debug 工程和 `docs/history/` 修改保留。

## 实现与接口

- `bmp_read.v`：宽高低 16 位保存；宽高高字节逐字节校验，负高度要求高半字为 `ffff`，正高度要求为 `0000`，再按完整符号检查绝对值范围。位深仅校验 24，压缩方式仅校验零；文件长度和像素偏移仍 32 位。BMP/FAT 项用计数器高七位比较和固定八位移位组装；新增结束后的捕获拍。
- `fat32_chart_reader.v`：固定四字节对齐的 FAT 项组装，取消动态 part-select；`FAT_CHECK` 在扇区结束的下一拍检查完整簇项。最后四字节和最后字节同拍结束不再依赖旧寄存器值。保留碎片链、掩去 FAT 高四位和原错误退出行为。
- `sd_sector_arbiter.v`：`REGISTER_RESPONSE=0` 为默认独立兼容模式；板级游戏/媒体两种共享路径都显式开启。接受事务时锁存 BMP/音频/谱面独热归属，结束采样后清除；`sd_data` 输入和 `response_data` 输出配套六个客户端 valid/done 同延迟一拍。`response_busy` 包含 ACTIVE/GAP 和待消费返回拍；会话取消/清理与 `media_quiet` 使用该信号。保留原公平策略、低水位音频优先和整扇区不可打断。
- `rhythm_sd_resources.v` 新增内部 `bmp_data`、`response_busy` 输出；BMP/目录、WAV、谱面全部使用同一配套返回数据。只改内部模块接口与连线，未改板级顶层。
- `rhythm_hud.v`：静态字符与 16 种状态改为 1024×8 同步 ROM，顺序填字符缓存时预取下一地址。两份标签表分别为 AUTO/TEST，状态表为 16×16，未用地址为空格。标题、难度、数字转换、字符缓存和像素延迟保留。`TEXT_ROM=0` 保留组合逻辑，供严格功能对照；实际板级使用默认 ROM。生成器可重复核对源表。
- `ring_spectrum_renderer.v`：十个边界和一个动态中心系数产品使用显式 9×9 无输入/输出寄存 DSP，原有视频拍数不变。中心系数 256 明确为 9 位无符号，全部乘积 18 位。`DSP_GEOMETRY=0` 保留原移位加法供功能对照；系数、比较、彩虹、圆帽及呼吸保持。修改表生成器，避免手工表与脚本不一致。

## 验证

采用最终源码及已验证且未改变的显示/FFT 结果；日志位于 `prj/log/`，不提交歌曲资源或厂商综合网表。

| 回归 | 覆盖 | 日志 |
|---|---|---|
| SD 两种返回模式 | 512 连续字节；独占归属；末字节同拍/分拍 done；撤回请求/变地址；三方公平及紧急音频；排空及重开 | `lut_sd_equivalence/` |
| HUD/频谱等价 | 16 状态×2 模式，每个写入字符及读像素一致；半径 90～110 的 21 个完整 640×480 画面逐像素一致，包含静音、角度边界和柱长变化 | `lut_sd_equivalence/display_equivalence.log` |
| FAT 末项 | BMP 第一簇 127，偏移 508～511，下一簇 `01000007`；真实谱第一簇 127、下一簇 `01000005`，强制高字节改变地址，同拍末字节/done | `lut_sd_equivalence/bmp_last_fat_byte.log`、`lut_sd_stage2_accepted/chart_last_fat_byte.log` |
| 读取/PCM | 13 项：全部 256 种簇大小及非法根簇、真实 413 条/49 Hold 碎片谱、取消/错误、WAV 附加 chunk、有效 PCM 时间及共享卷 | `lut_sd_stage2_accepted/` |
| 判定 | 六项：打包队列、边界判定、65535 条/百万分、真实 AUTO/TEST | `lut_sd_stage3/` |
| 会话/显示 | 五项：HUD/标题与像素、暂停、欠载、重开、EOF/结果/退出、图片冻结和提交隔离 | `lut_sd_stage4/` |
| 原系统 | 27 项：2048 FFT 存储/逐块等价、频谱和视频；BMP 扩展头、正负高度与非法高位、压缩每字节及位深、行填充/碎片；五图预装；双线性边界与 640×480；真实源 FIFO 两种媒体集成 | `lut_sd_media_fft/` |
| 实际映射 | 字库全部 1024 个地址；HUD 新 ROM 全部 1024 个 INIT；11 个几何产品打包为六片 MULT9X9C | `lut_sd_accepted_syn/mapped_check.v` |

局部编译/仿真零错误、零新增告警；真实厂商 FIFO 集成仍有原十二条可选端口告警。ROM 内容不能仅凭 RTL 仿真认定，另从 TD 导出的实际网表核对。

## 资源和时序

正式保留报告：`prj/log/lut_sd_accepted_syn/`。优化前报告：`prj/log/rhythm_ram_final_syn/`。小型可提交快照见 `docs/reports/lut-sd-2026-10-04.json`。统计 LUT 为逻辑 LUT 加 ripple，层级包含子模块，不能重复相加。

| 项目 | 优化前 | 最终保留 | 差值 |
|---|---:|---:|---:|
| LUT / 19600 | 19566 | 19261 | −305 |
| REG | 12365 | 12315 | −50 |
| BRAM9K | 33 | 34 | +1 |
| FIFO9K | 16 | 16 | 0 |
| BRAM9K 含 FIFO / 64 | 49 | 50 | +1 |
| BRAM32K / 16 | 11 | 11 | 0 |
| DSP / 29 | 18 | 24 | +6 |
| 全域 setup WNS / ns | −0.291 | −0.243 | +0.048 |
| 全域 setup TNS / ns | −7.017 | −9.545 | −2.528 |
| hold WNS / TNS / ns | +0.471 / 0 | +0.471 / 0 | 0 |

HUD 从 735 降至 659 LUT（−76）；环形渲染从 1474 降至 1220（−254）；BMP 从 1436 降至 1368（−68）。谱面读取器含 FAT_CHECK 从 1243 增至 1258（+15），其结束边界修复有控制成本，两个解析器合计净降 53 LUT；保留其完整字段验证和末字节正确性。仲裁器从 76 增至 118（+42），换取配套返回寄存边界。整板收益不能由局部差值直接相加，其他层级的映射、扇出复制亦改变。

SD 域 setup −0.243 ns、TNS −6.137 ns、Fmax 97.628 MHz，仍未达到 100 MHz。旧仲裁状态到 BMP top_down 的八级路径退出报告最差端点；新最差路径为 WAV `file_pos_reg[12]` → `chunk_header_pos_reg[0]`，八级，数据延迟 10.127 ns，其中连线 6.599 ns。视频 setup +5.669 ns；普通 SDRAM 时钟 +0.994 ns；相移 SDRAM 时钟仍 −0.213 ns/TNS −3.408 ns。STA coverage 99.93%。零综合错误，67 条告警（基线 66），没有新增告警类别。新增两处 HUD 初始化诊断：循环初始化索引被当作初值、初始化 ROM 被报无常规驱动；另减少一条匿名实例告警。实际一片 RAM 和全部 1024 个 INIT 已逐项核对，不能仅忽略初始化诊断而不检查映射。

LUT 剩 339，距 19000 的线还差 261，距后续 17500 目标差 1761。**本轮资源收益已确认，SD WNS 略改善但 TNS 恶化，SD 100 MHz 与全域时序仍未闭合；不能认定已可稳定上板。** 没有放宽约束，没有进入布局布线，也没有生成 bitstream。彩色/白色横线与实板验证继续未关闭。

## 已舍弃的后续候选

第一版 `lut_sd_candidate_syn/` 即最终保留结构。试验把 WAV 的文件位置比较换成寄存剩余标志：`lut_sd_final_syn/` 为 19255 LUT，但 SD WNS −0.918 ns，瓶颈转移到谱面启动的簇大小校验。进一步改为固定八个合法簇大小集合：`lut_sd_release_syn/` 为 19222 LUT，但 SD WNS −0.790 ns/TNS −18.084 ns，瓶颈转到取消控制至谱头字段使能。两项功能回归均通过，但整板 SD 时序恶化，最终撤回。保留其报告和快照作比较；这两个目录名不代表最终采用。恢复后独立构建 `lut_sd_accepted_syn/` 确认源码和报告一致。

## 复现

在项目根使用可用的 Python、ModelSim 和 TD 运行；工具需要当前机器相同的 SDK/IP 搜索路径。只执行综合，不执行 `--route`。

```powershell
python src/test/generate_rhythm_hud_text.py --check
python src/test/generate_ring_visual_tables.py --check
python src/test/run_lut_sd_regression.py
python src/test/run_rhythm_stage2.py --output prj/log/lut_sd_stage2_accepted
python src/test/run_rhythm_stage3.py --output prj/log/lut_sd_stage3
python src/test/run_rhythm_stage4.py --output prj/log/lut_sd_stage4
python src/test/run_resource_regression.py --output prj/log/lut_sd_media_fft
python src/test/run_resource_build.py lut_sd_accepted_syn --rhythm
python src/test/verify_rhythm_font_rom.py --build prj/log/lut_sd_accepted_syn
python src/test/verify_lut_sd_mapping.py --build prj/log/lut_sd_accepted_syn
```

下一轮应围绕 WAV `file_pos`→chunk 更新和谱面取消/谱头使能分开验证控制路径，并同步争取 LUT 余量；不合并整个 FAT32 引擎，不删除比赛要求或现有功能。只有资源留有足够余量且全域时序闭合后再做最终布局布线。
