# 音游第三阶段：四轨队列与判定引擎

第三阶段实现独立 `rhythm_game_engine`，没有接入板级工程文件集或修改顶层。
第二阶段负责 SD 读取、128 条跨时钟预取和实际 PCM 输出标记；本阶段消费预取记录，
提供判定、统计和供下一阶段显示使用的活动音符视图。板上游戏入口仍未完成。

## 模块与接口

- `src/rhythm_judge_core.v`：四轨各八槽环形队列、Tap/Hold 判定、统计、串行整数计分。
- `src/rhythm_auto_input.v`：根据有效队头和歌曲时间生成 AUTO press 事件，Hold 期间保持 down。
- `src/rhythm_game_engine.v`：输入选择与两模块连接；input_mode 0=AUTO、1=TEST、2=外部输入，3 按 TEST 处理。

全部接口在 25 MHz 游戏/视频时钟域；异步 SD 域的头部元数据必须在下一阶段用稳定数据总线
及同步有效标志传递。`total_notes`、`chart_offset`、`input_mode` 在一局中必须稳定。
切换模式和重开由下一阶段会话控制器停播、等待 SD 事务退出、清空并复位后完成。

`song_time` 为有符号 33 位 PCM 帧时间，支持 -96000 起的两秒预滚。
开始后应单调推进，暂停/音频欠载时冻结，并将 `run` 拉低。
本阶段不自行产生歌曲时间；PCM 有效输出如何驱动预滚/RUN/BUFFER/结尾宽限由下一阶段接入。

`note_data` 沿用 R4B1 八字节记录，时间加 `chart_offset` 后写入活动队列。
上游必须完成第二阶段格式、排序、重复、重叠及时间边界校验。
只有队头开始时间进入 `song_time+96000` 的两秒窗口且该轨有槽时才拉高 `note_ready`；
提前的记录保持在全局预取缓冲中，不能提前弹出。
同拍入队/出队合并更新计数；队列内容不复位，用复位后的有效计数隔离旧数据。
到期第九条记录无槽时保持反压并锁存 `queue_overflow`；会话控制器应将其转为资源错误。

`event_valid/event_ready` 是保持式握手，press/release 和 event_time 必须保持到接收。
四轨掩码与有符号采样时间在接收时锁存，随后四拍逐轨检查，避免和弦各轨使用不同时间。
每轨一次事件只作用于最早未完成队头，空按或窗口外的按下不计分。
物理输入桥未来须在采集时记录时间，并缓存未接收事件，不能以判定器处理时刻代替按下时刻。
`down_mask` 为当前按住电平，恢复运行后用于检查暂停期间松开的 Hold。
AUTO 经过同一事件接口，接收后等待逐轨处理结束再生成下一次事件；TEST 不生成输入。

`view_index[4:3]` 选择轨道，`[2:0]` 选择相对队头第 0..7 个音符。
view_valid/start/end 为组合读出的活动槽视图，单位为采样帧；无效槽的数据不应使用。
`head_valid/head_time` 是四轨队头，`holding_mask` 标识正在持续的队头 Hold。
显示阶段应在帧边界串行扫描并保存几何快照，避免直接用这些多路读信号构建昂贵的逐像素运算。

## 判定和结算

| 等级 | Tap / Hold 头部绝对偏差 | 权重 | 连击 |
| --- | --- | --- | --- |
| Perfect | ≤2400 帧（50 ms） | 10 | 加一 |
| Good | ≤4800 帧（100 ms） | 7 | 加一 |
| Bad | ≤7200 帧（150 ms） | 3 | 清零 |
| Miss | 无输入且超过 +7200 帧，或 Hold 提前松开 | 0 | 清零 |

Hold 头部只保存等级，不增加任何结果计数或连击。持续到尾部自动完成；
松开时间 ≥尾部-2400 帧时成功，早一帧则 Miss。成功沿用头部等级，整个 Hold 只结算一次。
暂停/BUFFER 时不扫描判定，恢复时根据当前 down 电平检查持续状态。
result_valid 为单拍输出，result_lane/result_grade 同拍有效；等级编码 0/1/2/3=Miss/Bad/Good/Perfect。

分数为 `floor(累计权重 × 100000 / 总音符数)`，满分 1000000。
36 位移位长除法每次执行 36 拍，不使用 DSP 或组合除法。
判定可在除法期间继续发生，算完快照后若累计权重变化则重新计算。
因此显示分数允许短暂滞后，`done` 必须同时满足 chart_eof、全部音符已结算及分数已更新到最终权重。
`done` 只表示判定引擎完成，**不表示音乐播放结束或可以提前进入结果页**。
下一阶段应等待实际全部 PCM 输出完成和 150 ms 结尾判定宽限，再锁定结果页。

## 验证

```powershell
& 'C:/Users/murong/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' src/test/run_rhythm_stage3.py
& 'C:/Users/murong/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe' src/test/run_rhythm_engine_synthesis.py
```

四项 ModelSim 仿真通过，编译及仿真 0 错误/0 告警：

1. 外部输入通过游戏引擎验证正负判定窗端点及相邻帧、空按、Hold 头部延迟结算、
   尾部 -2400/-2401 帧松开、自动尾判、1 帧短 Hold、Bad 头部继承、暂停松开/恢复、
   暂停事件反压、四轨和弦时间锁存、带偏移负预滚、视图、满八槽/第九条反压和复位清理。
   混合 Perfect/Good/Bad 验证 666666 分向下取整、Bad 清连击和最大连击保留。
2. 65535 个合成 Tap 的连续 AUTO 判定验证计数/权重/分子上限、大量环形绕回，
   最终 65535 Perfect、combo/max_combo 65535、1000000 分，无容量错误。
3. 真实 Dell's Normal 413 条、49 Hold 的完整加速 AUTO 重放：413 Perfect、combo 413、1000000 分。
4. 同谱 TEST 重放：413 Miss、combo 0、0 分。

真实重放每 16 拍推进 48 帧采样时间，验证完整时间跨度和全部记录，并非实际音频播放仿真。
真实文件由第一阶段 GAME.BIN 生成 notes.hex，不提交音乐/谱面资源。
资源缺失时脚本明确 SKIP，不能视为真实歌曲通过；本次真实资源存在，两模式均实际运行。
日志位于 `prj/log/rhythm_stage3_regression/`。

## 综合与边界

独立 EG4S20BG256 综合：1917 LUT、350 REG、0 BRAM9K/FIFO9K/BRAM32K、0 DSP。
活动队列推断为分布式 RAM，因判定/视图/四轨队头多路读而复制端口，使用 LUT 计入上述资源。
没有引入厂商 IP。
25 MHz 时钟约束下 setup WNS +18.154 ns/TNS 0，hold WNS +0.674 ns/TNS 0，
报告 Fmax 45.775 MHz，首条关键路径 judge/lane_reg[0]→judge/used_reg[2]。
综合 0 错误/0 告警；STA coverage 75.46%，独立工程仅约束时钟，外部接口未建板级 I/O 延迟。
这些数字只代表独立引擎的综合估计，不代表整个项目通过时序或最终路由资源。
报告位于 `prj/log/rhythm_stage3_engine_syn/`。

本次不修改板级顶层、管脚、时钟、厂商 IP，不运行 P&R、不生成 bitstream。
板级资源与第二阶段尚未闭合的时序结论保持不变；既有彩线问题及未提交工程/PLL 文件保持。
下一阶段才接入加载器/PCM 时钟、游戏会话控制、按键模式和四轨显示，最终整板容量及路由时序需重新验证。
