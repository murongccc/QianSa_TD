# BMP 读取器位宽优化（2026-09-27）

## 修改范围

保留合法源图最大尺寸 1920×1080 和 24 位 BI_RGB 格式限制。

- `row_byte_cnt`、`row_stride` 从 32 位收窄为 13 位：最大对齐行跨度为 5760 字节。
- `src_col`、`src_row` 从 16 位收窄为 11 位，覆盖最大列、行及行结束后的递增值。
- 像素阶段从校验后锁存的 `parsed_width`、`parsed_height` 获取 11 位尺寸，使用明确位宽的行字节运算和共享的行尾、帧尾判断。
- 原始图头宽高仍为 32 位，保留超限、零尺寸及负高度校验。文件长度、像素偏移、字节位置、FAT 簇链和扇区地址仍为 32 位。
- 不修改缩放器、IP、顶层、时钟或管脚；不生成 bitstream。

## 验证

ModelSim 编译为 0 errors、0 warnings；以下三项仿真均通过：

1. `tb_bmp_read_resource_opt`：完整 1920×1080 的 2,073,600 像素逐一检查 RGB、行尾和帧尾；1919 宽行、负高度 1×1080，以及宽度 1～4 的 0～3 字节行填充；超限、零尺寸及高位非零图头拒绝；最后一个像素不完整时仍报告加载失败。
2. `tb_bmp_read_fat_chain`：碎片 FAT32 文件跨簇读取。
3. `tb_bmp_read_v5_header`：800×60 的 BITMAPV5 图头和跨多个 64 扇区簇读取（旧测试的 PASS 文本仍写作 800×600）。

仿真日志位于 `prj/log/bmp_opt_tb_*.log`。

## 综合资源对比

使用相同的隔离综合配置分别构建修改前源码快照和最终源码，只执行至 `opt_gate`。LUT 统计包含 `lut + ripple`。

| 资源 | 修改前综合 | 修改后综合 | 减少 |
|---|---:|---:|---:|
| 全工程 LUT | 14,980 | 14,969 | 11 |
| 全工程 REG | 9,748 | 9,700 | 48 |
| BRAM9K（含 FIFO） | 40 | 40 | 0 |
| BRAM32K | 6 | 6 | 0 |
| DSP | 18 | 18 | 0 |
| BMP 读取器 LUT | 1,572 | 1,462 | 110 |
| BMP 读取器 REG | 772 | 724 | 48 |

BMP 模块自身减少 110 LUT；全工程其他逻辑的综合映射合计增加 99 LUT，因此净收益为 11 LUT。不能将模块节省直接当作全工程节省。

基线报告：`prj/log/bmp_opt_synth/baseline_gate.area`；候选报告：同目录 `SD_to_Video_gate.area`。综合告警与基线一致，无新增告警。

## 时序与交付限制

综合估计的 setup 从 `SWNS=-1.660 ns、STNS=-19.750 ns` 变为 `SWNS=-3.666 ns、STNS=-7.556 ns`；最差单路径变差，总负裕量减小。候选 hold 为 `HWNS=+0.471 ns、HTNS=0`。这些均为布局布线前估计，不代表最终板级时序。

候选最差 setup 路径为视频域 `video_delay_m0/de_d_reg[20] -> u_video_presentation/spectrum_stage_reg`；SD 域最差 setup 为 `-0.482 ns`，路径为 `u_sd_arbiter/state_reg[1] -> u_bmp_catalog/dir_end_pending_reg`。本轮不扩大范围修改这些路径。

本轮未运行 P&R。用户此前确认的 15,386 LUT、9,856 REG 是修改前 P&R 结果，不能与上述综合数字直接比较。最终资源收益及 setup/hold 必须通过候选版本 P&R 确认。现有用户修改保留，不覆盖 `current-state.md`。
