# 游戏背景版本路由冲突与一次恢复记录（2026-10-14）

## 用户GUI失败

当前源代码HEAD为 `9e3ad50`。用户GUI在2026-10-14 19:54的物理运行报PHY-8023：

```text
Location: x33y8_local5
sd_media_pipeline_m0/rhythm_resources$resources/u_chart/mux198_syn_69
sd_media_pipeline_m0/u_bmp_catalog/volume_root_cluster[7]
```

最初打包4864 MSlice，后续物理优化为4863/4900，余37；布局LUT18322/19600、REG10741，DSP21。日志没有报告MSlice超限，直接失败原因是这两个网络争用同一局部路由资源。不能凭网络名认定谱面或BMP目录RTL有错误。

运行日志第51行明确HFN设置为medium。当前GUI生成的 `.prj` 和主 `.al` 均缺少off项。因此这仍不是当前版本在HFN off策略下的物理验证。配置丢失可能来自GUI内存保存覆盖等操作，但具体过程没有证据；仅确认实际策略回退。

失败流程中Setup估计+1.753/0ns、Hold -0.025/-0.085ns；由于DRC失败，这些不是通过的最终时序结果。

## 用户授权的一次定向恢复

用户明确同意：允许一次 `route -incremental` 恢复，不综合、不重新布局、不生成bitstream。

已先把失败的13,312,070字节ECO数据库、运行工程、原路由日志、资源和settings复制到独立目录 `prj/log/game_background_route_recovery_20261014/`；输入SHA256保存在 `recovery_started.json`。原GUI目录未被覆盖。

调用既有 `prj/scripts/recover_incremental_route.tcl`，仅调整失败布局中的路由。该操作沿用已打包的medium布局，不能把它描述为HFN off重新布局。

**结果：失败。** `route -incremental` 执行35.394秒后，最终仍有同一个x33y8_local5冲突、同一对网络。退出码1，没有生成recovered_phy.area、recovered_phy.ts、recovered_pr.timing或recovered_pr.db。没有第二次恢复尝试，也没有声称修复或最终时序通过。

本轮未修改RTL、约束、IP、管脚或时钟，没有再综合/布局，没有生成bitstream。游戏提亮、SW2轮播及保留切换效果的实现仍为9e3ad50。

## 后续待确认步骤

已向用户申请单独授权：复用 `game_background_syn_20261014` 网表，显式HFN off，仅独立布局布线一次。收到授权之前不能执行：

```powershell
python src/test/run_resource_build.py game_background_hfn_off_phy_20261014 --route --parent game_background_syn_20261014 --hfn-off
```

该目录避免覆盖用户GUI结果；构建器从opt_place开始、以opt_route结束，不重新综合、不生成位流。必须核对实际日志HFN off、打包容量、无路由DRC错误和最终时序。若仍失败则停止，不继续循环布局种子或擅改冲突网络。

保留用户所有未提交改动，未覆盖current-state；此记录只描述已发生的失败与单次授权范围。
