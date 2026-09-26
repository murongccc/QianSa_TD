# WAV FIFO 资源优化（2026-09-26）

## 最终改动

- `fat32_wav_reader` 的 FIFO 占用计数按 `FIFO_SAFE_LEVEL + 128` 推导位宽；默认水位 3968、每扇区最多 128 个立体声帧，内部使用 13 位，可表示 4096。
- 外部 `audio_fifo_level` 保留 32 位无符号零扩展接口。
- 加一、减一共用一个加法器；空读不下溢，同时读写保持占用不变。FIFO 容量、水位、PCM 输出节奏和跨域读事件同步保持原设计。
- 簇地址乘法保留原实现。本轮验证过组合移位和逐拍移位，均未产生全工程 LUT 净收益，因此未保留；非法簇大小行为也保持原实现。

## 综合结果

TD 6.2.168116、EG4S20BG256，使用独立目录 `prj/log/wav_opt_synth/`，仅运行 read_design 到 opt_gate。原始 WAV 源码用相同脚本重新综合，结果与 2026-09-26 13:20 的原综合报告一致。

| 资源 | 原始基线 | 最终候选 | 差值 |
| --- | ---: | ---: | ---: |
| 全工程 LUT 利用量 | 15093 | 14980 | -113 |
| 全工程寄存器 | 9767 | 9748 | -19 |
| BRAM9K（含 FIFO） | 40 | 40 | 0 |
| BRAM32K | 6 | 6 | 0 |
| DSP | 18 | 18 | 0 |
| WAV 模块 LUT+ripple | 1553 | 1498 | -55 |
| WAV 模块 seq | 1146 | 1127 | -19 |

全工程差值包含重新映射和打包的变化，不能把全部 113 个 LUT 都归为 WAV 模块的直接减少。

对照试验：组合移位方案为 15225 LUT / 9748 寄存器 / 16 DSP；逐拍移位方案为 15127 LUT / 9752 寄存器 / 16 DSP；仅收窄计数、保留独立加减表达式为 15118 LUT / 9748 寄存器 / 18 DSP。最终采用收窄计数并明确共享加法器的方案。

报告：`prj/log/wav_opt_synth/fresh_baseline_gate.area`、`prj/log/wav_opt_synth/SD_to_Video_gate.area`。日志：`prj/log/wav_opt_fresh_baseline.log`、`prj/log/wav_opt_synth.log`。最终综合无新增告警（与原综合告警逐行比较）。

## 验证及限制

- ModelSim 编译：0 错误、0 告警。
- `tb_fat32_wav_reader`：标准 WAV 读取及 PCM 字节序通过。
- `tb_fat32_wav_reader_direct_volume`：LBA0 直接 FAT32 卷通过。
- 新增 `tb_wav_reader_resource_opt`：全部八种合法簇大小的地址运算保持不变；0～4096 写入/排空、水位 3968、空读、同时读写通过。
- 未修改顶层、约束、厂商 IP；未运行 P&R、未生成 bitstream。
- 最终综合阶段 setup WNS=-1.660 ns、TNS=-19.750 ns；hold WNS=+0.471 ns、TNS=0。这是布局布线前估算，不能作为最终时序闭合结论。
- 14980/19600（76.43%）是综合利用量，不能与旧 P&R 的 15428 直接相减；最终占用和时序需重新 P&R。偶发彩线仍待原有板级排查。
- 工作区已有的 `current-state.md`、工程配置及 PLL 改动未纳入本次提交。
