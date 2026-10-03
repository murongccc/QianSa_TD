# 四轨音游实施记录

## 实施状态（2026-10-03）

第一阶段资源转换、第二阶段读取/采样同步基础、第三阶段四轨判定引擎及第四阶段会话/显示集成已完成。
读取基础见 [第二阶段记录](rhythm-stage2-2026-10-03.md)，判定与完整 AUTO/TEST 重放见
[第三阶段记录](rhythm-stage3-2026-10-03.md)。板级集成、控制和验证见
[第四阶段记录](rhythm-stage4-2026-10-03.md)。当前综合容量接近上限且 setup 未闭合，尚未 P&R/生成 bitstream，不能认定已具备稳定上板条件。
下列资源转换结果属于第一阶段；最新源码资源和时序以 current-state.md 顶部记录为准。

- 源资源：Aimer - Brave Shine (TV size) (Ibrahim).osz。
- 难度：Dell's Normal，原生 Mode 3 / CircleSize 4。
- 413 个音符：364 Tap、49 Hold，四轨数量 105 / 99 / 106 / 103。
- 每轨活动槽峰值 6 / 5 / 6 / 5，容量预算为每轨 8 槽。
- 首音符 29088 采样（606 ms）；最后尾部 4264848 采样（88851 ms）。
- 音乐 4323421 帧，90.07127083333333 秒，48 kHz / 16 bit / 双声道 PCM。
- GAME.BIN 3368 字节；GAME.WAV 17293728 字节。
- 15 项合成边界回归通过；独立解析源 HitObjects 与二进制的 413 条记录逐条相等，
  Hold 数量、WAV 规范头、采样帧数、源和输出 SHA256 校验通过。
- 未改顶层、播放链、管脚、时钟、厂商 IP；未综合、布局布线或生成 bitstream。

生成资源保存在 `prj/log/rhythm_assets/brave_shine_normal/`，不提交歌曲资源到 Git。
原始 .osz 没有被修改，转换时不向磁盘解压谱面包的其他文件。

## 转换工具

工具：`src/python/osz_to_game.py`，仅依赖 Python 标准库及 FFmpeg。
支持 `inspect` 检查和 `convert` 单难度转换。路径包含空格时需引用。

```powershell
python src/python/osz_to_game.py inspect "C:/Users/murong/AppData/Roaming/osu/exports/Aimer - Brave Shine (TV size) (Ibrahim).osz"
python src/python/osz_to_game.py convert "C:/Users/murong/AppData/Roaming/osu/exports/Aimer - Brave Shine (TV size) (Ibrahim).osz" --difficulty "Dell's Normal" --output prj/log/rhythm_assets/brave_shine_normal --ffmpeg E:/ffmpeg/bin/ffmpeg.exe
python src/test/test_osz_to_game.py
python src/test/test_osz_to_game.py --verify-real "C:/Users/murong/AppData/Roaming/osu/exports/Aimer - Brave Shine (TV size) (Ibrahim).osz" --output prj/log/rhythm_assets/brave_shine_normal
```

本机 Python 未加入 PATH，可将上述 `python` 替换为：

```powershell
& 'C:/Users/murong/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
```

再次转换到已有输出目录需要显式 `--force`，否则拒绝覆盖。
`--offset-ms` 为有符号整数，正值延迟音符，默认零；偏移后音符必须仍在有效音频范围内。
验证完整后才发布输出；解析、解码或校验失败时保留已有资源。

将生成的 GAME.BIN 与 GAME.WAV 成对放在 FAT32 卡根目录，保留已有 BMP。
当前板级尚未接入，复制文件不能直接启动音游。后续媒体模式的“第一个 WAV”选择需要与
游戏资源隔离，避免把 GAME.WAV 当作错误的游戏音乐来源。

转换拒绝非原生四轨、无音符、重复同轨头、同轨 Hold 重叠、未支持的音符类型、
容量溢出、无效音频路径、找不到音乐以及超出歌曲时间范围的谱面。
忽略 osu! 的变速、皮肤、故事板和打击音，保留轨道、起始时间和 Hold 时长。
inspect 会列出拒绝原因；Brave 难度当前活动槽需求超出预算，不会静默转换或删减。

## R4B1 文件协议

这是本项目自定义格式，所有整数为小端。时间单位为 48 kHz 立体声采样帧，
一帧含左右声道各一个 16 bit 采样。不是左右声道样本总数，也不是字节位置。

### 64 字节头部

| 字节偏移 | 长度 | 内容 |
| --- | --- | --- |
| 0 | 4 | ASCII `R4B1` |
| 4 | 4 | u32 采样率，必须 48000 |
| 8 | 4 | u32 音乐 PCM 帧数 |
| 12 | 4 | u32 总音符数，1..65535 |
| 16 | 4 | u32 Hold 数量，不大于总音符数 |
| 20 | 4 | i32 音符偏移采样数，正值延迟；不改变音乐 |
| 24 | 24 | ASCII 曲名，至少末字节为 0 |
| 48 | 16 | ASCII 难度，至少末字节为 0 |

标题和难度按 23 / 15 字节截断，非 ASCII 替换为 `?`；完整名称在报告中保留。

### 8 字节音符记录

| 记录偏移 | 长度 | 内容 |
| --- | --- | --- |
| 0 | 4 | u32 原始命中采样位置，运行时加头部偏移 |
| 4 | 3 | u24 持续采样数，Tap 为 0，Hold 必须大于 0 |
| 7 | 1 | bits 1:0 轨道 0..3；bits 3:2 类型 0=Tap、1=Hold；bits 7:4 为 0 |

按 `(命中时间, 轨道)` 排序，和弦为多条相同时间的独立记录。
Hold 尾部为头部加持续时间。文件总长必须严格等于 `64 + 8 × 总音符数`。
转换器按 `[头部-96000, 尾部+7200]` 闭区间计算每轨活动槽峰值，超过 8 拒绝。

### WAV 约定

固定 44 字节标准 RIFF 头：fmt 长度 16、format 1、channels 2、rate 48000、
byte rate 192000、block align 4、bits 16，data 紧随其后。
头部帧数必须与 WAV data 字节数除以 4 相等。完整解码，禁止自动裁剪或拉伸音乐。
报告中的 SHA256 用于电脑端核对源和成对输出；首版 BIN 头不含音频内容哈希，
板级只能核对长度和格式，不能识别同长度但不同内容的音乐，复制时必须成对更换。

## 阶段划分与既定行为

1. 读取与同步：共享 FAT32 卷、精确文件名、碎片链、128 条预取、四轨各 8 槽；
   音频低水位优先，开始前 PCM 预缓冲至少 2048 帧；单次播放和实际 PCM 输出计时。
2. 判定核心：Tap/Hold、统一四轨输入、AUTO/TEST、暂停恢复、归一化百万分和结算。
3. 显示集成：640×480，四轨 x=96..543、判定线 y=384、2 秒下落；
   锁定并压暗当前 BMP，隐藏频谱/参数 OSD，保持原有 RGB/DE/VS 两拍对齐。
4. 验证收敛：局部仿真、完整歌曲加速仿真、相关媒体回归、综合与最终一次默认 P&R。

SW3/SW4=11 游戏，其余媒体；SW1 停止/从头开始；KEY2 重开/错误重试；
KEY3 暂停恢复；KEY4 AUTO/TEST，运行中切换重开；游戏中冻结 SW2 轮播。
未来输入通过 press/release/down 掩码和采样时间接入，不增加首版外部端口。

Perfect/Good/Bad 窗口分别为 ±50/100/150 ms（2400/4800/7200 帧），权重 10/7/3，
Miss 权重 0；Perfect/Good 增加连击，Bad/Miss 清零，空按忽略。
Hold 头部判定后按住到尾部自动完成，允许尾部前 50 ms 松开，更早松开失败。
每个 Hold 整体只计一次，成功沿用头部等级，完成时更新分数和连击。
暂停和音频欠载时冻结时间/判定；恢复根据当前按住状态检查 Hold。

完整歌曲 AUTO 目标 413 Perfect / combo 413 / 1000000 分，TEST 目标 413 Miss / 0 分。
最终必须验证模式切换、扇区事务退场、FIFO 清理、暂停、欠载及原媒体功能回归。
资源预算和时序只有实际映射报告能确认，不沿用旧报告；彩线问题继续保留未关闭。
