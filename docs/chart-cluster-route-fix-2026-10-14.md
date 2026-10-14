# 谱面簇选择链的局部布线修复（2026-10-14）

## 失败证据

GUI 的 PHY-8023 指向 `x33y8_local5`，冲突网络为
`sd_media_pipeline_m0/rhythm_resources$resources/u_chart/mux198_syn_69`
和 `sd_media_pipeline_m0/u_bmp_catalog/volume_root_cluster[7]`。
原布局物理优化后占用 4863/4900 MSlice。

既有 `game_background_hfn_off_phy_20261014/console.log` 已确认
`hfn_opt_effort=off`，仍报相同冲突。因此关闭布局 HFN 优化不能单独解决本次失败。
冲突是物理路由资源争用，不能仅由网络名推断 FAT32 功能错误。

## 修改范围

- `fat32_chart_reader.v`：将 `cluster` 的卷入口、目录项、FAT 下一簇三个互斥来源，
  从主状态机的优先赋值拆为共享写使能和并行掩码选择。取消和保持条件不变，
  保留卷入口 32 位数据及目录/FAT 的 28 位掩码，不增加流水拍。
- 主工程恢复原有 `hfn_opt_effort=off`，保留 `post_place_opt=medium`。
  主 `.al` 存在用户其他未提交改动，不把整份工程文件纳入本次提交。
- 增加 `run_chart_route_equivalence.py`，默认以 `9e3ad50` 的读取器为对照。

不修改顶层、IP、管脚、时钟、SD 协议或双线性缩放功能。

## 验证

`route_cluster_regression_20261014/`：第二阶段全部可用回归通过，覆盖卷校验、
碎片谱面、共享媒体、取消、WAV、SPI 延迟、实际卡启动数据。
独立 413-note 真实谱面文件缺失，该用例由原回归脚本明确跳过。

`chart_route_equivalence_20261014/equivalence.log`：162460 个周期比较全部谱面输出、
簇寄存器和状态。碎片 FAT 高位、精确扇区边界、取消和重启均通过。

独立综合 `route_cluster_syn_20261014/`：LUT 18180、REG 10575，
对比 `game_background_syn_20261014/` 的 LUT 18192，减少 12 LUT，寄存器数不变。

独立物理验证 `route_cluster_phy_20261014/` 使用新综合网表，从 `opt_place` 到
`opt_route`，实际日志确认 HFN off；布局后 4818/4900 MSlice，余 82，
比原失败布局少 45。流程不生成 bitstream。

最终正常布局布线成功，退出码 0，`.opt_route.end.f`、路由数据库和最终时序报告
均已生成；Routing DRC 完成且没有 PHY-8023 或 RUN-8102 错误。
没有调用额外增量恢复流程，没有生成 bitstream。

路由后 LUT 18278/19600、REG 10696、BRAM9K/FIFO9K 57/64、BRAM32K 11/16、DSP 21/29。
最终 `SD_to_Video_phy.ts` 为 Setup WNS -0.234 ns、TNS -0.622 ns，
Hold WNS -0.054 ns、TNS -0.137 ns。Setup 违例位于 25 MHz 视频域，
该域报告 Fmax 24.855 MHz；50 MHz SD 域 Setup +1.808 ns，100 MHz SDRAM 域 +0.113 ns。
因此本轮完成的是布线冲突修复，不能宣称时序闭合或实板稳定性已经验证。
首条最差 Setup 路径为频谱环 `base_radius_sq_stage[0]` 到 `narrow_center_stage_reg`，
19 级逻辑，数据延迟 39.882 ns（布线 24.819 ns）。保留的 PHY-5079 告警为
`ext_mem_clk_sft` 到 SDRAM 时钟输出的单扇出局部线，不是本次网络冲突。

后续在 TD GUI 重新加载磁盘工程，确认物理策略 HFN off、post_place_opt medium，
然后从综合开始重新运行，不能继续使用旧失败布局进行增量布线。
若 GUI 已打开旧工程，避免先保存旧内存配置覆盖磁盘的 off 设置。
