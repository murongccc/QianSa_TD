# 三指版本 GUI 布线失败诊断（2026-10-13 21:27）

> 后续用户要求已删除触摸十字。最新无十字候选及综合结果见 [删除十字说明](three-touch-no-cross-2026-10-13.md)，本文保留当时结果。

## 已确认的失败与资源

用户运行 `724df0d` 三指版本后，`prj/SD_to_Video_Runs/phy_1/run.log` 报告：

- `PHY-8023`：`x2y36_n2beg4` 上 `u_game_renderer/difference[15]` 与 `u_game_renderer/time_snapshot[30]` 路由资源冲突。
- `RUN-8102`：内部 `route -eco` 结束后仍存在冲突，物理流程失败。
- Place Packing（run.log:338）：4895 MSlice、4894 LSlice，器件各容量4900；MSlice余5。
- 布局资源报告：LUT18479/19600、REG10830，BRAM9K/FIFO9K57、BRAM32K11、DSP22。
- 用户此次综合仍为LUT18379、REG10685，与本轮独立综合相同。

相对旧已通过物理版本4796 MSlice，此次打包增加99，余量从104变为5。这一差值包含其后紧凑频谱、触摸操作区、三指改动和本次物理策略；不能全部归因于三指。Place Packing没有报告超容量，错误的直接证据是单个路由资源冲突。接近满载很可能加大布线压力，但日志不足以把它认定为唯一根因。

冲突网络位于既有renderer的时间差计算。仅凭网络名不能认定该RTL存在算术/多驱动错误；没有针对它修改位宽、Hold算法或时序约束。

日志最后一次时序估计为Setup +0.581/0ns、Hold -0.012/-0.050ns，但最终路由DRC失败，不能据此宣布时序通过或生成位流。失败标志`.opt_route.error.f`存在；无本次成功完成证明。

## 确认的策略回退与本次修复

本次失败日志第51行明确为 `hfn_opt_effort | medium | medium`。主 `.al` 和运行生成的 `.prj` 都只有 `post_place_opt=medium`，缺失先前要求保留的 `hfn_opt_effort=off`。

本次已局部补回主工程 `.al` 中的off，保留用户post_place_opt及所有其他工程内容。没有改写生成的 `.prj`、settings、IP或RTL。HEAD本来已有off，所以不把用户整份未提交工程文件加入commit。

上一轮磁盘曾补回off，但此次GUI实际运行又回到medium。可能是仍打开的GUI工程状态保存覆盖了磁盘设置，也可能是用户设置变更；只能确认实际参数回退，不能从日志证明具体操作过程。

该配置问题确实需要纠正，但尚未证明off能单独消除此冲突。本次没有重跑综合、布局或布线，没有生成bitstream，也没有改动用户选择暂不处理的极小Hold问题。

失败现场已复制到 `prj/log/three_touch_route_failure_20261013/`：failed_route.log、placed.area、failed_physical.prj、failed_settings.cfg。它们不会被下一次GUI运行覆盖。

## 后续一次验证的条件

不要先让仍含旧状态的TD窗口保存工程。重新载入磁盘工程，或在GUI的物理策略中明确设置HFN优化off，同时保持post_place_opt=medium。最终以新运行日志的参数表为准，必须看到 `hfn_opt_effort | off`，仅看磁盘XML不够。

此次run从新的syn_1 gate.db开始执行opt_place，然后由正常route进入内部ECO。因此“Incremental route failed”不表示用户一定选择了增量布局，也不构成删除工程、清理全部缓存或恢复旧源码的理由。

若由用户安排下一次唯一完整物理验证，可使用已有独立构建器显式指定参数、避免GUI内存策略覆盖：

```powershell
python src/test/run_resource_build.py three_touch_hfn_off_phy_20261013 --route --parent three_touch_syn_20261013 --hfn-off
```

该命令使用上一轮已验证的三指综合网表，不重新综合、不生成bitstream；本次只提供可审查命令，没有执行。若后续改动RTL，必须换用新的匹配综合网表，不能继续引用这个parent。主GUI失败settings的end_step为bitgen，故不得直接执行其完整流程作为本轮的无位流验证。

下一次若仍失败，先检查新打包余量和冲突位置，不循环尝试布局种子。前文 `three-touch-implementation-2026-10-13.md` 已给出减少三个坐标暂存宽反馈选择器的具体RTL候选，可在单独审查、回归及集中综合后验证。现有 `recover_incremental_route.tcl` 能尝试释放更多已路由网络，但继续使用当前失败布局不会改变其medium策略产生的打包结果；本次没有执行它，也不把它当作已解决问题的证据。
