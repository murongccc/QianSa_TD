# 删除触摸十字并缓解路由资源压力（2026-10-13）

本次按用户追加指令“修复的同时删除十字线”，覆盖先前保留A/B十字的要求。最新主工程不再显示触摸十字；三指游戏输入、四轨发光、T/S与L串口诊断保留。

## 失败依据与策略修复

用户GUI构建在 `x2y36_n2beg4` 报告renderer的 `difference[15]` 与 `time_snapshot[30]` 路由资源冲突，Place Packing为4895/4900 MSlice，只余5。不是日志明确报告的MSlice超限。失败流程实际使用HFN medium，而先前要求是off。

已在主 `.al` 局部补回 `hfn_opt_effort=off`，保留用户 `post_place_opt=medium` 及其余所有内容。重新加载TD工程后，须以运行日志参数表确认off；仍打开的GUI旧状态可能再次覆盖磁盘策略。未改写任何厂商IP、生成的运行工程、引脚或时钟。

失败现场和详细分析见 `three-touch-route-failure-2026-10-13.md`，快照在 `prj/log/three_touch_route_failure_20261013/`。

## RTL改动

仅修改 `src/top_tf_hdmi_audio.v`：

- `ENABLE_TOUCH_MARKERS=0`，视频端触摸包接常量0，不再绘制十字。
- 删除板级 `u_touch_mapper` 和 `u_touch_frame_snapshot` 两个专用实例及其连线，真正释放映射/快照资源。
- A/B原始坐标仍给触摸绑定和T/S诊断；C原始坐标给三指游戏输入。输入不依赖像素mapper，因此删除视频链不影响标定、身份、忽略触点生命周期或事件延迟。

通用mapper、snapshot和marker源文件保留供历史测试/其他工程使用；主工程实例已移除或参数裁剪，综合层级确认无这些资源。无需修改用户已有改动的综合源列表，也没有加入新可综合模块。视频内部用于旁频谱坐标的计数保持原样。

三指parser、lane、CDC、串口monitor及rhythm renderer RTL与修改前逐文件文本对照一致。未修改 `difference` 算术、游戏判定、Hold显示、光晕、滚速、音频、FFT、图片或双线性缩放。

## 仿真与静态验证

- `run_touch_marker_regression.py --case video`：关闭十字的视频与参考画面逐拍一致，1536000个有效像素；同时检查图像/游戏保留、启动、OSD和切图。
- `run_game_spectrum_regression.py` 指定 `tb_video_game_spectrum`、`tb_hold_glow_fix`、`tb_video_glow_blend`、`tb_rhythm_scroll_speed`：921600个复合画面像素、307200个实际Hold/光晕像素、10000个光晕合成像素、2412次真实串行滚动转换全部通过。
- 静态核对确认顶层十字参数为0、触摸视频包为0、无mapper/snapshot实例；三指输入、CDC、串口和renderer代码未变。T/S不依赖mapper，格式不变。
- 编译均0错误0告警。旧视频参考有两条缺失 `game_layout` 端口提示，禁用十字逐像素对照仍通过；其他所运行视频测试0告警。

本次复用已有完整画面禁用十字对照测试，没有为了简单参数改动添加镜像实现的测试。日志保存在 `prj/log/touch_marker_regression_20261009/` 和 `prj/log/game_spectrum_20261013/`。

## 一次集中综合

目录 `prj/log/three_touch_no_cross_syn_20261013/`，已检查完成标志、资源、层级与告警。相对删除前 `three_touch_syn_20261013` 的同一三指版本：

| 项目 | 删除前 | 删除后 | 变化 |
|---|---:|---:|---:|
| LUT | 18379 | 18143/19600 | -236，余1457 |
| REG | 10685 | 10575/19600 | -110 |
| DSP | 22 | 21/29 | -1 |
| BRAM9K/FIFO9K合计 | 57 | 57/64 | 0 |
| BRAM32K | 11 | 11/16 | 0 |
| PLL | 2 | 2/4 | 0 |
| GCLK | 2 | 2/16 | 0 |

本次只综合一次，没有新的布局布线或bitstream。70条带编号综合告警的类别/数量与删除前完全一致，没有新增告警、黑盒或锁存器。综合层级无 `u_touch_mapper`、`u_touch_frame_snapshot` 或marker。

综合估算仍为Setup -0.213/-3.408ns、Hold +0.471/0ns，与删除前相同；不能当作路由结果。机器记录见 `reports/three-touch-no-cross-2026-10-13.json`。

**本候选缓解了资源压力并修复磁盘HFN策略回退，原物理路由冲突是否消除尚未验证。** 删除236 LUT、110 REG不能转换成确定的MSlice节省；不能直接从失败时4895推算新打包值。

## 下次物理验证与板上检查

用户原约束为默认不布局布线、不生成bitstream，本次遵守。若用户安排下一次唯一完整物理验证，应使用新的无十字综合网表和显式HFN off：

```powershell
python src/test/run_resource_build.py three_touch_no_cross_phy_20261013 --route --parent three_touch_no_cross_syn_20261013 --hfn-off
```

本次没有执行上述命令。不要再用删除十字前的parent网表；独立构建器默认结束于opt_route，不生成bitstream。检查参数表HFN off、实际MSlice余量、无PHY-8023/RUN-8102及最终Setup/Hold；若仍失败先分析报告，不反复试布局种子。

最终下载后，在普通图像和游戏画面触摸各处都不应出现A/B十字。三指不同轨应有三轨光晕和L事件；T/S仍显示A/B原始状态。验证三指同轨合并、第四指不提升及松开重按、三押Tap、三Hold/两Hold加Tap、提前释放和暂停后全松开重武装。Hold光晕和旁频谱仍应与删除前一致。

本次不覆盖用户 `current-state.md`，不提交用户工程配置、PLL、换行状态文件或演示资源。HFN off本来存在于HEAD，因此局部恢复它后仍保持工程的用户差异，不把整份 `.al` 纳入本轮commit。
