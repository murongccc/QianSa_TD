# 同一网表的 HFN 策略对照

日期：2026-10-15。结论：本次仅将 `place.hfn_opt_effort` 从 medium 改为 off，**没有降低 MSlice，未解决超限**。没有修改生产 RTL、时钟、约束或主工程设置，没有生成 bitstream。

## 固定输入

使用当日 20:07:14 GUI 失败运行导入的 `prj/SD_to_Video_Runs/syn_1/SD_to_Video_gate.db`，先复制到独立审计目录冻结，再供两次物理运行共同导入。没有重新综合，也没有执行 RTL 分析。

冻结数据库 SHA256：

```text
b1f3fd4fdeef85f1768ff5a7918f966fc0b597891333e651ed3c72a7510f2a98
```

原失败日志、工程、流程脚本、settings、综合资源/时序报告均已归档。两次运行的工程文件逐字比较，仅 `<hfn_opt_effort>` 为 medium/off 不同；settings 完全一致，保留原 `-packarea`、post_place_opt medium 和其他物理参数。共同将导入路径指向冻结数据库，并将流程终点设为 opt_route，禁止进入 bitgen。起点保持 opt_place。

两次均从同一个综合数据库重新开始物理实现，未读取先前失败的布局或路由数据库。226 个现有 RTL、IP、工程与约束文件运行前后哈希一致；原 GUI 失败日志与原综合数据库也未变化。逐文件哈希清单位于审计目录的 input_manifest.json。

## 实测结果

| 指标 | HFN medium 对照 | HFN off 候选 |
|---|---:|---:|
| 参数表 hfn_opt_effort | medium | off |
| 打包前 HFN 阶段报告的 effort | medium | medium |
| 处理的寄存器驱动 | 21 | 21 |
| 复制的寄存器 | 302 | 302 |
| 最终打包 MSlice | **5005** | **5005** |
| 最终打包 LSlice | 5004 | 5004 |
| MSlice 上限 | 4900 | 4900 |
| MSlice 超出数量 | **105** | **105** |
| 剩余单独 LUT / SEQ | 1502 / 186 | 1502 / 186 |
| 物理流程结果 | PHY-9009，打包超限 | PHY-9009，打包超限 |

medium 对照精确复现了用户 GUI 的 5005/5004 打包结果。因此，本轮 off 与 medium 的资源比较确实基于同一网表，不能与此前其他网表的 HFN off 试验混用。

**重要限定：off 参数被成功接收，但不等于当前全部高扇出复制均已停用。** off 日志明确包含 `set_param place hfn_opt_effort off`，参数表也显示 off；后续 pre-pack 阶段却仍报告 `medium effort`，并仍复制 302 个寄存器。现有证据不足以断言这是参数作用阶段的限制、内部策略覆盖还是工具其他机制。只读查询了 TD 6.2 的 place/set_param/report_param 命令帮助，未得到解释这一内部阶段行为的说明；没有猜测或追加未经确认的参数。

两次都在打包阶段失败，没有完成布局/布线，没有最终 Routed 时序报告；不能将日志中的中间估计当作 setup/hold 通过。关闭参数在本轮的实际 MSlice 收益为 **0**，不能宣传为节省了 302 个寄存器或相同数量的切片。

## 工程处置与范围

没有把 off 写回 `prj/SD_to_Video.al` 或原 GUI 运行目录。功能逻辑沿用原综合网表，未改图片预装、双线性缩放、FFT、音游、音频、触摸或诊断功能；由于容量仍不满足，本轮不构成上板验证。

本项对照已经结束，未继续修改复位、使能、地址 ALU、流水线或时钟。若继续优化，下一步应单独检查内部数据通路复位/使能的打包成本，或在获得明确 TD 参数依据后再验证其他高扇出控制方式，不能重复把同一个 off 开关作为已证明有效的修复。

## 材料与复现

- 审计输入与哈希：`prj/log/mslice_hfn_same_netlist_20261015/`。
- medium 独立运行：`prj/log/mslice_hfn_medium_20261015/console.log`。
- off 独立运行：`prj/log/mslice_hfn_off_20261015/console.log`。
- 机器可读结果：[mslice-hfn-same-netlist-2026-10-15.json](reports/mslice-hfn-same-netlist-2026-10-15.json)。
- 对照工具：`src/test/run_hfn_same_netlist.py`。它冻结 GUI gate.db，检查工程的唯一策略差异，按顺序运行 medium/off，记录复制与打包结果，并校验 RTL/约束哈希。已有目录存在时拒绝覆盖，防止破坏本次证据；重放前应使用新的 TAG 和独立目录。

本次没有 RTL 改动，因此未重新执行功能仿真；验证依据是完全相同的输入综合网表、相同约束、明确的单参数差异、medium 失败结果复现及全部输入哈希核对。两次预期的 PHY-9009 均作为失败结果记录，没有被当作构建通过。
