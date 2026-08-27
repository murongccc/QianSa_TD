# SD_to_Video 项目续作说明

## 项目与工具

- 工程：`prj/SD_to_Video.al`
- 顶层：`top`，源码：`src/top_tf_hdmi_audio.v`
- 器件：Anlogic `EG4S20BG256`
- 工具：Tang Dynasty `v6.2.168116`
- 板级输入时钟：`clk`，50 MHz，R7；复位为低有效 `rst_n`，A2。
- 用户自行在 TD GUI 运行综合、布局布线和下载；Codex 不运行 TD flow，也不生成 `.bit` 文件。
- TD GUI 日志统一保留在 `prj/log/`，该目录由 `.gitignore` 排除，不提交到 GitHub。

## 已确认的稳定基线

- HDMI 图片显示、TF 扫描、SDRAM 三帧缓存、KEY1/KEY2 按键和自动播放曾在板上验证正常。
- 当前项目的已推送稳定提交：`25eecf7 Add stable TD FPGA media player project`，远端：`https://github.com/murongccc/QianSa_TD` 的 `main`。
- 不要将 `prj/SD_to_Video_Runs/` 中的历史 `.bit` 当作可靠回退；运行目录会被覆盖。
- 工程已通过 `.gitignore` 排除 TD 运行目录、日志、转储和锁文件。

## 赛题要求更新（来源：`赛题解析一.pptx`，2026-08-26）

以下为本次赛题解析中相对项目原有“图片播放 + HDMI 音频”目标新增或
进一步明确的要求。后续功能取舍、验收和演示应以本节为准；PPT 中的实现
框图仅作参考，不是必须照搬的工程结构。

### 基础要求：新增/明确项

1. **素材规格明确**：必须从 TF 卡经 SPI 读取 `640×480`、`24-bit RGB`、
   **非压缩 BMP** 图片，解析后写入 SDRAM 帧缓存，并经 HDMI 实时显示。
2. **图片播放要求明确**：必须同时具备按键手动切换和自动轮播；切换期间
   画面应连续稳定、无明显闪烁或异常。
3. **HDMI 音频成为必做项**：必须经 HDMI 输出 `48 kHz` 音频测试音，并实现
   音视频同步播放；不再仅以图片显示和切换作为基础完成功能。
4. **交付与平台约束明确**：必须使用 **HX4S20C** 开发板；最终设计须固化到
   开发板，上电即可运行，形成稳定且适于现场演示的完整系统。
5. **完整性约束**：基础要求在最终设计中必须全部实现，不能只演示其中部分。

### 扩展要求：当前五项清单及变化

扩展要求现统一为以下五项，最终设计**至少实现 1 项**；完成项越多、质量越高，
得分越高。相较于项目当前已有的亮度/音量状态条和 UART 控制，只有“实时调节
与信息叠加”具备部分基础，其余均仍是待实现的赛题扩展方向。

1. **图层叠加与字幕效果**：图片播放时叠加动态文字（如时间戳、标语），
   支持多图层混合与平滑滚动。
2. **图片切换与转场特效**：轮播时加入淡入淡出、滑动等过渡效果，保证切换
   连续。PPT 建议淡入淡出可采用双帧缓存和 Alpha 渐变，滑动可采用行缓存。
3. **图片缩放适配**：支持不同分辨率图片的读取与缩放显示，以适配 HDMI
   输出分辨率，并尽量优化缩放质量。
4. **实时调节与信息叠加**：使用板载开关或按键实时调整亮度、对比度等显示
   参数，并在画面上叠加当前参数值和调节状态。当前 UART 亮度调节与 OSD 状态条
   可作为基础，但若按此条验收，仍需补充板载输入和对比度调节。
5. **音频可视化与自主创意**：由音频数据生成频谱或波形，叠加到视频画面；
   可进一步结合 ADC/DAC、电机、点阵、多屏等外设实现音视频联动。

### 已实现扩展 1：图层叠加与字幕效果（2026-08-26，待 TD GUI 上板验证）

- `src/video_presentation.v` 在 `video_clk` 域实现两层 OSD，不改动 TF、SDRAM
  帧缓存、HDMI 时序或音频通路：
  1. 底层为画面底部 `y=428..461` 的半透明黑色横幅（原图 RGB 的 75%）；
  2. 上层为黄色 5×7 点阵滚动文字，2×像素放大，位于 `y=438..451`，默认标语
     为 `ANLOGIC HDMI MULTIMEDIA OSD`。
- 滚动速度为每秒 80 像素，512 像素周期循环；不依赖外部 ROM/IP，也不新增引脚。
- 原有亮度/音量状态条仍具有更高显示优先级；字幕横幅与文字只在有效显示区叠加。
- 可通过修改 `video_presentation.v` 的 `subtitle_char` 函数替换英文标语；当前
  字库只包含此标语所需大写字母和空格。中文字体或可配置字幕需要另加字库 ROM
  和配置接口，不能直接写入 UTF-8 文本。
- 自检 testbench：`src/test/tb_video_presentation.v`。ModelSim `vlog` 已成功编译
  `video_presentation.v` 和该 testbench；执行 `vsim` 时因本机 ModelSim license
  初始化失败而未能运行。工程尚未使用 TD GUI 编译、布局布线或上板验证，须由用户完成。

### 赛题通用验收约束（本次新增记录）

- 基础和扩展功能必须整合在**同一份最终固化设计**中；评测时不得通过反复
  加载不同固化镜像，分别演示基础与扩展功能。
- 最终设计须具有实用性。
- 例程 1、例程 2 仅为参考；赛题中的例程 4、例程 5 可分别作为图片显示和
  HDMI 音频的实现参考。
- 评测不以资源使用量为依据；设计建议在满足功能和稳定性的前提下优化逻辑与功耗。

## 功能架构

- `src/sd_media_pipeline.v`：扫描并缓存前 4 个 BMP 文件，负责 SD 读取与写帧数据通路。
- `src/media_session_controller.v`：播放策略，负责首图、KEY1 下一张、KEY2 自动播放开关、固定 3 秒自动轮播和帧槽提交。该稳定路径不接受 UART 播放控制。
- `src/video_presentation.v`：视频域显示效果、亮度控制。
- `src/pcm_playlist_engine.v`：视频域 PCM 音频发生器、音量控制。
- `src/SD/frame_read_write.v`：SD 写入到 SDRAM、SDRAM 到视频读出的 FIFO/帧缓存通路。
- `src/media_session_controller.v` 中按键消抖模块名为 `media_key_press_debounce`，不可改回 `key_press_debounce`，因为旧的 `src/SD/sd_card_bmp.v` 也含同名模块，会引起 TD 重复模块报错。

## 引脚约定

| 信号 | 引脚 | 说明 |
|---|---:|---|
| `key1` | B2 | 下一张，低有效，内部上拉 |
| `key2` | C1 | 自动播放开关，低有效，内部上拉 |
| `uart_rxd` | F12 | CH340 → FPGA，空闲高 |
| `uart_txd` | D12 | FPGA → CH340 |
| `clk` | R7 | 50 MHz |
| `rst_n` | A2 | 低有效复位 |

完整约束文件：`prj/pin.adc`。不要猜测或随意修改引脚。

## UART 当前改动（尚待用户手动编译验证）

当前工作区相对 Git 提交 `25eecf7` 有未提交 UART 改动：

- `src/uart_command_control.v`
  - 115200、8N1 UART 接收。
  - 正确收到的每个字节通过 `uart_echo_tx` 原样回显。
  - `B/b` 调亮/调暗；`V/v` 调大/调小音量；`N/n` 下一张；`A/a` 切换自动轮播；`1~4` 设置轮播间隔为 1~4 秒。
- `src/top_tf_hdmi_audio.v`
  - 新增顶层 UART RX/TX，UART 接收/回显实例。
  - 亮度、音量连接到已有的视频/音频同步器。
- `src/media_session_controller.v` 和 `src/sd_media_pipeline.v`：UART 播放命令采用“保持命令数据 + 翻转事件标志”跨到 `sd_card_clk`，不直接跨域使用单周期脉冲。
- `prj/pin.adc`：新增 F12/D12 约束。
- `prj/SD_to_Video.al`：已新增 `src/uart_command_control.v` 到 Source Files。

### 最近错误及修复

首次 UART 综合失败的直接原因是：

```text
HDL-7144 unknown module uart_command_control / uart_echo_tx
HDL-8007 ... is a black box
```

原因：`uart_command_control.v` 未出现在 TD 工程 Source Files。现已在 `prj/SD_to_Video.al` 加入。

此外，TD 6.2 会把 `uart_command_control.v` 里带 Xilinx 风格
`ASYNC_REG` 属性的 `rx_meta` 触发器报成时钟未驱动（`SYN-5011`）。该
属性已移除，保留标准两级同步器；UART 的亮度与音量信号也在各视频域内
通过两级寄存器同步，避免直接跨域影响显示数据通路。

### 亮度、音量挡位和画面提示（2026-08-22）

- 原亮度路径将乘法结果直接截为 8 位；当增益超过 1.0 时会发生溢出回绕，
  造成红蓝异常。现在逐色分量使用饱和裁剪到 255。
- UART 亮度和音量均改为固定 0~7 的 8 挡范围，按到边界不会再溢出或反向。
  `B/b` 为亮度加/减；`V/v` 的音量映射为静音、12.5%、25%、50%、100%、
  150%、200%、250%，默认第 4 挡（100%）。音量使用明确的有符号移位/加法，
  不使用混合 signed/unsigned 乘法，因此档位严格单调。
- 每次使用 `B/b/V/v` 后，HDMI 画面左上角会显示约 3 秒的两个 8 段状态条：
  上方黄色为亮度，下方绿色为音量；亮起段数即当前挡位（0~7）。
注意：`PRJ-7002 Load IPC file . error`、`PHY-7002 U3/sdram location not honored`、`PHY-5079 SDRAM_CLK local routing` 是既有 Critical Warning。此前时序通过时未阻塞功能；不要把它们误当作 UART 编译错误。

## 后续操作

1. 用户在 TD GUI 手动综合、布局布线、生成位流并下载；日志查看 `prj/log/`。
2. 上板先验证 HDMI 首图、KEY1 单次切图、KEY2 自动播放开关、固定 3 秒轮播；再单独验证 UART 的回显、`B/b`、`V/v`。
3. UART 上板验证成功后：`git add` 相关源文件和本文件，提交并推送到 `main`。

## 播放控制卡死修复（2026-08-26，待上板验证）

- 症状：图片切换/自动轮播在运行一段时间后同时失效。
- 根因：`src/sd_media_pipeline.v` 原来仅在 **BMP 源读取完成** 与 **SDRAM 写完成
  toggle 跨域脉冲** 恰好同一 `sd_card_clk` 周期出现时，才产生 `frame_commit`。
  两个完成事件本来没有固定相位关系；一旦写完成先到，单周期事件会丢失，
  `media_session_controller` 的 `load_inflight` 永远不清零，故后续按键请求和自动
  轮播均无法启动。
- 修复：写完成事件改为 `write_complete_pending` 保持标志，等本次 BMP 装载确实离开
  空闲态并重新返回 `ready` 后再提交该帧；提交后清除标志。这样无论 SD 或 SDRAM
  哪一侧先完成都不会丢事件，也不会把上一帧的迟到完成事件复用到下一帧。
- 验证：ModelSim `vlog` 已成功编译 `media_session_controller.v`、
  `sd_media_pipeline.v` 及原有播放控制自检 testbench。`vsim` 仍因本机 license
  初始化失败无法运行；请在 TD GUI 重新综合、实现、下载后，连续轮播至少 10 分钟，
  并在轮播过程中交替按 KEY1/KEY2 验证。

## 滑动转场边缘修复（2026-08-26，待上板验证）

- 症状：滑动动画结束后，图片左侧仍残留一小列未正常显示。
- 根因：`video_presentation.v` 的 `pixel_x` 在每行首个 `de` 周期仍保留上一行的
  终止坐标；转场遮罩将该周期误判为超出 `reveal_x`。同时行首将计数器置零会让
  x=0 重复一拍，并挤掉最后的 x=639。
- 修复：行首显示显式使用 `render_x=0`，并在该周期后将计数器置为 1，使每行
  严格覆盖 x=0..639；字幕和状态条也改用同一显示坐标，避免各图层再发生列偏移。

## TD Critical Warning 处理记录（2026-08-26）

- 已移除工程文件 `prj/SD_to_Video.al` 中 3 个未使用且标记为 AutoExcluded 的旧
  IPC 引用：`AUDIO_SAMPLE_ROM.ipc`、`PLL.ipc`、`PLL_HDMI_AUDIO.ipc`。其中
  `AUDIO_SAMPLE_ROM.ipc` 仍指向不存在的旧初始化文件，触发
  `PRJ-7002 Load IPC file . error`；当前顶层仅使用 `sys_pll.ipc`、`video_pll.ipc`
  和两组异步 FIFO IPC，移除旧引用不会改变现有 HDMI/SDRAM/TF/UART 功能。
- `PHY-7002 U3/sdram location (12,12) is not honored` 与
  `PHY-5079 ... SDRAM_CLK ... local routing` 来自厂商加密 `sdr_as_ram` /
  `EG_PHY_SDRAM_2M_32` SDRAM 核内部物理实现，不存在于 `prj/pin.adc` 的用户
  约束。当前最终布线时序通过（Setup WNS `2.937 ns`、Hold WNS `0.025 ns`）。
  不得通过修改/替换加密 SDRAM 核、伪造位置约束或添加宽泛 timing exception 来
  “消除”这两项，否则会危及已验证的 SDRAM 功能；若必须清零，只能采用与 TD 6.2
  和 EG4S20BG256 匹配的厂商新版 SDRAM reference design 后重新完整上板验证。

## XCOM UART 验证

1. 接板上唯一 USB-UART Type-C 口，确认 CH340 COM 号。
2. XCOM 设置：115200、8 data bits、1 stop bit、None parity、None flow control。
3. **关闭本地回显（Local Echo）**，否则窗口里的字符无法证明 FPGA 回传。
4. 每次只发送一个字符，取消自动附加 CR/LF，发送后等待约 1 秒。
5. 先发送 `B`：接收区出现 `B`，且亮度状态条增加一格，说明收发链路完整成功。
6. 再逐一测试 `b`、`V`、`v`、`N`、`A`、`1`~`4`；每个字节间隔约 1 秒。

## 工作注意事项

- 不要为了调 UART 改动 SD 卡、SDRAM、HDMI PLL 或按键架构。
- KEY1/KEY2 是低有效输入，约束必须保留 `PULLTYPE = PULLUP`，否则松开时可能悬空，导致按键无响应或误触发。
- 不要为用户运行 TD 编译/bitgen；由用户手动执行，日志始终放在 `prj/log/`。
- 不要通过编辑 `*_Runs` 目录中的脚本/设置来固化项目逻辑；这些是 TD 自动生成的临时文件。
- 命令行 TD 在此环境中曾出现脚本路径转义异常；优先使用 TD GUI 运行流程。
- 完成有意义修改后，推送前用 `git status` 检查，仅提交源码、工程配置和必要资源。
