# 目录器 FAT 采集布线修复（2026-09-27）

## 故障证据

用户重新执行完整 P&R 后，仍在 `x7y10_local4` 报告 `PHY-8023`，网络为目录器的 `mux47_syn_86` 和 `mux48_syn_86`，随后 `route -eco` 失败并报告 `RUN-8102`。

使用 TD `import_db` 读取失败数据库，通过 `report_nets -connection` 查明：前者连接 `fat_b0` 的寄存器 CE，后者连接 `fat_b1` 的寄存器 CE，两条网络在 x7y10 均有负载。故障涉及 FAT 字节采集控制布线，不是根据生成的 mux 名称推测的候选缓存读选择器。

诊断日志：`prj/log/inspect_route_failure.log`；原失败日志快照：`prj/log/catalog_route_failure_baseline.log`。

## 修复

`fat32_bmp_catalog.v` 原来分别比较 FAT 项的四个字节位置，为四组字节寄存器生成独立写使能。现在改为 32 位 `fat_entry_shift`，在四个有效字节到来时依次执行 `{sd_sec_read_data, fat_entry_shift[31:8]}`。

FAT 项偏移由 `{dir_cluster[6:0],2'b00}` 生成，始终四字节对齐，因此用 `pos[9:2] == {1'b0,fat_offset[8:2]}` 识别四字节区间。四次移位完成后得到相同的小端 32 位 FAT 项，仍屏蔽高四位再判断下一簇、EOC 或非法簇。四字节共享一条写使能，消除原来的独立 CE 组合。

不改变状态机、目录候选顺序、候选握手、管脚、时钟、约束或厂商 IP。保留 BMP 读取器上一轮位宽优化及 1920×1080 上限。

## 仿真

ModelSim 编译和以下仿真均为 0 errors、0 warnings：

- 新增 `tb_bmp_catalog_fat_capture`：偏移 0、8、508，字节间两拍空隙，非目标字节不采集，小端顺序、高四位屏蔽，合法下一簇、EOC 和无效簇分支。
- `tb_fat32_bmp_catalog`：MBR/直接 FAT32 卷、根目录跨 FAT 簇链及候选释放。
- `tb_fat32_bmp_catalog_five`：五个候选按物理目录顺序输出。

日志位于 `prj/log/catalog_route_fix_*.log`。

## 实现验证

在独立目录 `prj/log/catalog_route_fix` 中，从 `read_design` 运行到 `opt_route`，执行完整综合、布局和布线，保留当前 `pin.adc` 与 `timing.sdc`，不执行 bitgen。

TD 进程退出码为 0，日志无 ERROR，`route` 正常完成，并生成最终 `SD_to_Video_phy.area`、`SD_to_Video_phy.ts` 和 `SD_to_Video_pr.timing`。没有再次出现 `PHY-8023`、`RUN-8102`。HDL/SYN 告警与修复前一致。SDRAM 初始位置的 `PHY-7002` 仍出现，但本次运行最终布线成功，故未删除约束或改动硬宏来隐藏此警告。

| 资源 | 用户上一份成功 P&R（BMP 优化之前） | 本次最终 P&R | 减少 |
|---|---:|---:|---:|
| LUT | 15,386 | 15,255 | 131 |
| REG | 9,856 | 9,801 | 55 |
| BRAM9K（含 FIFO） | 40 | 40 | 0 |
| BRAM32K | 6 | 6 | 0 |
| DSP | 18 | 18 | 0 |
| PLL | 2 | 2 | 0 |

这组差值包含 BMP 位宽优化、目录器修复以及最终物理映射变化，不能单独归因于本次 FAT 采集修改。LUT 占用为 77.83%，剩余 4345。

本次综合为 14,931 LUT、9,704 REG；修复前候选综合为 14,969 LUT、9,700 REG，减少 38 LUT，增加 4 REG。增加的存储位用于连续四次移位中的完整字节保留，最终簇号仍只使用低 28 位。

## 剩余时序问题

最终 `SWNS=-0.833 ns、STNS=-0.833 ns`，`HWNS=+0.003 ns、HTNS=0`。hold 已通过，仍有一条视频域 setup 违例：

`u_video_presentation/faded_rgb[22]_syn_4 -> u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/U_audio_sample_packet_2_channel/S_packet_body[55]_syn_50`

本轮目标是解决重复的布线错误，未扩大范围修改视频/HDMI 路径。布线成功不等于时序全部闭合，也不代表实板彩线问题已经解决。未生成 bitstream，未执行实板验证。
