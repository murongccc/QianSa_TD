# 功能链与模块资源占用（2026-10-10）

基线：2026-10-09 23:37:22 开始的最终触摸标记综合。资源与用户给出的 LUT 18401、REG 10370、BRAM9K/FIFO9K 57、BRAM32K 11、DSP 29 完全一致。
原始报告：[SD_to_Video_gate.area](E:/AnLuTD_Project/SD_to_Video/prj/log/touch_markers_final_syn_20261009/SD_to_Video_gate.area)。使用 TD 导入同一次综合的 gate.db 并导出网表，逐实例统计物理存储与 DSP 原语。未重新综合、布局布线或生成 bitstream。

统计口径：

- LUT 合计 = hierarchy 表的 lut + ripple；全局为 14762 + 3639 = 18401。
- SEQ 是层次报告原始时序单元口径，合计 10404；利用率 REG 为 10370。差值 34 与报告中的 I/O 寄存器计数 ireg 9 + oreg 24 + treg 1 相符，不将 SEQ 冒充纯 REG。
- 层次报告 bram 合并了三类存储；本表按 EG_PHY_BRAM / EG_PHY_FIFO / EG_PHY_BRAM32K 实例名归属拆成 41 / 16 / 11，并逐层核对。
- 普通模块行包含其全部子模块；“本体”行扣除直接子模块。各功能链汇总采用互不重叠的归属，允许跨 RTL 层次归类，每个资源只计一次。
- 资源来自扁平化后综合网表实例名的归属，属于这一次整板综合的统计，不能视为模块独立综合的固有资源。
- PLL 共 2、GCLK 共 2；sdram 另外包含 1 个 EG_PHY_SDRAM_2M_32 专用块。PLL/SDRAM专用块不计入 BRAM9K/BRAM32K。
- 当前触摸链只显示标记及串口监视；top 中音游引擎 event_valid=0，press_mask/release_mask/down_mask=0，触摸尚未连接到人工四轨判定。

## 功能链汇总

| 功能链 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---:|---:|---:|---:|---:|---:|
| 共享 SD 接口与调度 | 486 | 274 | 0 | 0 | 0 | 0 |
| 图片预装与双线性缩放 | 3,356 | 2,228 | 1 | 0 | 6 | 5 |
| SDRAM 帧存储与视频读取 | 777 | 921 | 4 | 0 | 0 | 0 |
| WAV 音频读取与播放 | 1,917 | 933 | 0 | 16 | 0 | 0 |
| FFT 与环形频谱 | 2,779 | 621 | 4 | 0 | 4 | 13 |
| 谱面读取、音游判定与渲染 | 4,818 | 2,457 | 11 | 0 | 1 | 3 |
| 触摸解析、串口监视与十字显示 | 1,239 | 638 | 5 | 0 | 0 | 5 |
| 图像调节、OSD 与最终合成 | 934 | 244 | 0 | 0 | 0 | 3 |
| HDMI 音视频封装与物理输出 | 1,689 | 1,682 | 16 | 0 | 0 | 0 |
| 时钟、复位、命令与诊断 | 406 | 406 | 0 | 0 | 0 | 0 |
| **总计** | 18,401 | 10,404 | 41 | 16 | 11 | 29 |

## 1. 共享 SD 接口与调度

BMP/WAV/谱面请求 → 扇区仲裁 → SD 命令与 SPI → 各读取器

| 模块/归属 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| sd_card_top | `top/sd_media_pipeline_m0/u_sd` | 279 | 180 | 0 | 0 | 0 | 0 |
| sd_sector_arbiter | `top/sd_media_pipeline_m0/rhythm_resources$resources/u_arbiter` | 118 | 54 | 0 | 0 | 0 | 0 |
| domain_reset_sync：媒体复位 | `top/sd_media_pipeline_m0/u_reset_local` | 7 | 7 | 0 | 0 | 0 | 0 |
| domain_reset_sync：资源复位 | `top/sd_media_pipeline_m0/rhythm_resources$clear_sync` | 7 | 6 | 0 | 0 | 0 | 0 |
| sd_media_pipeline 本体 | `top/sd_media_pipeline_m0` | 32 | 25 | 0 | 0 | 0 | 0 |
| rhythm_sd_resources 本体 | `top/sd_media_pipeline_m0/rhythm_resources$resources` | 43 | 2 | 0 | 0 | 0 | 0 |
| **小计** | | 486 | 274 | 0 | 0 | 0 | 0 |

子模块明细（已包含在上表父模块中，不再加到小计）：

| 子模块 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| sd_card_cmd | `top/sd_media_pipeline_m0/u_sd/sd_card_cmd_m0` | 150 | 47 | 0 | 0 | 0 | 0 |
| sd_card_sec_read_write | `top/sd_media_pipeline_m0/u_sd/sd_card_sec_read_write_m0` | 62 | 89 | 0 | 0 | 0 | 0 |
| spi_master | `top/sd_media_pipeline_m0/u_sd/spi_master_m0` | 67 | 44 | 0 | 0 | 0 | 0 |

## 2. 图片预装与双线性缩放

FAT32/BMP目录 → BMP读取 → 源像素FIFO → 双线性缩放及奇偶行缓存 → SDRAM写入；会话控制决定预装完成与切图

| 模块/归属 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| fat32_bmp_catalog | `top/sd_media_pipeline_m0/u_bmp_catalog` | 844 | 754 | 1 | 0 | 0 | 2 |
| bmp_read | `top/sd_media_pipeline_m0/u_bmp_read` | 1,065 | 646 | 0 | 0 | 0 | 0 |
| source_pixel_fifo_ip | `top/sd_media_pipeline_m0/source_pixel_fifo` | 73 | 84 | 0 | 0 | 2 | 0 |
| bmp_bilinear_scaler | `top/sd_media_pipeline_m0/u_scaler` | 1,160 | 647 | 0 | 0 | 4 | 3 |
| media_session_controller | `top/sd_media_pipeline_m0/u_session` | 214 | 97 | 0 | 0 | 0 | 0 |
| **小计** | | 3,356 | 2,228 | 1 | 0 | 6 | 5 |

子模块明细（已包含在上表父模块中，不再加到小计）：

| 子模块 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| soft_fifo_f9a960ae4922 | `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst` | 72 | 84 | 0 | 0 | 2 | 0 |
| al_soft_fifo_J5Dq79mN_f9a960ae4922 | `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst/al_soft_fifo_ELyPIOfr` | 49 | 31 | 0 | 0 | 0 | 0 |
| al_soft_fifo_MPXy9iEA_f9a960ae4922 | `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst/al_soft_fifo_ELyPIOfr/al_soft_fifo_eSCWbQZ_` | 2 | 2 | 0 | 0 | 0 | 0 |
| al_soft_fifo_CMEB9ZlH_f9a960ae4922 | `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst/al_soft_fifo_ktZv2ExW` | 2 | 25 | 0 | 0 | 2 | 0 |
| al_soft_fifo_EoCVCOi5_f9a960ae4922 | `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst/al_soft_fifo_ktZv2ExW/al_soft_fifo_BpJUKxcz` | 1 | 0 | 0 | 0 | 2 | 0 |
| al_soft_fifo_nzFbx5iw_f9a960ae4922 | `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst/al_soft_fifo_pXuL5aOr` | 21 | 28 | 0 | 0 | 0 | 0 |
| al_soft_fifo_ZBIjHksb_f9a960ae4922 | `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst/al_soft_fifo_pXuL5aOr/al_soft_fifo_asSgfuf5` | 7 | 27 | 0 | 0 | 0 | 0 |
| al_soft_fifo_HiHqg1Au_f9a960ae4922 | `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst/al_soft_fifo_pXuL5aOr/al_soft_fifo_whu47jXM` | 14 | 1 | 0 | 0 | 0 | 0 |
| rhythm_block_ram | `top/sd_media_pipeline_m0/u_bmp_catalog/descriptor_cache` | 3 | 0 | 1 | 0 | 0 | 0 |
| scaler_linebuf_even_ip | `top/sd_media_pipeline_m0/u_scaler/u_line_even` | 1 | 0 | 0 | 0 | 2 | 0 |
| scaler_linebuf_odd_ip | `top/sd_media_pipeline_m0/u_scaler/u_line_odd` | 1 | 0 | 0 | 0 | 2 | 0 |
| media_key_press_debounce | `top/sd_media_pipeline_m0/u_session/u_key_next` | 59 | 23 | 0 | 0 | 0 | 0 |

## 3. SDRAM 帧存储与视频读取

缩放像素 → 写FIFO/写控制 → SDRAM → 读控制/读FIFO → 视频时序与延迟 → RGB

| 模块/归属 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| frame_read_write | `top/frame_read_write_m0` | 522 | 367 | 4 | 0 | 0 | 0 |
| sdram / sdr_as_ram | `top/U3` | 96 | 422 | 0 | 0 | 0 | 0 |
| sdram_refresh_scheduler | `top/u_sdram_refresh_scheduler` | 93 | 33 | 0 | 0 | 0 | 0 |
| video_timing_data | `top/video_timing_data_m0` | 42 | 33 | 0 | 0 | 0 | 0 |
| video_delay | `top/video_delay_m0` | 24 | 66 | 0 | 0 | 0 | 0 |
| **小计** | | 777 | 921 | 4 | 0 | 0 | 0 |

子模块明细（已包含在上表父模块中，不再加到小计）：

| 子模块 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| sdr_as_ram | `top/U3/u2_ram` | 96 | 422 | 0 | 0 | 0 | 0 |
| sdr_init_ref | `top/U3/u2_ram/u1_init_ref` | 25 | 81 | 0 | 0 | 0 | 0 |
| sdr_wrrd | `top/U3/u2_ram/u2_wrrd` | 71 | 341 | 0 | 0 | 0 | 0 |
| frame_fifo_read | `top/frame_read_write_m0/frame_fifo_read_m0` | 129 | 74 | 0 | 0 | 0 | 0 |
| frame_fifo_write | `top/frame_read_write_m0/frame_fifo_write_m0` | 239 | 81 | 0 | 0 | 0 | 0 |
| rfifo_32_32_512 | `top/frame_read_write_m0/read_buf` | 72 | 118 | 2 | 0 | 0 | 0 |
| ram_infer_rfifo_32_32_512 | `top/frame_read_write_m0/read_buf/ram_inst` | 0 | 24 | 2 | 0 | 0 | 0 |
| fifo_cross_domain_addr_process_al_rfifo_32_32_512 | `top/frame_read_write_m0/read_buf/rd_to_wr_cross_inst` | 16 | 36 | 0 | 0 | 0 | 0 |
| fifo_cross_domain_addr_process_al_rfifo_32_32_512 | `top/frame_read_write_m0/read_buf/wr_to_rd_cross_inst` | 16 | 36 | 0 | 0 | 0 | 0 |
| wfifo_32_32_512 | `top/frame_read_write_m0/write_buf` | 82 | 94 | 2 | 0 | 0 | 0 |
| ram_infer_wfifo_32_32_512 | `top/frame_read_write_m0/write_buf/ram_inst` | 0 | 0 | 2 | 0 | 0 | 0 |
| fifo_cross_domain_addr_process_al_wfifo_32_32_512 | `top/frame_read_write_m0/write_buf/rd_to_wr_cross_inst` | 16 | 36 | 0 | 0 | 0 | 0 |
| fifo_cross_domain_addr_process_al_wfifo_32_32_512 | `top/frame_read_write_m0/write_buf/wr_to_rd_cross_inst` | 16 | 36 | 0 | 0 | 0 | 0 |
| color_bar | `top/video_timing_data_m0/color_bar_m0` | 41 | 28 | 0 | 0 | 0 | 0 |

## 4. WAV 音频读取与播放

FAT32/WAV读取 → 32×4096音频FIFO → PCM播放器 → HDMI音频入口；ACR计算音频时钟恢复参数

| 模块/归属 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| fat32_wav_reader | `top/sd_media_pipeline_m0/rhythm_resources$resources/u_wav` | 1,392 | 715 | 0 | 0 | 0 | 0 |
| audio_fifo_32x4096 | `top/u_audio_fifo` | 1 | 0 | 0 | 16 | 0 | 0 |
| pcm_audio_player | `top/u_pcm_audio_player` | 467 | 171 | 0 | 0 | 0 | 0 |
| audio_arc_calculate | `top/u_audio_arc_calculate` | 57 | 47 | 0 | 0 | 0 | 0 |
| **小计** | | 1,917 | 933 | 0 | 16 | 0 | 0 |

## 5. FFT 与环形频谱

PCM采样 → 2048点FFT/Hann/频谱处理 → 柱缓存 → 环形频谱渲染 → 视频叠加

| 模块/归属 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| audio_fft_spectrum / reference_fft_spectrum | `top/u_audio_fft_spectrum` | 2,110 | 557 | 4 | 0 | 4 | 5 |
| ring_spectrum_renderer | `top/u_video_presentation/u_ring_spectrum_renderer` | 669 | 64 | 0 | 0 | 0 | 8 |
| **小计** | | 2,779 | 621 | 4 | 0 | 4 | 13 |

子模块明细（已包含在上表父模块中，不再加到小计）：

| 子模块 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| reference_fft_spectrum | `top/u_audio_fft_spectrum/g_reference$u_reference` | 2,110 | 557 | 4 | 0 | 4 | 5 |
| rhythm_block_ram | `top/u_audio_fft_spectrum/g_reference$u_reference/block_bars$cache` | 2 | 0 | 1 | 0 | 0 | 0 |
| fft_spectrum_bank_ram | `top/u_audio_fft_spectrum/g_reference$u_reference/u_bank0` | 73 | 0 | 0 | 0 | 2 | 0 |
| fft_spectrum_bank_ram | `top/u_audio_fft_spectrum/g_reference$u_reference/u_bank1` | 46 | 0 | 0 | 0 | 2 | 0 |

## 6. 谱面读取、音游判定与渲染

谱面读取 → 谱面缓冲 → 音游引擎/自动输入/判定 → 游戏渲染与HUD；会话控制按实际PCM输出推进时间

| 模块/归属 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| fat32_chart_reader | `top/sd_media_pipeline_m0/rhythm_resources$resources/u_chart` | 1,215 | 810 | 0 | 0 | 0 | 0 |
| rhythm_chart_buffer | `top/sd_media_pipeline_m0/rhythm_resources$resources/u_buffer` | 63 | 65 | 4 | 0 | 0 | 0 |
| rhythm_block_ram：元数据 | `top/sd_media_pipeline_m0/rhythm_resources$resources/metadata_ram$ram` | 9 | 0 | 0 | 0 | 1 | 0 |
| rhythm_session_controller | `top/u_game_session` | 661 | 477 | 0 | 0 | 0 | 0 |
| rhythm_game_engine | `top/u_game_engine` | 1,072 | 632 | 2 | 0 | 0 | 1 |
| rhythm_game_renderer | `top/u_game_renderer` | 1,798 | 473 | 5 | 0 | 0 | 2 |
| **小计** | | 4,818 | 2,457 | 11 | 0 | 1 | 3 |

子模块明细（已包含在上表父模块中，不再加到小计）：

| 子模块 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| rhythm_auto_input | `top/u_game_engine/auto_input` | 69 | 47 | 0 | 0 | 0 | 0 |
| rhythm_judge_core | `top/u_game_engine/judge` | 1,001 | 583 | 2 | 0 | 0 | 1 |
| rhythm_block_ram | `top/u_game_engine/judge/block_queue$judge_ram` | 6 | 0 | 1 | 0 | 0 | 0 |
| rhythm_block_ram | `top/u_game_engine/judge/block_queue$view_ram` | 5 | 0 | 1 | 0 | 0 | 0 |
| rhythm_block_ram | `top/u_game_renderer/block_geometry$ram` | 24 | 0 | 2 | 0 | 0 | 0 |
| rhythm_font | `top/u_game_renderer/font` | 22 | 1 | 1 | 0 | 0 | 0 |
| rhythm_hud | `top/u_game_renderer/hud` | 668 | 148 | 2 | 0 | 0 | 0 |
| rhythm_block_ram | `top/u_game_renderer/hud/block_characters$ram` | 198 | 72 | 1 | 0 | 0 | 0 |
| audio_control_debounce | `top/u_game_session/gsw` | 52 | 22 | 0 | 0 | 0 | 0 |
| audio_control_debounce | `top/u_game_session/key2` | 53 | 23 | 0 | 0 | 0 | 0 |
| audio_control_debounce | `top/u_game_session/key3` | 53 | 22 | 0 | 0 | 0 | 0 |
| audio_control_debounce | `top/u_game_session/key4` | 53 | 22 | 0 | 0 | 0 | 0 |
| audio_control_debounce | `top/u_game_session/rsw` | 52 | 21 | 0 | 0 | 0 | 0 |

## 7. 触摸解析、串口监视与十字显示

CH9350 UART → 帧解析/应答 → 原始触点；分支1：串口监视；分支2：坐标映射 → 跨域帧快照 → 十字叠加

| 模块/归属 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| ch9350_touch_input | `top/u_touch_input` | 538 | 368 | 0 | 0 | 0 | 4 |
| touch_serial_monitor | `top/u_touch_monitor` | 480 | 162 | 5 | 0 | 0 | 0 |
| touch_pixel_mapper | `top/u_touch_mapper` | 135 | 59 | 0 | 0 | 0 | 1 |
| touch_frame_snapshot | `top/u_touch_frame_snapshot` | 6 | 49 | 0 | 0 | 0 | 0 |
| touch_marker | `top/u_video_presentation/g_touch_markers$u_marker` | 80 | 0 | 0 | 0 | 0 | 0 |
| **小计** | | 1,239 | 638 | 5 | 0 | 0 | 5 |

子模块明细（已包含在上表父模块中，不再加到小计）：

| 子模块 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| uart_byte_tx | `top/u_touch_input/u_ack_tx` | 36 | 22 | 0 | 0 | 0 | 0 |
| ch9350_touch_parser | `top/u_touch_input/u_parser` | 410 | 288 | 0 | 0 | 0 | 4 |
| touch_counter_increment | `top/u_touch_input/u_parser/u_checksum_increment` | 0 | 0 | 0 | 0 | 0 | 1 |
| touch_counter_increment | `top/u_touch_input/u_parser/u_format_increment` | 0 | 0 | 0 | 0 | 0 | 1 |
| touch_counter_increment | `top/u_touch_input/u_parser/u_gap_increment` | 0 | 0 | 0 | 0 | 0 | 1 |
| touch_counter_increment | `top/u_touch_input/u_parser/u_good_increment` | 0 | 0 | 0 | 0 | 0 | 1 |
| uart_byte_rx | `top/u_touch_input/u_rx` | 63 | 36 | 0 | 0 | 0 | 0 |
| uart_byte_tx | `top/u_touch_monitor/u_tx` | 96 | 23 | 0 | 0 | 0 | 0 |

## 8. 图像调节、OSD 与最终合成

图像调节按键 → 参数；RGB/频谱/音游/触摸 → 图像处理、OSD与最终像素合成

| 模块/归属 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| image_controls | `top/u_image_controls` | 193 | 70 | 0 | 0 | 0 | 0 |
| video_presentation 本体 | `top/u_video_presentation` | 741 | 174 | 0 | 0 | 0 | 3 |
| **小计** | | 934 | 244 | 0 | 0 | 0 | 3 |

子模块明细（已包含在上表父模块中，不再加到小计）：

| 子模块 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| media_key_press_debounce | `top/u_image_controls/u_dec` | 56 | 22 | 0 | 0 | 0 | 0 |
| media_key_press_debounce | `top/u_image_controls/u_inc` | 56 | 22 | 0 | 0 | 0 | 0 |

## 9. HDMI 音视频封装与物理输出

处理后的RGB → AXIS → HDMI核（视频、音频数据岛、EDID/I²C） → TMDS串行物理输出

| 模块/归属 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| video_rgb_to_axis_640x480 | `top/u_video_rgb_to_axis_640x480` | 23 | 40 | 0 | 0 | 0 | 0 |
| hdmi_1_4b_transmitter_core_wrapper | `top/u_hdmi_1_4b_transmitter_core_wrapper` | 1,605 | 1,573 | 16 | 0 | 0 | 0 |
| hdmi_phy_wrapper | `top/u_hdmi2phy_wrapper` | 34 | 47 | 0 | 0 | 0 | 0 |
| startup_pulse | `top/u_startup_pulse` | 27 | 22 | 0 | 0 | 0 | 0 |
| **小计** | | 1,689 | 1,682 | 16 | 0 | 0 | 0 |

子模块明细（已包含在上表父模块中，不再加到小计）：

| 子模块 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| lane_lvds_10_1 | `top/u_hdmi2phy_wrapper/u0_lane_lvds_8_1` | 12 | 18 | 0 | 0 | 0 | 0 |
| lane_lvds_10_1 | `top/u_hdmi2phy_wrapper/u1_lane_lvds_8_1` | 10 | 12 | 0 | 0 | 0 | 0 |
| lane_lvds_10_1 | `top/u_hdmi2phy_wrapper/u2_lane_lvds_8_1` | 10 | 12 | 0 | 0 | 0 | 0 |
| lane_lvds_10_1 | `top/u_hdmi2phy_wrapper/u3_lane_lvds_8_1` | 2 | 5 | 0 | 0 | 0 | 0 |
| hdmi_1_4b_tx_reset_sync | `top/u_hdmi_1_4b_transmitter_core_wrapper/u0_reset_sync` | 0 | 2 | 0 | 0 | 0 | 0 |
| hdmi_edid_wrapper | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_edid_wrapper` | 227 | 155 | 2 | 0 | 0 | 0 |
| hdmi_edid_read_controller | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_edid_wrapper/u_hdmi_edid_read_controller` | 10 | 11 | 0 | 0 | 0 | 0 |
| iic_master_wrapper | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_edid_wrapper/u_iic_master_wrapper` | 217 | 144 | 2 | 0 | 0 | 0 |
| iic_bit_transmitter | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_edid_wrapper/u_iic_master_wrapper/u_iic_bit_transmitter` | 77 | 31 | 0 | 0 | 0 | 0 |
| iic_transmitter_controller | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_edid_wrapper/u_iic_master_wrapper/u_iic_transmitter_controller` | 140 | 113 | 2 | 0 | 0 | 0 |
| iic_w11_d1024_fifo | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_edid_wrapper/u_iic_master_wrapper/u_iic_transmitter_controller/u_iic_w11_d1024_fifo` | 28 | 55 | 2 | 0 | 0 | 0 |
| hdmi_tx_controller_wrapper | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper` | 1,378 | 1,416 | 14 | 0 | 0 | 0 |
| hdmi_tmds_encode | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u0_hdmi_tmds_encode` | 162 | 160 | 0 | 0 | 0 | 0 |
| hdmi_tmds_encode | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u1_hdmi_tmds_encode` | 159 | 108 | 0 | 0 | 0 | 0 |
| hdmi_tmds_encode | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u2_hdmi_tmds_encode` | 157 | 108 | 0 | 0 | 0 | 0 |
| hdmi_data_distribution | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_data_distribution` | 2 | 43 | 0 | 0 | 0 | 0 |
| hdmi_island_data_assemble | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_assemble` | 277 | 418 | 0 | 0 | 0 | 0 |
| hdmi_island_data_gen | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen` | 330 | 422 | 11 | 0 | 0 | 0 |
| audio_sample_packet_2_channel | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/U_audio_sample_packet_2_channel` | 142 | 219 | 11 | 0 | 0 | 0 |
| w96_d1024_fifo | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/U_audio_sample_packet_2_channel/u_w96_d1024_fifo` | 24 | 55 | 11 | 0 | 0 | 0 |
| BCH_32_24_encode | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/U_audio_sample_packet_2_channel/u_BCH_32_24_encode` | 0 | 1 | 0 | 0 | 0 | 0 |
| BCH_64_56_encode | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/U_audio_sample_packet_2_channel/u_BCH_64_56_encode` | 0 | 8 | 0 | 0 | 0 | 0 |
| audio_clock_regeneration_packet | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/u_audio_clock_regeneration_packet` | 27 | 63 | 0 | 0 | 0 | 0 |
| BCH_64_56_encode | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/u_audio_clock_regeneration_packet/u_BCH_64_56_encode` | 0 | 8 | 0 | 0 | 0 | 0 |
| hdmi_video_data_assemble | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_video_data_assemble` | 0 | 40 | 0 | 0 | 0 | 0 |
| hdmi_video_source | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_video_source` | 224 | 38 | 0 | 0 | 0 | 0 |
| video_axi_stream_receiver | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_video_axi_stream_receiver` | 67 | 79 | 3 | 0 | 0 | 0 |
| w24_d1024_fifo | `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_video_axi_stream_receiver/u_w24_d1024_fifo` | 50 | 76 | 3 | 0 | 0 | 0 |

## 10. 时钟、复位、命令与诊断

PLL/复位 → 各时钟域；UART命令、帧读取监视、数码管与顶层粘合逻辑

| 模块/归属 | 实例路径 | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| sys_pll | `top/sys_pll_m0` | 0 | 0 | 0 | 0 | 0 | 0 |
| video_pll | `top/video_pll_m0` | 0 | 0 | 0 | 0 | 0 | 0 |
| domain_reset_sync：clk | `top/u_reset_clk` | 13 | 13 | 0 | 0 | 0 | 0 |
| domain_reset_sync：sd | `top/u_reset_sd` | 12 | 13 | 0 | 0 | 0 | 0 |
| domain_reset_sync：mem | `top/u_reset_mem` | 12 | 13 | 0 | 0 | 0 | 0 |
| domain_reset_sync：video | `top/u_reset_video` | 12 | 13 | 0 | 0 | 0 | 0 |
| uart_command_control | `top/u_uart_command_control` | 84 | 54 | 0 | 0 | 0 | 0 |
| frame_read_monitor | `top/u_frame_read_monitor` | 20 | 18 | 0 | 0 | 0 | 0 |
| seg_scan | `top/seg_scan_m0` | 147 | 19 | 0 | 0 | 0 | 0 |
| top 本体 | `top` | 106 | 263 | 0 | 0 | 0 | 0 |
| **小计** | | 406 | 406 | 0 | 0 | 0 | 0 |

## 原始层次全表

保留所有 133 行层次节点（含 top、厂商 IP 内部子模块及常数传播后保留的节点）。每行总量包含子模块；本体列可用于无重复求和。

| 实例路径 | 模块 | 普通LUT | ripple | LUT合计 | SEQ | BRAM9K | FIFO9K | BRAM32K | DSP | 本体LUT | 本体SEQ | 本体BRAM9K | 本体FIFO9K | 本体BRAM32K | 本体DSP |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `top` | top | 14762 | 3639 | 18,401 | 10,404 | 41 | 16 | 11 | 29 | 106 | 263 | 0 | 0 | 0 | 0 |
| `top/U3` | sdram | 91 | 5 | 96 | 422 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `top/U3/u2_ram` | sdr_as_ram | 91 | 5 | 96 | 422 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `top/U3/u2_ram/u1_init_ref` | sdr_init_ref | 20 | 5 | 25 | 81 | 0 | 0 | 0 | 0 | 25 | 81 | 0 | 0 | 0 | 0 |
| `top/U3/u2_ram/u2_wrrd` | sdr_wrrd | 71 | 0 | 71 | 341 | 0 | 0 | 0 | 0 | 71 | 341 | 0 | 0 | 0 | 0 |
| `top/frame_read_write_m0` | frame_read_write | 388 | 134 | 522 | 367 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `top/frame_read_write_m0/frame_fifo_read_m0` | frame_fifo_read | 102 | 27 | 129 | 74 | 0 | 0 | 0 | 0 | 129 | 74 | 0 | 0 | 0 | 0 |
| `top/frame_read_write_m0/frame_fifo_write_m0` | frame_fifo_write | 168 | 71 | 239 | 81 | 0 | 0 | 0 | 0 | 239 | 81 | 0 | 0 | 0 | 0 |
| `top/frame_read_write_m0/read_buf` | rfifo_32_32_512 | 54 | 18 | 72 | 118 | 2 | 0 | 0 | 0 | 40 | 22 | 0 | 0 | 0 | 0 |
| `top/frame_read_write_m0/read_buf/ram_inst` | ram_infer_rfifo_32_32_512 | 0 | 0 | 0 | 24 | 2 | 0 | 0 | 0 | 0 | 24 | 2 | 0 | 0 | 0 |
| `top/frame_read_write_m0/read_buf/rd_to_wr_cross_inst` | fifo_cross_domain_addr_process_al_rfifo_32_32_512 | 16 | 0 | 16 | 36 | 0 | 0 | 0 | 0 | 16 | 36 | 0 | 0 | 0 | 0 |
| `top/frame_read_write_m0/read_buf/wr_to_rd_cross_inst` | fifo_cross_domain_addr_process_al_rfifo_32_32_512 | 16 | 0 | 16 | 36 | 0 | 0 | 0 | 0 | 16 | 36 | 0 | 0 | 0 | 0 |
| `top/frame_read_write_m0/write_buf` | wfifo_32_32_512 | 64 | 18 | 82 | 94 | 2 | 0 | 0 | 0 | 50 | 22 | 0 | 0 | 0 | 0 |
| `top/frame_read_write_m0/write_buf/ram_inst` | ram_infer_wfifo_32_32_512 | 0 | 0 | 0 | 0 | 2 | 0 | 0 | 0 | 0 | 0 | 2 | 0 | 0 | 0 |
| `top/frame_read_write_m0/write_buf/rd_to_wr_cross_inst` | fifo_cross_domain_addr_process_al_wfifo_32_32_512 | 16 | 0 | 16 | 36 | 0 | 0 | 0 | 0 | 16 | 36 | 0 | 0 | 0 | 0 |
| `top/frame_read_write_m0/write_buf/wr_to_rd_cross_inst` | fifo_cross_domain_addr_process_al_wfifo_32_32_512 | 16 | 0 | 16 | 36 | 0 | 0 | 0 | 0 | 16 | 36 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0` | sd_media_pipeline | 5309 | 1212 | 6,521 | 4,092 | 5 | 0 | 7 | 5 | 32 | 25 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/rhythm_resources$clear_sync` | domain_reset_sync | 7 | 0 | 7 | 6 | 0 | 0 | 0 | 0 | 7 | 6 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/rhythm_resources$resources` | rhythm_sd_resources | 2271 | 569 | 2,840 | 1,646 | 4 | 0 | 1 | 0 | 43 | 2 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/rhythm_resources$resources/metadata_ram$ram` | rhythm_block_ram | 9 | 0 | 9 | 0 | 0 | 0 | 1 | 0 | 9 | 0 | 0 | 0 | 1 | 0 |
| `top/sd_media_pipeline_m0/rhythm_resources$resources/u_arbiter` | sd_sector_arbiter | 118 | 0 | 118 | 54 | 0 | 0 | 0 | 0 | 118 | 54 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/rhythm_resources$resources/u_buffer` | rhythm_chart_buffer | 49 | 14 | 63 | 65 | 4 | 0 | 0 | 0 | 63 | 65 | 4 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/rhythm_resources$resources/u_chart` | fat32_chart_reader | 876 | 339 | 1,215 | 810 | 0 | 0 | 0 | 0 | 1,215 | 810 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/rhythm_resources$resources/u_wav` | fat32_wav_reader | 1176 | 216 | 1,392 | 715 | 0 | 0 | 0 | 0 | 1,392 | 715 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/source_pixel_fifo` | source_pixel_fifo_ip | 61 | 12 | 73 | 84 | 0 | 0 | 2 | 0 | 1 | 0 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst` | soft_fifo_f9a960ae4922 | 60 | 12 | 72 | 84 | 0 | 0 | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst/al_soft_fifo_ELyPIOfr` | al_soft_fifo_J5Dq79mN_f9a960ae4922 | 40 | 9 | 49 | 31 | 0 | 0 | 0 | 0 | 47 | 29 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst/al_soft_fifo_ELyPIOfr/al_soft_fifo_eSCWbQZ_` | al_soft_fifo_MPXy9iEA_f9a960ae4922 | 2 | 0 | 2 | 2 | 0 | 0 | 0 | 0 | 2 | 2 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst/al_soft_fifo_ktZv2ExW` | al_soft_fifo_CMEB9ZlH_f9a960ae4922 | 2 | 0 | 2 | 25 | 0 | 0 | 2 | 0 | 1 | 25 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst/al_soft_fifo_ktZv2ExW/al_soft_fifo_BpJUKxcz` | al_soft_fifo_EoCVCOi5_f9a960ae4922 | 1 | 0 | 1 | 0 | 0 | 0 | 2 | 0 | 1 | 0 | 0 | 0 | 2 | 0 |
| `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst/al_soft_fifo_pXuL5aOr` | al_soft_fifo_nzFbx5iw_f9a960ae4922 | 18 | 3 | 21 | 28 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst/al_soft_fifo_pXuL5aOr/al_soft_fifo_asSgfuf5` | al_soft_fifo_ZBIjHksb_f9a960ae4922 | 4 | 3 | 7 | 27 | 0 | 0 | 0 | 0 | 7 | 27 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/source_pixel_fifo/soft_fifo_f9a960ae4922_Inst/al_soft_fifo_pXuL5aOr/al_soft_fifo_whu47jXM` | al_soft_fifo_HiHqg1Au_f9a960ae4922 | 14 | 0 | 14 | 1 | 0 | 0 | 0 | 0 | 14 | 1 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/u_bmp_catalog` | fat32_bmp_catalog | 703 | 141 | 844 | 754 | 1 | 0 | 0 | 2 | 841 | 754 | 0 | 0 | 0 | 2 |
| `top/sd_media_pipeline_m0/u_bmp_catalog/descriptor_cache` | rhythm_block_ram | 3 | 0 | 3 | 0 | 1 | 0 | 0 | 0 | 3 | 0 | 1 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/u_bmp_read` | bmp_read | 827 | 238 | 1,065 | 646 | 0 | 0 | 0 | 0 | 1,065 | 646 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/u_reset_local` | domain_reset_sync | 7 | 0 | 7 | 7 | 0 | 0 | 0 | 0 | 7 | 7 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/u_scaler` | bmp_bilinear_scaler | 983 | 177 | 1,160 | 647 | 0 | 0 | 4 | 3 | 1,158 | 647 | 0 | 0 | 0 | 3 |
| `top/sd_media_pipeline_m0/u_scaler/u_line_even` | scaler_linebuf_even_ip | 1 | 0 | 1 | 0 | 0 | 0 | 2 | 0 | 1 | 0 | 0 | 0 | 2 | 0 |
| `top/sd_media_pipeline_m0/u_scaler/u_line_odd` | scaler_linebuf_odd_ip | 1 | 0 | 1 | 0 | 0 | 0 | 2 | 0 | 1 | 0 | 0 | 0 | 2 | 0 |
| `top/sd_media_pipeline_m0/u_sd` | sd_card_top | 255 | 24 | 279 | 180 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/u_sd/sd_card_cmd_m0` | sd_card_cmd | 131 | 19 | 150 | 47 | 0 | 0 | 0 | 0 | 150 | 47 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/u_sd/sd_card_sec_read_write_m0` | sd_card_sec_read_write | 62 | 0 | 62 | 89 | 0 | 0 | 0 | 0 | 62 | 89 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/u_sd/spi_master_m0` | spi_master | 62 | 5 | 67 | 44 | 0 | 0 | 0 | 0 | 67 | 44 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/u_session` | media_session_controller | 172 | 42 | 214 | 97 | 0 | 0 | 0 | 0 | 155 | 74 | 0 | 0 | 0 | 0 |
| `top/sd_media_pipeline_m0/u_session/u_key_next` | media_key_press_debounce | 41 | 18 | 59 | 23 | 0 | 0 | 0 | 0 | 59 | 23 | 0 | 0 | 0 | 0 |
| `top/seg_scan_m0` | seg_scan | 133 | 14 | 147 | 19 | 0 | 0 | 0 | 0 | 147 | 19 | 0 | 0 | 0 | 0 |
| `top/sys_pll_m0` | sys_pll | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `top/u_audio_arc_calculate` | audio_arc_calculate | 43 | 14 | 57 | 47 | 0 | 0 | 0 | 0 | 57 | 47 | 0 | 0 | 0 | 0 |
| `top/u_audio_fft_spectrum` | audio_fft_spectrum | 1596 | 514 | 2,110 | 557 | 4 | 0 | 4 | 5 | 0 | 0 | 0 | 0 | 0 | 0 |
| `top/u_audio_fft_spectrum/g_reference$u_reference` | reference_fft_spectrum | 1596 | 514 | 2,110 | 557 | 4 | 0 | 4 | 5 | 1,989 | 557 | 3 | 0 | 0 | 5 |
| `top/u_audio_fft_spectrum/g_reference$u_reference/block_bars$cache` | rhythm_block_ram | 2 | 0 | 2 | 0 | 1 | 0 | 0 | 0 | 2 | 0 | 1 | 0 | 0 | 0 |
| `top/u_audio_fft_spectrum/g_reference$u_reference/u_bank0` | fft_spectrum_bank_ram | 73 | 0 | 73 | 0 | 0 | 0 | 2 | 0 | 73 | 0 | 0 | 0 | 2 | 0 |
| `top/u_audio_fft_spectrum/g_reference$u_reference/u_bank1` | fft_spectrum_bank_ram | 46 | 0 | 46 | 0 | 0 | 0 | 2 | 0 | 46 | 0 | 0 | 0 | 2 | 0 |
| `top/u_audio_fifo` | audio_fifo_32x4096 | 1 | 0 | 1 | 0 | 0 | 16 | 0 | 0 | 1 | 0 | 0 | 16 | 0 | 0 |
| `top/u_frame_read_monitor` | frame_read_monitor | 15 | 5 | 20 | 18 | 0 | 0 | 0 | 0 | 20 | 18 | 0 | 0 | 0 | 0 |
| `top/u_game_engine` | rhythm_game_engine | 828 | 244 | 1,072 | 632 | 2 | 0 | 0 | 1 | 2 | 2 | 0 | 0 | 0 | 0 |
| `top/u_game_engine/auto_input` | rhythm_auto_input | 51 | 18 | 69 | 47 | 0 | 0 | 0 | 0 | 69 | 47 | 0 | 0 | 0 | 0 |
| `top/u_game_engine/judge` | rhythm_judge_core | 775 | 226 | 1,001 | 583 | 2 | 0 | 0 | 1 | 990 | 583 | 0 | 0 | 0 | 1 |
| `top/u_game_engine/judge/block_queue$judge_ram` | rhythm_block_ram | 6 | 0 | 6 | 0 | 1 | 0 | 0 | 0 | 6 | 0 | 1 | 0 | 0 | 0 |
| `top/u_game_engine/judge/block_queue$view_ram` | rhythm_block_ram | 5 | 0 | 5 | 0 | 1 | 0 | 0 | 0 | 5 | 0 | 1 | 0 | 0 | 0 |
| `top/u_game_renderer` | rhythm_game_renderer | 1412 | 386 | 1,798 | 473 | 5 | 0 | 0 | 2 | 1,084 | 324 | 0 | 0 | 0 | 2 |
| `top/u_game_renderer/block_geometry$ram` | rhythm_block_ram | 24 | 0 | 24 | 0 | 2 | 0 | 0 | 0 | 24 | 0 | 2 | 0 | 0 | 0 |
| `top/u_game_renderer/font` | rhythm_font | 12 | 10 | 22 | 1 | 1 | 0 | 0 | 0 | 22 | 1 | 1 | 0 | 0 | 0 |
| `top/u_game_renderer/hud` | rhythm_hud | 569 | 99 | 668 | 148 | 2 | 0 | 0 | 0 | 470 | 76 | 1 | 0 | 0 | 0 |
| `top/u_game_renderer/hud/block_characters$ram` | rhythm_block_ram | 198 | 0 | 198 | 72 | 1 | 0 | 0 | 0 | 198 | 72 | 1 | 0 | 0 | 0 |
| `top/u_game_session` | rhythm_session_controller | 514 | 147 | 661 | 477 | 0 | 0 | 0 | 0 | 398 | 367 | 0 | 0 | 0 | 0 |
| `top/u_game_session/gsw` | audio_control_debounce | 36 | 16 | 52 | 22 | 0 | 0 | 0 | 0 | 52 | 22 | 0 | 0 | 0 | 0 |
| `top/u_game_session/key2` | audio_control_debounce | 37 | 16 | 53 | 23 | 0 | 0 | 0 | 0 | 53 | 23 | 0 | 0 | 0 | 0 |
| `top/u_game_session/key3` | audio_control_debounce | 37 | 16 | 53 | 22 | 0 | 0 | 0 | 0 | 53 | 22 | 0 | 0 | 0 | 0 |
| `top/u_game_session/key4` | audio_control_debounce | 37 | 16 | 53 | 22 | 0 | 0 | 0 | 0 | 53 | 22 | 0 | 0 | 0 | 0 |
| `top/u_game_session/rsw` | audio_control_debounce | 36 | 16 | 52 | 21 | 0 | 0 | 0 | 0 | 52 | 21 | 0 | 0 | 0 | 0 |
| `top/u_hdmi2phy_wrapper` | hdmi_phy_wrapper | 34 | 0 | 34 | 47 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `top/u_hdmi2phy_wrapper/u0_lane_lvds_8_1` | lane_lvds_10_1 | 12 | 0 | 12 | 18 | 0 | 0 | 0 | 0 | 12 | 18 | 0 | 0 | 0 | 0 |
| `top/u_hdmi2phy_wrapper/u1_lane_lvds_8_1` | lane_lvds_10_1 | 10 | 0 | 10 | 12 | 0 | 0 | 0 | 0 | 10 | 12 | 0 | 0 | 0 | 0 |
| `top/u_hdmi2phy_wrapper/u2_lane_lvds_8_1` | lane_lvds_10_1 | 10 | 0 | 10 | 12 | 0 | 0 | 0 | 0 | 10 | 12 | 0 | 0 | 0 | 0 |
| `top/u_hdmi2phy_wrapper/u3_lane_lvds_8_1` | lane_lvds_10_1 | 2 | 0 | 2 | 5 | 0 | 0 | 0 | 0 | 2 | 5 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper` | hdmi_1_4b_transmitter_core_wrapper | 1386 | 219 | 1,605 | 1,573 | 16 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u0_reset_sync` | hdmi_1_4b_tx_reset_sync | 0 | 0 | 0 | 2 | 0 | 0 | 0 | 0 | 0 | 2 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_edid_wrapper` | hdmi_edid_wrapper | 206 | 21 | 227 | 155 | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_edid_wrapper/u_hdmi_edid_read_controller` | hdmi_edid_read_controller | 7 | 3 | 10 | 11 | 0 | 0 | 0 | 0 | 10 | 11 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_edid_wrapper/u_iic_master_wrapper` | iic_master_wrapper | 199 | 18 | 217 | 144 | 2 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_edid_wrapper/u_iic_master_wrapper/u_iic_bit_transmitter` | iic_bit_transmitter | 69 | 8 | 77 | 31 | 0 | 0 | 0 | 0 | 77 | 31 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_edid_wrapper/u_iic_master_wrapper/u_iic_transmitter_controller` | iic_transmitter_controller | 130 | 10 | 140 | 113 | 2 | 0 | 0 | 0 | 112 | 58 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_edid_wrapper/u_iic_master_wrapper/u_iic_transmitter_controller/u_iic_w11_d1024_fifo` | iic_w11_d1024_fifo | 28 | 0 | 28 | 55 | 2 | 0 | 0 | 0 | 28 | 55 | 2 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper` | hdmi_tx_controller_wrapper | 1180 | 198 | 1,378 | 1,416 | 14 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u0_hdmi_tmds_encode` | hdmi_tmds_encode | 132 | 30 | 162 | 160 | 0 | 0 | 0 | 0 | 162 | 160 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u1_hdmi_tmds_encode` | hdmi_tmds_encode | 129 | 30 | 159 | 108 | 0 | 0 | 0 | 0 | 159 | 108 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u2_hdmi_tmds_encode` | hdmi_tmds_encode | 127 | 30 | 157 | 108 | 0 | 0 | 0 | 0 | 157 | 108 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_data_distribution` | hdmi_data_distribution | 2 | 0 | 2 | 43 | 0 | 0 | 0 | 0 | 2 | 43 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_assemble` | hdmi_island_data_assemble | 277 | 0 | 277 | 418 | 0 | 0 | 0 | 0 | 277 | 418 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen` | hdmi_island_data_gen | 327 | 3 | 330 | 422 | 11 | 0 | 0 | 0 | 161 | 140 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/U_audio_sample_packet_2_channel` | audio_sample_packet_2_channel | 139 | 3 | 142 | 219 | 11 | 0 | 0 | 0 | 118 | 155 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/U_audio_sample_packet_2_channel/u_w96_d1024_fifo` | w96_d1024_fifo | 24 | 0 | 24 | 55 | 11 | 0 | 0 | 0 | 24 | 55 | 11 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/U_audio_sample_packet_2_channel/u_BCH_32_24_encode` | BCH_32_24_encode | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/U_audio_sample_packet_2_channel/u_BCH_64_56_encode` | BCH_64_56_encode | 0 | 0 | 0 | 8 | 0 | 0 | 0 | 0 | 0 | 8 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/u_audio_clock_regeneration_packet` | audio_clock_regeneration_packet | 27 | 0 | 27 | 63 | 0 | 0 | 0 | 0 | 27 | 55 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/u_audio_clock_regeneration_packet/u_BCH_64_56_encode` | BCH_64_56_encode | 0 | 0 | 0 | 8 | 0 | 0 | 0 | 0 | 0 | 8 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_video_data_assemble` | hdmi_video_data_assemble | 0 | 0 | 0 | 40 | 0 | 0 | 0 | 0 | 0 | 40 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_video_source` | hdmi_video_source | 129 | 95 | 224 | 38 | 0 | 0 | 0 | 0 | 224 | 38 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_video_axi_stream_receiver` | video_axi_stream_receiver | 57 | 10 | 67 | 79 | 3 | 0 | 0 | 0 | 17 | 3 | 0 | 0 | 0 | 0 |
| `top/u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_video_axi_stream_receiver/u_w24_d1024_fifo` | w24_d1024_fifo | 47 | 3 | 50 | 76 | 3 | 0 | 0 | 0 | 50 | 76 | 3 | 0 | 0 | 0 |
| `top/u_image_controls` | image_controls | 133 | 60 | 193 | 70 | 0 | 0 | 0 | 0 | 81 | 26 | 0 | 0 | 0 | 0 |
| `top/u_image_controls/u_dec` | media_key_press_debounce | 39 | 17 | 56 | 22 | 0 | 0 | 0 | 0 | 56 | 22 | 0 | 0 | 0 | 0 |
| `top/u_image_controls/u_inc` | media_key_press_debounce | 39 | 17 | 56 | 22 | 0 | 0 | 0 | 0 | 56 | 22 | 0 | 0 | 0 | 0 |
| `top/u_pcm_audio_player` | pcm_audio_player | 369 | 98 | 467 | 171 | 0 | 0 | 0 | 0 | 467 | 171 | 0 | 0 | 0 | 0 |
| `top/u_reset_clk` | domain_reset_sync | 10 | 3 | 13 | 13 | 0 | 0 | 0 | 0 | 13 | 13 | 0 | 0 | 0 | 0 |
| `top/u_reset_mem` | domain_reset_sync | 9 | 3 | 12 | 13 | 0 | 0 | 0 | 0 | 12 | 13 | 0 | 0 | 0 | 0 |
| `top/u_reset_sd` | domain_reset_sync | 9 | 3 | 12 | 13 | 0 | 0 | 0 | 0 | 12 | 13 | 0 | 0 | 0 | 0 |
| `top/u_reset_video` | domain_reset_sync | 9 | 3 | 12 | 13 | 0 | 0 | 0 | 0 | 12 | 13 | 0 | 0 | 0 | 0 |
| `top/u_sdram_refresh_scheduler` | sdram_refresh_scheduler | 67 | 26 | 93 | 33 | 0 | 0 | 0 | 0 | 93 | 33 | 0 | 0 | 0 | 0 |
| `top/u_startup_pulse` | startup_pulse | 21 | 6 | 27 | 22 | 0 | 0 | 0 | 0 | 27 | 22 | 0 | 0 | 0 | 0 |
| `top/u_touch_frame_snapshot` | touch_frame_snapshot | 6 | 0 | 6 | 49 | 0 | 0 | 0 | 0 | 6 | 49 | 0 | 0 | 0 | 0 |
| `top/u_touch_input` | ch9350_touch_input | 478 | 60 | 538 | 368 | 0 | 0 | 0 | 4 | 29 | 22 | 0 | 0 | 0 | 0 |
| `top/u_touch_input/u_ack_tx` | uart_byte_tx | 33 | 3 | 36 | 22 | 0 | 0 | 0 | 0 | 36 | 22 | 0 | 0 | 0 | 0 |
| `top/u_touch_input/u_parser` | ch9350_touch_parser | 361 | 49 | 410 | 288 | 0 | 0 | 0 | 4 | 410 | 288 | 0 | 0 | 0 | 0 |
| `top/u_touch_input/u_parser/u_checksum_increment` | touch_counter_increment | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 1 |
| `top/u_touch_input/u_parser/u_format_increment` | touch_counter_increment | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 1 |
| `top/u_touch_input/u_parser/u_gap_increment` | touch_counter_increment | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 1 |
| `top/u_touch_input/u_parser/u_good_increment` | touch_counter_increment | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 1 |
| `top/u_touch_input/u_rx` | uart_byte_rx | 60 | 3 | 63 | 36 | 0 | 0 | 0 | 0 | 63 | 36 | 0 | 0 | 0 | 0 |
| `top/u_touch_mapper` | touch_pixel_mapper | 115 | 20 | 135 | 59 | 0 | 0 | 0 | 1 | 135 | 59 | 0 | 0 | 0 | 1 |
| `top/u_touch_monitor` | touch_serial_monitor | 448 | 32 | 480 | 162 | 5 | 0 | 0 | 0 | 384 | 139 | 5 | 0 | 0 | 0 |
| `top/u_touch_monitor/u_tx` | uart_byte_tx | 93 | 3 | 96 | 23 | 0 | 0 | 0 | 0 | 96 | 23 | 0 | 0 | 0 | 0 |
| `top/u_uart_command_control` | uart_command_control | 81 | 3 | 84 | 54 | 0 | 0 | 0 | 0 | 84 | 54 | 0 | 0 | 0 | 0 |
| `top/u_video_presentation` | video_presentation | 1085 | 405 | 1,490 | 238 | 0 | 0 | 0 | 11 | 741 | 174 | 0 | 0 | 0 | 3 |
| `top/u_video_presentation/g_touch_markers$u_marker` | touch_marker | 40 | 40 | 80 | 0 | 0 | 0 | 0 | 0 | 80 | 0 | 0 | 0 | 0 | 0 |
| `top/u_video_presentation/u_ring_spectrum_renderer` | ring_spectrum_renderer | 457 | 212 | 669 | 64 | 0 | 0 | 0 | 8 | 669 | 64 | 0 | 0 | 0 | 8 |
| `top/u_video_rgb_to_axis_640x480` | video_rgb_to_axis_640x480 | 20 | 3 | 23 | 40 | 0 | 0 | 0 | 0 | 23 | 40 | 0 | 0 | 0 | 0 |
| `top/video_delay_m0` | video_delay | 24 | 0 | 24 | 66 | 0 | 0 | 0 | 0 | 24 | 66 | 0 | 0 | 0 | 0 |
| `top/video_pll_m0` | video_pll | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| `top/video_timing_data_m0` | video_timing_data | 34 | 8 | 42 | 33 | 0 | 0 | 0 | 0 | 1 | 5 | 0 | 0 | 0 | 0 |
| `top/video_timing_data_m0/color_bar_m0` | color_bar | 33 | 8 | 41 | 28 | 0 | 0 | 0 | 0 | 41 | 28 | 0 | 0 | 0 | 0 |

## 核对结果

- 133 行全部归属到功能链，无遗漏、无重叠。
- 每一层 BRAM9K + FIFO9K + BRAM32K 等于该层原始 bram 计数；DSP 等于该层物理 MULT18 实例数。
- 功能链合计及所有节点本体合计均与 top 层次值相同。
- 合计存储 41 + 16 + 11 = 68；9K/FIFO9K 为 57。
- 本报告是资源归属诊断；不将综合资源统计视为物理打包、时序或上板验证。
