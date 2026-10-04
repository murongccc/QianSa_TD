# QianSa_TD

安路 EG4S20 FPGA 图片播放与 HDMI 音频工程。

## SD 音乐格式（2026-10-04 起）

板级 WAV 读取器仅接受 **44 字节头、48 kHz、16 bit、双声道、无压缩 PCM**。
`fmt ` 长度必须为 16，`data` 必须紧随其后；RIFF/data 长度必须与 FAT32
目录项中的文件大小一致，数据非空且包含完整的 4 字节立体声采样帧。
不再接受 LIST/JUNK/fact、扩展 fmt 或尾随块；错误文件在当前扇区排空后停止，
不会将附加块当成 PCM 播放。FAT32 分区/直接卷、碎片簇链、媒体循环及游戏单次播放保留。

普通音乐先转换后复制到 SD 根目录，转换工具会重采样并显式生成规范头：

```powershell
python src/python/normalize_wav.py "原音乐.mp3" "输出目录/MUSIC.WAV"
```

工具需要 FFmpeg，默认查找 PATH 或 `E:/ffmpeg/bin/ffmpeg.exe`，也可用
`--ffmpeg` 指定位置。已有输出默认不覆盖；明确需要替换时使用 `--force`。
请勿将普通媒体音乐命名为 `GAME.WAV`，该名称保留给音游资源。
`osz_to_game.py` 生成的 `GAME.WAV` 已符合本格式，无需再次转换。

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
