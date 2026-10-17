# SD_to_Video 当前状态
### 最近验证与仍待处理的问题

## 当前稳定配置

- SDRAM 固定运行在 `ext_mem_clk=100 MHz/0°` 与 `ext_mem_clk_sft=100 MHz/180°`；两路必须同频并保持 180°相差
- `sdr_as_ram` 保持 `self_refresh_open=1'b0`；刷新待确认期间阻止新的帧读/写 burst，已启动 burst 正常完成后让出控制器。
- 刷新数码管页的有效范围为不超过 `0x09C4` 且第五位不显示 `E`；正常实板值为 `0x08D3`。
- 当前诊断页每 2 秒轮换：`B` 为读 FIFO 空读，`D` 为最终原始 RGB 帧签名变化，`F` 为帧读 FIFO 输出签名变化，`C` 为 SDRAM 返回口帧签名变化，`A` 为 HDMI AXIS 反压。`C` 的帧起点已改为 `read_req_ack` 上升沿，避免多周期 ack 重复清零签名。

## 当前暂停的问题：偶发彩色横线与 100 MHz SD 域时序未闭合

> 本节保留 2026-09-23 的问题记录及当时排查方向。

### 已验证的现象与结论

- 实板在关闭自动轮播和音乐后，图片稳定显示约 2–3 秒仍可能出现一两帧彩色或白色横线；位置常在上半部或中下部。少数情况下出现位置近似固定、延伸到左右边缘之外的横线。
- 问题出现时 `B=0000`、`A=0000`，刷新页没有 `E`，`D/F` 多数只增加到 `2`–`6` 后停止。它排除了读 FIFO 空读和 HDMI AXIS 反压作为主要原因。
- 实板原始 RGB 旁路后仍会出现彩线；固定灰画面、高翻转黑白棋盘格和内部八色逐像素序列均未出现彩线。HDMI 物理输出链本身和单纯的数据翻转不是首要嫌疑，实际帧读数据链仍是重点。
- 将帧读异步 FIFO 改为 RAM 输出寄存器，并把视频读请求提前一拍后，彩线出现概率明显下降，但没有完全消失。
- `C/F/D` 同时变化时伴随彩线，证明变化已经跨过 SDRAM 返回口、帧读 FIFO 和最终原始 RGB。`C` 持续变化而 `F/D` 稳定时不能单独判定 SDRAM 数据已损坏，因为 `C` 按预取事务计数，`F/D` 按实际显示帧计数，两者边界不同。
- 目录扫描路径的旧违例已经通过 `e6a2cb5` 结构切分移出最差路径。当时前三条违例为缩放器两条：`sh_reg -> state_reg` 为 `-0.208 ns`，`sh_reg -> linebuf_read_addr` 为 `-0.077 ns`；音频读取器 `file_pos -> chunk_header_pos` 为 `-0.017 ns`。
- `f81e5c4` 已让缩放器每个源行结束后统一进入既有的 `ST_CHECK/ST_CHECK_ROWS` 两拍检查，切断上述 `sh -> sy1 -> 状态/行缓存地址` 组合链。ModelSim 已通过 2×2→4×4 的像素、标志和反压回归，以及 640×480 的 307,200 像素逐一比较。

### 仍待验证的原因和后续动作
- 若所有普通时序闭合、连续上电/复位后仍出现彩线，再继续验证 SDRAM 硬宏的 DQ 读采样、读 burst 边界和刷新竞争。现有 `C/F/D` 只能定位到数据链，不足以单独证明 DQ 相位或刷新是根因。

## 已完成的主要功能

- FAT32 根目录先一次性扫描并缓存按物理目录项顺序发现的前 5 个 BMP 描述符，再逐项交给读取器；支持 MBR 分区和 LBA0 直接 FAT32。BMP/WAV 均可定位到对应卷起点，BMP 文件按 FAT 簇链读取；碎片文件、坏图头或截断图片会跳过并继续查找。
- BMP0–4 预装至 SDRAM 五个独立槽。目录器已释放全部候选且没有在途加载时，才在视频帧边界显示首帧并启动音频；因此不会将后续图片降为受音频仲裁影响的后台加载。图片不足五张时循环已成功预装的图片，切图不再访问 SD 卡。
- `bmp_bilinear_scaler` 已修复奇偶行缓存推进问题，并支持失败中止恢复；BMP、缩放器和 SDRAM 写完成事件通过保持型提交状态汇合。
- SD 与音频仲裁、FAT32/WAV 地址计算、媒体加载失败恢复均已实现；音频 FIFO 低于 1024 个立体声采样帧时优先服务音频。
- 数码管阶段码：`A`=源 FIFO/扇区节流，`B`=缩放器排空，`C`=等待 SDRAM 写完成；目录扫描完成且空闲时显示已提交图片数 `1`–`5`。若目录交出的候选数多于已提交数，显示 `D`，用于区分后续加载/提交失败和目录仅找到一张的情况。


## Git 与工作区

- 已提交：`eaa2cdf Fix scaler row progression and media handshakes`。
- 已提交：`9de54f4 Add synchronized resets and real timing constraints`。
- 已提交：`299bf3d Cache FAT32 BMP candidates before loading`。
- 已提交：`72074ce Wait for all BMP preload before first display`。
- 已提交：`e6dc853 Optimize scaler and spectrum resources`。
- 已提交：`e6a2cb5 Pipeline BMP catalog boot-sector validation`。
- 已提交：`f81e5c4 Shorten scaler row-end timing path`。
- 已提交：`08b8c9e Add centered FFT ring spectrum`。
- 已提交：`f3e525e Render spectrum bars with circular edges`。
- 已提交：`fb7dd30 Boost and smooth FFT spectrum response`。
- 已提交：`2c9f3ba Window FFT samples and aggregate spectrum bands`。
- 已提交：`19e9207 Interpolate 32 FFT bands into 64 radial bars`。
- 已提交：`bafb593 Reduce spectrum gain and stop frequency seam interpolation`。
- 已提交：`b50088f` WAV FIFO 占用计数资源优化。
- 已提交：`9281d69` BMP 读取器位宽资源优化。
- 已提交：`dd637e9` 目录器 FAT 采集共享使能及布线修复。
- 已提交：`10946a4` 双线性缩放器位宽资源优化及回归。
- 已回退：`79e6948` 自动 P&R 恢复工作流，由 `43bf09d` 撤回；默认流程修复不能以额外续跑成功作为依据。
- 已提交：`25641c4` BMP 内部完成标志复位布线修复，默认 P&R 完成但 setup 时序未闭合。
- 工作区含既有未提交改动；不得覆盖或清理无关文件。
