# QianSa_TD

安路 EG4S20 FPGA 图片播放与 HDMI 音频工程。

## BMP 分辨率与双线性缩放

`src/SD/bmp_read.v` 从 BMP 文件头的 BITMAPINFOHEADER 小端字段解析原始
宽度（偏移 18）和高度（偏移 22），并识别负高度表示的 top-down BMP。解析结果
通过 `parsed_width`、`parsed_height` 和 `parsed_top_down` 输出；宽度/高度不再被
固定的 640×480 匹配条件限制，仍校验 24-bit、BI_RGB 非压缩格式及 4096 像素上限。

`src/SD/bmp_bilinear_scaler.v` 提供 24-bit RGB 流式双线性缩放器。它使用两个源图像
行缓存，坐标采用 16.16 固定点，横纵方向权重采用 8-bit 小数，并将边界坐标钳位到
最后一个源像素。输入输出均为 ready/valid 握手，默认输出 640×480，可通过参数改变
目标尺寸。该模块可置于 BMP 字节组包和 SDRAM 写 FIFO 之间；现有帧缓存接口保持
640×480，因此不会改变 HDMI 时序和三帧缓存地址布局。

参考实现（用于接口、行缓存和固定点算法交叉验证）：

- [sricharan-yerramsetti/bilinear-image-scaler-axistream](https://github.com/sricharan-yerramsetti/bilinear-image-scaler-axistream)
- [RRidhii280507/Scale-X_ichip_ps1](https://github.com/RRidhii280507/Scale-X_ichip_ps1)
