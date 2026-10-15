# 暂时关闭触摸串口监视

顶层增加 `TOUCH_SERIAL_MONITOR_ENABLED`，默认值为 0，通过 generate 裁剪
`touch_serial_monitor`；板载 CH340 的 `uart_txd` 保持空闲高电平，监视溢出标志置零。
置 1 后重新综合可恢复串口监视。触摸接收、轨道映射、游戏事件桥连接保持不变；
视频 D/F/C 三点诊断配置保持不变。

独立综合 `prj/log/touch_monitor_disabled_syn_20261015/` 完成：
LUT 17827、REG 10710、BRAM9K/FIFO 54、BRAM32K 15、DSP 18。
层次报告确认串口监视实例被裁剪，触摸接收、轨道映射及游戏事件桥保留。
`git diff --check` 通过。综合含现有厂商 IP 初始化和未驱动信号告警。

独立物理尝试 `prj/log/touch_monitor_disabled_phy_20261015/` 的打包为
4781/4900 MSlice，容量通过，余量 119。用户随后要求自行布局，未再启动物理运行。
检查运行状态时该次流程已以布线错误退出：PHY-8023，位置 x13y37_local1，
涉及 HDMI IIC 接收控制器及 FFT 的复位复制网络；RUN-8102。
本次没有完整路由成功和最终时序通过结论，没有生成位流。
