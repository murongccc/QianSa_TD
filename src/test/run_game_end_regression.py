"""游戏收尾：真实触摸 CDC/窄队列/DSP/会话闭环，含旧版反例和运行中溢出保护。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', default='prj/log/game_end_regression_20261016')
args = parser.parse_args()
out = root / args.output
out.mkdir(parents=True, exist_ok=True)
library = str(out / 'work')

def run(name, command, expect_failure=None):
    with (out / (name + '.log')).open('wb') as log:
        # 全分辨率扫描复位用例检查九个完整帧场景，沿用原视频回归的 600 秒上限。
        timeout = 600 if name == 'tb_rhythm_renderer_session_reset' else 180
        result = subprocess.run(command, cwd=out, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    text = (out / (name + '.log')).read_text(errors='replace')
    if expect_failure:
        if expect_failure not in text or '** Fatal:' not in text:
            raise RuntimeError('old design was not rejected: ' + name + '\n' + text[-1400:])
        print('PASS expected rejection: ' + name + ' (' + expect_failure + ')', flush=True)
        return
    if result.returncode or re.search(r'\*\* (?:Error|Fatal):|Errors: [1-9]|\bFAIL\b', text):
        raise RuntimeError(name + '\n' + text[-1600:])
    if name not in ['library', 'compile'] and 'PASS' not in text:
        raise RuntimeError(name + ': no PASS assertion')
    print(name + ': ' + '; '.join(line for line in text.splitlines() if 'PASS' in line or 'Errors:' in line), flush=True)

reference = subprocess.check_output(['git', 'show', 'f4fd3fa:src/rhythm_game_engine.v'], cwd=root).decode('utf-8')
reference = re.sub(r'\brhythm_game_engine\b', 'baseline_rhythm_game_engine', reference)
reference_path = out / 'baseline_rhythm_game_engine.v'
reference_path.write_text(reference, encoding='utf-8')
if not Path(library).exists():
    run('library', [shutil.which('vlib'), library])
modules = ['rhythm_block_ram', 'rhythm_judge_core', 'rhythm_auto_input', 'rhythm_game_engine',
           'rhythm_session_controller', 'touch_game_event_bridge', 'rhythm_font', 'rhythm_hud', 'rhythm_game_renderer',
           'video_presentation', 'ring_spectrum_renderer', 'image_info_osd', 'image_osd_font', 'touch_marker']
existing_tests = ['tb_touch_game_event_bridge', 'tb_rhythm_session', 'tb_rhythm_judge_core',
                  'tb_rhythm_packed_queue', 'tb_rhythm_renderer_session_reset']
run('compile', [shutil.which('vlog'), '-work', library,
    'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v', str(root / 'src/test/eg_logic_mult_model.v'),
    str(root / 'src/SD/color_bar.v'),
    *[str(root / 'src' / (name + '.v')) for name in modules], str(reference_path),
    str(root / 'src/test/tb_rhythm_end_retirement.v'),
    *[str(root / 'src/test' / (name + '.v')) for name in existing_tests]])

def simulate(name, test, parameters=(), expect_failure=None):
    run(name, [shutil.which('vsim'), '-c', '-lib', library, test, *parameters,
               '-do', str(root / 'src/test/run_pcm_audio_player.do')], expect_failure)

simulate('old_engine_rejected', 'tb_rhythm_end_retirement', ['-gBASELINE_ENGINE=1'], 'terminal drain blocked during capture')
simulate('old_enable_rejected', 'tb_rhythm_end_retirement', ['-gKEEP_INPUT_AFTER_DONE=1'], 'touch source did not retire')
for name, parameters in [
    ('last_tap', []), ('last_hold', ['-gLAST_KIND=1']), ('last_miss', ['-gLAST_KIND=2']),
    ('last_tap_in_tail', ['-gEND_IN_TAIL=1']), ('late_chart_eof', ['-gLATE_EOF=1']),
    ('last_miss_in_tail', ['-gEND_IN_TAIL=1', '-gLAST_KIND=2', '-gTAIL_SAMPLES=7200']),
    ('phase_aligned', ['-gPHASE=0']), ('phase_slow', ['-gPHASE=31', '-gHALF=23']),
    ('phase_fast', ['-gPHASE=1', '-gHALF=11'])]:
    simulate(name, 'tb_rhythm_end_retirement', parameters)
for test in existing_tests:
    simulate(test, test)
simulate('judge_block_queue', 'tb_rhythm_judge_core', ['-gBLOCK_QUEUE=1'])
