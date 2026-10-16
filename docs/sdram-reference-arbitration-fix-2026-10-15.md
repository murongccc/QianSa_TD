# SDRAM 参考例程对照与读写互斥修复（2026-10-15）

## 参考来源与写入方式

只读检查用户提供的
`E:/AN_LU_saiti/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/LiTi/lab_ex5_i2s/src/user_source/hdl_source/`。
未修改参考例程，也未按其中的管脚或时钟替换当前工程配置。

- `top_tf_hdmi_audio.v`：实际只使用两个 SDRAM 帧槽，地址为 0 和 307200，单位是 32 位字。
- `SD/sd_card_bmp.v`：扫描时缓存前四张图片的 SD 起始扇区，缓存的是地址描述符，
  没有把四张图片的像素全部预装进 SDRAM。首图写槽 0；下一张从 SD 重新读取，
  写入当前未显示的另一槽，写完再切换。
- 像素按 `{R,G,B,8'd0}` 写入 32×512 异步 FIFO，再由内存域按 256 字一组送往 SDRAM。
  每张 640×480 图片为 307200 字。参考顶层启用写入时垂直翻转，以处理 BMP 的行顺序。
- `bmp_read` 保持 `write_req` 直到 `write_req_ack`；内存侧确认期间清写 FIFO、锁存地址。
  源读取完成和 `write_finish_toggle` 同步事件汇合后才提交显示槽。
- 参考例程 SDRAM 为 125 MHz/180°两路，`self_refresh_open=1`、外部 `App_ref_req=0`。
  当前工程为 100 MHz 两路与外部手动刷新策略。本次不回退这些配置。
- 参考例程有固定等待 10 拍结束读 burst、未使用读 FIFO 输出寄存器等旧实现。
  当前按实际返回字数结束读 burst、启用输出寄存器等已有修复保留，不能整段照搬旧模块。

当前工程是最多五槽像素预装，之后切槽不再读取 SD。三槽和五槽按当前固定帧尺寸都
没有超过 2M×32 SDRAM 的地址容量；容量计算本身不能证明握手、时序与数据保持正确。

## 可复现的仲裁缺陷

参考写侧的 `into_burst` 包含实时 `!App_rd_busy`，并直接用于写侧的提前 busy 和准入。
当前工程为了切断 FIFO 占用比较路径，将条件寄存为 `into_burst_d`。
该改动可追溯至 `50fc5e2`（2026-09-18）。进入写 burst 时只检查这个上一拍结果，
没有再次检查实时读忙。

当读写双方都处于 `S_CHECK_FIFO`，而写 FIFO 刚达到阈值时：

1. `into_burst_d` 仍为 0，读侧看不到提前写 busy，于是获得读 burst。
2. 同一拍写侧把 FIFO 就绪、旧的读空闲状态寄存为 `into_burst_d=1`。
3. 下一拍读侧已忙，但控制器尚未采到流水线中的第一条读命令，`Sdr_busy` 仍可能为 0。
4. 旧写侧仅凭 `into_burst_d=1` 启动写 burst，随后两个 App 使能同时为高。

原有 `tb_frame_fifo_refresh_gate` 分别把双方的对端 busy 接为常量零，验证刷新门控，
没有验证这两个真实状态机的互斥。因此需要新增连接实际 busy 输出的测试。

## 最小修复

在 `src/SD/frame_fifo_write.v` 的 `S_CHECK_FIFO` 写 burst 准入条件中补充
`!App_rd_busy`，保留寄存的 FIFO 就绪条件和现有刷新、控制器 busy 检查。
修复只影响新 burst 的启动，不中断已启动 burst，不修改图片槽数、像素、时钟或管脚。

## 仿真证据

运行：

```powershell
python src/test/run_frame_burst_regression.py --reference "E:/AN_LU_saiti/HX4S20_Contest_202606/7_lab_ex_2026_nosoft/LiTi/lab_ex5_i2s/src/user_source/hdl_source"
```

- 固定历史参考 `8e3dd70`：必须复现 `overlapping SDRAM read/write commands`，旧版在竞争场景第 12 周期失败。
- 修复版：覆盖 FIFO 提前就绪、恰好在读侧准入时就绪、读侧启动后才就绪三种时机，
  均无读写命令重叠；分别测试 4 字和板级 256 字 burst，两侧各完成两个 burst。
- 用户参考写侧：仅适配测试端口与固定参数，不修改其逻辑，接入同一场景通过。
- 现有刷新准入回归通过；线性及垂直翻转地址回归通过。
- 编译零错误、零告警；所有正向仿真零错误、零告警。
- 日志保存在 `prj/log/frame_burst_regression_20261015/`。

## 验证边界

确认的是实际读写状态机之间的仲裁漏洞，测试不包含加密 SDRAM 控制器及真实存储颗粒。
尚不能据此认定每次首图完整出现后闪烁 1～2 秒的全部原因已找到。
当前预装流程在提交首图前等待所有加载完成，而闪线出现在显示后；仍需结合板上
启动阶段的读写使能和诊断趋势判断该漏洞对可见故障的实际影响。
本轮不改变诊断点配置，不用降频代替对已证实协议漏洞的修复。
全工程综合通过：LUT `18079/19600`、REG `10737/19600`、BRAM9K/FIFO `54/64`、
BRAM32K `15/16`、DSP `18/29`。综合日志位于
`prj/log/frame_burst_guard_syn_20261015/`，沿用当前工程策略，未新增综合告警类别。
默认布局布线流程完成，没有路由 DRC 错误，最终占用 `4855/4900` MSlice，余量 45 个；
路由后 LUT `18192/19600`、REG `10885/19600`，RAM/DSP 数量不变。
Setup WNS/TNS 为 `-0.401/-0.401 ns`，Hold WNS/TNS 为 `-0.060/-0.530 ns`，时序尚未闭合。
最差 Setup 路径位于 C 诊断本身：`u_sdram_read_monitor/frame_signature_reg[1]` →
`mismatch_count_reg[0].ce`，不能仅据此判定实际图像读数据路径不满足时序。
完整报告位于 `prj/log/frame_burst_guard_phy_20261015/SD_to_Video_pr.timing`。
三个签名监视点仍由 `VIDEO_SIGNATURE_DIAGNOSTICS=1`、`VIDEO_DIAGNOSTIC_POINT=0` 并行启用。
未生成 bitstream，未完成板级验证，不能把流程完成或互斥回归通过当作彩线已消失的证明。
该资源统计包括用户此前对其他功能的优化，不能将资源收益归因于本次一条准入条件修复。

## 后续实板反馈（2026-10-16）

用户使用本版完成实板验证，反馈“问题解决了”，并要求提交到 GitHub。
因此，上述“未完成板级验证”为 2026-10-15 交付时的状态；本版现已有用户确认的
彩线问题解决结果。未提供连续上电次数或长时间测试统计，不补充推定的验证范围。

保留修复提交 `9a1e2dd`（启动 SDRAM 写 burst 前重新检查读侧 busy）、对应回归，
以及当前 TD 工程文件中的既有综合和布局设置。三个签名监视点继续同时启用。
该实板反馈不改变上述静态时序报告中的未闭合项。
