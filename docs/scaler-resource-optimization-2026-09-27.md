# 双线性缩放器位宽优化（2026-09-27）

## 修改

保留 1920×1080 的最大源图、640×480 板级输出、原有双线性插值、3 个显式 DSP、两个 2048 深度行缓存及状态流程，不改顶层、IP、时钟或约束。

- 源宽高、填充列、已填充行、目标源行按 `MAX_WIDTH/MAX_HEIGHT` 推导位宽；当前配置为 11 位。尺寸位宽包括最大尺寸本身及行结束后的行计数。
- 横纵定点坐标、步进分别使用源尺寸位宽加 16 个小数位；当前配置为 27 位。
- 相位、步进余数及输出计数按输出尺寸推导；当前横向 10 位，纵向 9 位。相位加法保留额外进位。
- 共享除法器的除数和余数收窄为 10 位和 11 位；保留原来的 32 拍除法，商、被除数仍为 32 位。
- 水平单项及累计结果保留 16 位，因最大值为 `255*256=65280`；垂直单项及累计结果保留 24 位，最大为 `255*65536=16711680`。加舍入常量 32768 后仍小于 2^24。
- DSP 原语及其 18 位注册操作数保持原配置，使用明确零扩展和乘积截取。
- 11 位行缓存地址从参数化计数/坐标零扩展，避免参数变小时出现越界位选择。

## 回归

新增 `tb_bmp_scaler_resource_opt` 使用独立的 64 位定点坐标公式和互补插值权重，逐像素检查 RGB、坐标和行/帧标志，并覆盖源数据间隙、输出反压、加载中止及不复位重启。

- 1920×1080、1919×1079、1×1080、1920×1、2×2、17×13、1×1 → 19×14，包括变化颜色、黑白交替、全白极值。
- 17×13、1×1 及中止后重启 → 640×480，共三个完整输出帧，每帧 307,200 像素。
- 修改最大尺寸参数为 1024×512，验证位宽推导及最大尺寸为二次幂时的边界。
- 原有 2×2→4×4、640×480 等尺寸逐像素回归通过。
- 修改前版本源码快照也运行同一参考模型，用于核对算术结果。
- `BMP -> source FIFO -> scaler -> frame_commit` 集成回归通过；使用厂商真实源 FIFO 仿真模型，行缓存使用既有注册输出行为模型。

旧集成测试的 SD 模型只在 LBA0 提供裸 BMP，无法通过当前 FAT32 目录扫描，故本轮将测试数据补为直接 FAT32 卷：BPB=0、FAT=1、根目录=2、BMP 文件=3。这不修改板级加载逻辑。

RTL 编译及独立缩放器仿真均为 0 errors、0 warnings。集成仿真为 0 errors、12 warnings，均为既有源 FIFO 包装器及上层实例未连接可选输出/异步端口的告警，不修改厂商生成文件。综合 HDL/SYN 告警与基线一致，无新增告警。

## 综合结果

基线为提交 `dd637e9` 的已验证综合结果，当前候选使用相同设置。

| 资源 | 优化前综合 | 优化后综合 | 减少 |
|---|---:|---:|---:|
| 全工程 LUT | 14,931 | 14,747 | 184 |
| 全工程 REG | 9,704 | 9,617 | 87 |
| 缩放器 LUT（含 ripple） | 1,487 | 1,323 | 164 |
| 缩放器 REG | 831 | 744 | 87 |
| BRAM9K（含 FIFO） | 40 | 40 | 0 |
| BRAM32K | 6 | 6 | 0 |
| DSP | 18 | 18 | 0 |

基线快照位于 `prj/log/scaler_opt_sim/baseline_gate.area`，候选报告位于 `prj/log/scaler_opt_synth/SD_to_Video_gate.area`。模块节省与全工程节省不同，表中分别列出。

## P&R

最终候选在 `prj/log/scaler_opt_phy` 中从已验证的综合数据库运行完整布局布线，不生成 bitstream。

默认 P&R 第一轮在 `x29y10_w2beg4` 出现另一组 `PHY-8023`：`u_audio_playback_control/u_key/rst` 与 `u_bmp_catalog/rst_dup_22_holdbuf`。它与已修复的目录器 FAT 独立 CE 问题不同，是本轮布局与 hold 修复后的复位网络布线冲突。

从失败的 `SD_to_Video_eco_pr.db` 继续执行 TD 官方提供的 `route -incremental`，允许调整已合法布线网络，随后完成 `report_route_status -drc`、最终资源和时序报告。续跑无 ERROR，布线检查没有再报告 `PHY-8023` 或 `RUN-8102`。没有关闭 hold 修复或修改任何约束。

| 资源 | 优化前成功 P&R | 优化后最终 P&R | 减少 |
|---|---:|---:|---:|
| LUT | 15,255 | 15,125 | 130 |
| REG | 9,801 | 9,702 | 99 |
| BRAM9K（含 FIFO） | 40 | 40 | 0 |
| BRAM32K | 6 | 6 | 0 |
| DSP | 18 | 18 | 0 |
| PLL | 2 | 2 | 0 |

最终 LUT 占用 77.17%，剩余 4475。最终 `SWNS=+0.115 ns、STNS=0`，`HWNS=+0.003 ns、HTNS=0`，普通 setup/hold 均通过；优化前为 `SWNS=-0.833 ns、STNS=-0.833 ns`，hold 同为 +0.003 ns。布局及重布线变化同时影响了其他模块，因此不能把时序改善全部归因于缩放器位宽。

当前最差 setup 路径为 WAV 读取器 `cluster_reg[5] -> cluster_offset_reg[26]`，位于 100 MHz 的 SD 域。SDRAM 初始位置警告和 `ext_mem_clk_sft` 使用局部布线的既有警告仍须结合专用 SDRAM 接口和实板验证判断，未通过更改约束隐藏它们。此结果只确认本次实现的普通时序检查通过，不代表实板彩线问题已解决。

初次失败日志：`prj/log/scaler_opt_phy.log`；续跑成功日志：`prj/log/scaler_opt_route_repair.log`；最终报告：`prj/log/scaler_opt_phy/repaired_phy.area`、`repaired_phy.ts`、`repaired_pr.timing`。

## GUI 遇到同类布线失败时

提供 `prj/scripts/recover_incremental_route.tcl`，默认读取 GUI `phy_1` 的失败 ECO 数据库并输出 `recovered_phy.area`、`recovered_phy.ts`、`recovered_pr.timing`、`recovered_pr.db`，不生成 bitstream。在 GUI 完成当前源码的 P&R 后，若仍出现同类错误，可在 TD Tcl 控制台执行：

```tcl
source {E:/AnLuTD_Project/SD_to_Video/prj/scripts/recover_incremental_route.tcl}
```

必须确认控制台没有 ERROR，并检查新生成的 `recovered_*` 报告；不能使用旧成功报告或仅凭进程退出码判定成功。脚本已从同一失败 ECO 数据库重放核验，日志 `prj/log/scaler_opt_recovery_verify.log` 为 0 ERROR，资源及 setup/hold 与第一次续跑一致。重放后的最终报告为 `prj/log/scaler_opt_phy/recovered_phy.area`、`recovered_phy.ts`、`recovered_pr.timing`。
