# E8 地址选位与重开背景亮度修复

## 已知事实和范围

用户同卡旧版正常，新版进入游戏立即稳定报E8。F:上的GAME.BIN/WAV、原始短目录项、两份FAT及完整簇链都与原转换产物一致；真实卡首WAV簇225，spc64，首LBA23912。用真实启动扇区运行当前读取器与实际SPI控制器均可正常预取，未发现资源损坏或纯协议对齐问题。

通过最新路由DB单独筛选实际每拍变化的乘法计数器网络，确认 `multiply_bit→cluster_product` setup −2.468 ns。用户要求跳过外接采集，因此尚未捕获实际失败扇区和头字节；本次修复确定的时序缺陷，增加错误子原因，不宣称已唯一锁定实板E8根因。

背景亮度定向仿真则明确复现：游戏清理导致renderer.frame_enabled下降，原顶层又用它选择压暗，部分扫描区域从302418恢复C09060，下一真实帧恢复。本次同时修复这个独立控制缺陷。

## 实现

- **WAV选位流水**：CALC_MULTIPLY只锁存 `spc[multiply_bit]`，新增CALC_ADD累加、移位及推进索引；八轮每轮两拍。32位截断乘积、全部8位spc数学结果、扇区请求稳定性和取消语义保持。没有用宽泛multicycle/false-path处理违例。
- **E8可观测性**：读取器保留第一个错误子原因，头末字节或非整帧长度另行归类。目录大小/首簇异常、头字段、完整RIFF/data长度、提前FAT结束分别记录。保留完整校验，不允许错误数据进入PCM。
- **节省总线/CDC资源**：资源组件使用原四位错误总线保留码11～14传递E8子类，不新增板级端口或宽调试总线。会话要求连续两次同步错误值一致，队列溢出同步标志仍即时处理。
- **背景**：顶层将video_presentation.game_active从renderer帧有效改为session游戏状态，显示模块只在真实帧边界切换压暗模式。UI像素仍依赖renderer就绪；重开等待快照不影响背景亮度。
- **SPI参数**：S_WAIT_READ_WRITE保持SPI_HIGH_SPEED_DIV，修复只改参数却被强制写0的问题。默认值0仍约25MHz；值2约12.5MHz。未修改默认时钟、MISO采样点、CRC处理、引脚或厂商IP。

| 屏幕显示 | 原四位资源码 | 含义 |
| --- | --- | --- |
| E8H | 11 | RIFF/WAVE/fmt/data标识或PCM固定字段错误 |
| E8L | 12 | RIFF/data长度、文件长度或完整采样帧对齐错误 |
| E8F | 13 | 数据截断、提前FAT结束、坏簇或EOF边界错误 |
| E8M | 14 | 目录首簇/文件大小非法 |
| E8 | 8 | 未分类的WAV错误，保留兼容含义 |
| EA | 10 | 游戏判定队列溢出，保持原含义 |

子类只描述读到的数据在哪里被拒绝，不能单独判断是文件问题、读地址问题还是SPI返回误码。

## 验证

WAV/SD/SPI第二阶段20项、补充三项、游戏九项共32次仿真通过，零错误。新增取消测试后来纳入正式stage2脚本，因此复现脚本会直接包含该项。

- 124个规范WAV向量，媒体/游戏、44字节逐个故障注入、长度高位、目录小文件/非法首簇、截断和错误原因；错误释放/循环/单次EOF保持。
- 256种spc×6边界簇号=1536地址向量，完整32位数学结果一致；分拍期间取消不发请求，已发LBA23912保持至done。
- 原SD仲裁、真实碎片谱、FIFO边界、末字节与done同拍、媒体延迟启动通过。
- 完整真实SPI收发模型支持合成/真实卡扇区，核对CMD17地址、512字节边界和2048个PCM帧。默认返回延迟0/19ns通过；20ns故障正确分类为E8H；HIGH_SPEED_DIV=2下25ns模型通过。这是数字模型测试，不是实板延迟测量或I/O签核。
- HUD验证E8H/L/F/M和原E8/EA字符；短暂错误码不锁死，稳定子类及队列错误正确保留。
- 游戏进入/退出只在帧边界改变背景；九个清理场景逐像素检查恢复坐标，背景区域保持四分之一亮度。暂停/欠载/重开/模式切换/结果/退出、618240图案像素检查继续通过。

全部编译零告警。第二阶段保留七条既有可选端口告警（资源组件3、仲裁4），游戏播放保留3条；新测试零告警，WAV新增输出在既有调用处显式连接或留空，避免新增告警。

```powershell
python src/test/run_rhythm_stage2.py --output prj/log/rhythm_e8_fix_20261006/stage2 --real-chart prj/log/rhythm_assets/brave_shine_normal/Brave_Shine.BIN
python src/test/run_rhythm_stage4.py --output prj/log/rhythm_e8_fix_20261006/stage4
python src/test/run_resource_build.py rhythm_e8_fix_syn_20261006
python src/test/run_resource_build.py rhythm_e8_fix_phy_20261006 --route --parent rhythm_e8_fix_syn_20261006
```

真实卡SPI测试在存在诊断启动hex时执行；该音乐扇区不提交仓库。没有fixture时，合成数据SPI测试仍正常执行。

## 默认P&R、定向时序和限制

整板综合LUT17787/REG10515，相对修复前+74/+10；BRAM9K36+FIFO9K16=52、BRAM32K11、DSP24保持。70条告警类别/数量一致，无latch。默认完整P&R约3分37秒完成，正常生成最终DB和.opt_route.end.f，未出现PHY-8023/PHY-8096/RUN-8102。

| 路径/资源 | 修复后实际路由 |
| --- | --- |
| 原变化计数器相关最差 | +2.936 ns |
| 新选择寄存器→累加 | +0.404 ns |
| 全域setup WNS/TNS | −2.472 / −398.316 ns |
| 全域hold/removal WNS/TNS | −0.020 / −0.115 ns |
| 视频setup | +0.349 / 0 ns |
| 内存setup | +0.132 / 0 ns |
| SD最差setup | −2.472 ns，BMP扇区计数→状态 |
| WAV其他控制路径 | file_pos→cluster.ce −2.177 ns；state→entry_size_low −2.068 ns |
| 物理MSlice/LSlice | 4825 / 4826，各容量4900 |
| 最终LUT/REG | 17948（91.57%）/10630 |

原选位违例已消除，但整个WAV/SD链及全域时序仍未闭合；没有将其他路径声明为假路径或放宽约束。独立导入最终DB进行DRC无多驱动、异常时序路径或未完全布线诊断。既有SDRAM位置PHY-7002、局部SDRAM_CLK的PHY-5079告警保留。

I/O输入返回尚无完整SPI接口时序约束，CRC校验也没有在本次新增。后续板测仍可能暴露其他控制时序或采样误码；本次不是稳定性验收版本。

报告在prj/log/rhythm_e8_fix_phy_20261006，定向查询和DRC在prj/log/rhythm_e8_fix_20261006/phy_check.log、fixed_counter_paths.timing、fixed_selected_paths.timing、wav_all_related_paths.timing。

## 用户下一步

从综合开始重新构建、布局布线；本轮不生成bitstream，不写SD卡。检查新时序报告，再按自己的板测流程下载。反复KEY2/KEY4确认背景不再局部亮起，观察游戏是否加载。若仍失败，请反馈具体E8H/L/F/M，便于进一步区分；卡资源无需重新转换。

用户四个既有工程/PLL/debug修改文件SHA256保持不变。顶层仅改背景控制内部连线，外部端口、约束和管脚不变。
