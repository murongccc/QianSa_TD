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
