"""游戏背景提亮、冻结时SW2轮播及原媒体/视频回归；不运行物理实现。"""
from pathlib import Path
import argparse,re,shutil,subprocess
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--case",action="append");args=parser.parse_args()
root=Path(__file__).resolve().parents[2];out=root/'prj/log/game_background_20261014';out.mkdir(parents=True,exist_ok=True)
def run(name,command,passed=False):
 with (out/(name+'.log')).open('wb') as log:r=subprocess.run(command,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=600)
 text=(out/(name+'.log')).read_text(errors='replace')
 if r.returncode or re.search(r'\*\* (?:Error|Fatal):|Errors: [1-9]|\bFAIL\b',text) or passed and 'PASS' not in text:
  raise RuntimeError(name+'\n'+'\n'.join(text.splitlines()[-14:]))
 print(name+': '+'; '.join(l for l in text.splitlines() if 'PASS' in l or 'Errors:' in l),flush=True)
lib=str(out/'work')
if not Path(lib).exists():run('library',[shutil.which('vlib'),lib])
modules=['pcm_audio_player','rhythm_game_engine','rhythm_judge_core','rhythm_auto_input','rhythm_session_controller','media_session_controller','video_presentation','ring_spectrum_renderer','rhythm_game_renderer','rhythm_block_ram','rhythm_font','rhythm_hud','domain_reset_sync','fat32_bmp_catalog','fat32_wav_reader','sd_sector_arbiter','sd_media_pipeline','fat32_chart_reader','rhythm_chart_buffer','rhythm_sd_resources']
cases=['tb_game_background_playback','tb_game_background_carousel','tb_media_session_controller','tb_rhythm_media_freeze','tb_rhythm_background_mode','tb_video_glow_blend','tb_video_game_spectrum','tb_hold_glow_fix','tb_rhythm_renderer_session_reset','tb_video_presentation','tb_video_presentation_startup','tb_sd_media_scaler_commit']
run('compile',[shutil.which('vlog'),'-work',lib,'+define+MEDIA_STARTUP_MODEL','E:/AnLuTD/sim_release/eg4/eg_logic_bram.v','E:/AnLuTD/sim_release/eg4/eg_logic_ramfifo.v','src/test/eg_logic_mult_model.v','src/SD/color_bar.v','src/SD/bmp_bilinear_scaler.v','src/SD/bmp_read.v','prj/al_ip/source_pixel_fifo_ip/RTL/soft_fifo_f9a960ae4922.v','prj/al_ip/source_pixel_fifo_ip/source_pixel_fifo_ip.v',*[str(root/'src'/(n+'.v')) for n in modules],*[str(root/'src/test'/(n+'.v')) for n in cases]])
for c in [n for n in cases if not args.case or n in args.case]:run(c,[shutil.which('vsim'),'-c','-lib',lib,c,'-do','src/test/run_startup_regression.do'],True)
if not args.case or 'rhythm_pipeline' in args.case:run('rhythm_pipeline',[shutil.which('vsim'),'-c','-lib',lib,'tb_sd_media_scaler_commit','-gRHYTHM=1','-do','src/test/run_startup_regression.do'],True)
print('PASS game background regression')
