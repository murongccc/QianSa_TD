"""启动相关时序修复回归；以修改前提交为对照，不生成位流。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', default='prj/log/startup_timing_regression_20261016')
parser.add_argument('--baseline-ref', default='2fcd138')
args = parser.parse_args()
out = root / args.output
out.mkdir(parents=True, exist_ok=True)
library = str(out / 'work')

def run(name, command, expect_pass=False):
    with (out / (name + '.log')).open('wb') as log:
        result = subprocess.run(command, cwd=out, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    text = (out / (name + '.log')).read_text(errors='replace')
    if result.returncode or re.search(r'\*\* (?:Error|Fatal):|Errors: [1-9]|\bFAIL\b', text) or (expect_pass and 'PASS' not in text):
        raise RuntimeError(name + '\n' + '\n'.join(text.splitlines()[-16:]))
    print(name + ': ' + '; '.join(line for line in text.splitlines() if 'PASS' in line or 'Errors:' in line), flush=True)

references = []
for path, module in [('src/rhythm_chart_buffer.v', 'rhythm_chart_buffer')]:
    text = subprocess.check_output(['git', 'show', args.baseline_ref + ':' + path], cwd=root).decode('utf-8')
    text = re.search(r'\bmodule ' + module + r'\b.*?\bendmodule', text, re.S)[0]
    text = re.sub(r'\b' + module + r'\b', 'baseline_' + module, text)
    target = out / ('baseline_' + module + '.v')
    target.write_text(text, encoding='utf-8')
    references.append(str(target))

if not Path(library).exists():
    run('library', [shutil.which('vlib'), library])
sources = ['domain_reset_sync', 'rhythm_chart_buffer', 'rhythm_session_controller', 'frame_read_monitor']
tests = ['tb_timing_startup_fix', 'tb_domain_reset_sync', 'tb_rhythm_session', 'tb_frame_diagnostic_pages']
run('compile', [shutil.which('vlog'), '-work', library,
                *[str(root / 'src' / (name + '.v')) for name in sources], *references,
                *[str(root / 'src/test' / (name + '.v')) for name in tests]])
for test in ['tb_chart_buffer_timing', 'tb_domain_reset_sync', 'tb_rhythm_session', 'tb_frame_diagnostic_pages']:
    run(test, [shutil.which('vsim'), '-c', '-lib', library, test,
               '-do', str(root / 'src/test/run_pcm_audio_player.do')], True)

# 公共复位与谱面 FIFO 同时用于媒体外壳和游戏闭环，覆盖两种实际接法。
modules = ['pcm_audio_player', 'rhythm_game_engine', 'rhythm_judge_core', 'rhythm_auto_input',
           'rhythm_session_controller', 'media_session_controller', 'image_info_metadata',
           'image_info_osd', 'image_osd_font', 'video_presentation', 'ring_spectrum_renderer',
           'rhythm_game_renderer', 'rhythm_block_ram', 'rhythm_font', 'rhythm_hud',
           'domain_reset_sync', 'fat32_bmp_catalog', 'fat32_wav_reader', 'sd_sector_arbiter',
           'sd_media_pipeline', 'fat32_chart_reader', 'rhythm_chart_buffer', 'rhythm_sd_resources']
integration_tests = ['tb_game_background_playback', 'tb_sd_media_scaler_commit', 'tb_rhythm_sd_resources']
run('integration_compile', [shutil.which('vlog'), '-work', library, '+define+MEDIA_STARTUP_MODEL',
    'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v', 'E:/AnLuTD/sim_release/eg4/eg_logic_ramfifo.v',
    str(root / 'src/test/eg_logic_mult_model.v'), str(root / 'src/SD/bmp_bilinear_scaler.v'),
    str(root / 'src/SD/bmp_read.v'),
    str(root / 'prj/al_ip/source_pixel_fifo_ip/RTL/soft_fifo_f9a960ae4922.v'),
    str(root / 'prj/al_ip/source_pixel_fifo_ip/source_pixel_fifo_ip.v'),
    *[str(root / 'src' / (name + '.v')) for name in modules],
    *[str(root / 'src/test' / (name + '.v')) for name in integration_tests]])
for name, test, parameters in [
    ('game_playback', 'tb_game_background_playback', []),
    ('media_pipeline', 'tb_sd_media_scaler_commit', []),
    ('rhythm_pipeline', 'tb_sd_media_scaler_commit', ['-gRHYTHM=1']),
    ('sd_resources', 'tb_rhythm_sd_resources', [])]:
    run(name, [shutil.which('vsim'), '-c', '-lib', library, test, *parameters,
               '-do', str(root / 'src/test/run_pcm_audio_player.do')], True)
