"""游戏与频谱布局局部回归；只运行ModelSim，不布局布线。"""
from pathlib import Path
import argparse
import re
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--case', action='append', help='only run the named test or variant; repeat for several cases')
args = parser.parse_args()
out = root / 'prj/log/game_spectrum_20261013'
out.mkdir(parents=True, exist_ok=True)
for name in ['rhythm_note_style_20261006', 'touch_glow_20261012', 'hold_glow_fix_20261012']:
    (root/'prj/log'/name).mkdir(parents=True, exist_ok=True)

def run(name, command, passed=False):
    log = out/(name+'.log')
    with log.open('wb') as stream:
        result = subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT, timeout=300)
    text = log.read_text(errors='replace')
    if result.returncode or re.search(r'\*\* (?:Fatal|Error):|Errors: [1-9]', text) or (passed and 'PASS' not in text):
        raise RuntimeError(name+' failed\n'+'\n'.join(text.splitlines()[-15:]))
    print('\n'.join(line for line in text.splitlines() if 'PASS' in line or 'Errors:' in line), flush=True)

# 固定修改前提交，避免后续提交后HEAD变成被测实现。
baseline = subprocess.check_output(['git', 'show', '5717585:src/ring_spectrum_renderer.v'], cwd=root).decode('utf-8')
baseline = re.sub(r'\bring_spectrum_renderer\b', 'baseline_ring_spectrum_renderer', baseline)
reference = out/'baseline_ring_spectrum_renderer.v'
reference.write_text(baseline, encoding='utf-8')
library = str(out/'work')
if not Path(library).exists():
    run('library', [shutil.which('vlib'), library])
modules = ['rhythm_game_renderer', 'rhythm_block_ram', 'rhythm_font', 'rhythm_hud',
           'ring_spectrum_renderer', 'image_info_metadata','image_info_osd','image_osd_font','video_presentation']
tests = ['tb_ring_spectrum_renderer', 'tb_game_ring_layout', 'tb_video_game_spectrum', 'tb_rhythm_note_style',
         'tb_touch_lane_glow', 'tb_hold_glow_fix', 'tb_video_glow_blend', 'tb_reference_ring',
         'tb_video_presentation', 'tb_video_presentation_startup', 'tb_rhythm_scroll_speed',
         'tb_rhythm_renderer', 'tb_rhythm_renderer_session_reset', 'tb_compact_progress']
run('compile', [shutil.which('vlog'), '-work', library, 'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v',
                'src/test/eg_logic_mult_model.v', 'src/SD/color_bar.v', str(reference),
                *[f'src/{name}.v' for name in modules], *[f'src/test/{name}.v' for name in tests]])
for name in tests:
    if args.case and name not in args.case:
        continue
    run(name, [shutil.which('vsim'), '-c', '-lib', library, name, '-do', 'src/test/run_pcm_audio_player.do'], True)
for label, name, params in [
    ('ring_wide', 'tb_game_ring_layout', ['-gBLOCK_BARS=0']),
    ('notes_distributed', 'tb_rhythm_note_style', ['-gBLOCK_GEOMETRY=0']),
    ('notes_original', 'tb_rhythm_note_style', ['-gCOMPACT_LAYOUT=0']),
    ('progress_lut', 'tb_compact_progress', ['-gBLOCK_HUD=0']),
    ('reference_video', 'tb_video_presentation', ['-gREFERENCE_SPECTRUM=1'])]:
    if args.case and label not in args.case:
        continue
    run(label, [shutil.which('vsim'), '-c', '-lib', library, name, *params,
                '-do', 'src/test/run_pcm_audio_player.do'], True)
print(f'PASS game spectrum regression; logs: {out}', flush=True)
