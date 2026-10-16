"""会话复位毛刺回归：非零计分、真实 SD/PCM，以及状态译码输入传播延迟反例。"""
import argparse
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', default='prj/log/session_reset_regression_20261016')
parser.add_argument('--variants', nargs='+', choices=['fixed', 'fixed_skew', 'baseline_skew', 'physical'],
                    default=['fixed', 'fixed_skew', 'baseline_skew', 'physical'])
args = parser.parse_args()
out = root / args.output
out.mkdir(parents=True, exist_ok=True)
bin_dir = Path('E:/altera/modelsim_ase/win32aloem')

def run(name, command, expected=None):
    with (out / (name + '.log')).open('wb') as log:
        result = subprocess.run(command, cwd=out, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    content = (out / (name + '.log')).read_text(errors='replace')
    if expected:
        if expected not in content or '** Fatal:' not in content:
            raise RuntimeError('counterexample not detected: ' + name + '\n' + content[-1800:])
        print('PASS expected rejection: ' + name, flush=True)
    else:
        if result.returncode or re.search(r'\*\* (?:Error|Fatal):|Errors: [1-9]|\bFAIL\b', content):
            raise RuntimeError(name + '\n' + content[-1800:])
        if name.startswith('sim_') and 'PASS' not in content:
            raise RuntimeError(name + ': missing PASS')
        print(name + ': ' + '; '.join(line for line in content.splitlines() if 'PASS' in line or 'Errors:' in line), flush=True)

modules = ['pcm_audio_player', 'rhythm_game_engine', 'rhythm_judge_core', 'rhythm_auto_input',
           'media_session_controller', 'image_info_osd', 'image_osd_font', 'video_presentation',
           'ring_spectrum_renderer', 'rhythm_game_renderer', 'rhythm_block_ram', 'rhythm_font',
           'rhythm_hud', 'domain_reset_sync', 'fat32_wav_reader', 'sd_sector_arbiter',
           'fat32_chart_reader', 'rhythm_chart_buffer', 'rhythm_sd_resources']
baseline = subprocess.check_output(['git', 'show', '240375a:src/rhythm_session_controller.v'], cwd=root).decode('utf-8')
fixed = (root / 'src/rhythm_session_controller.v').read_text(encoding='utf-8')

def with_decode_skew(source):
    # 只在测试副本里延迟复位译码的输入，状态机自身及所有握手仍使用真实 state。
    # state[2]/[3] 延迟来自缺陷版 GUI 布线的 clock-to-Q + 网络，不声称完整 SDF 回标。
    skew = '''    wire [3:0] reset_state;
    assign #0.500 reset_state[0]=state[0];
    assign #0.500 reset_state[1]=state[1];
    assign #0.872 reset_state[2]=state[2];
    assign #1.453 reset_state[3]=state[3];
'''
    source = source.replace('    assign freeze_media=', skew + '    assign freeze_media=', 1)
    if 'always @(negedge clk or posedge rst)' in source:
        start = source.index('    always @(negedge clk or posedge rst)')
        end = source.index('    assign engine_load=', start)
        source = source[:start] + re.sub(r'\bstate\b', 'reset_state', source[start:end]) + source[end:]
    else:
        source = re.sub(r'(?m)^    assign (?:engine_reset|resource_reset)=.*$',
                        lambda m: re.sub(r'\bstate\b', 'reset_state', m[0]), source)
    return source

for variant, source in [('fixed', fixed), ('fixed_skew', with_decode_skew(fixed)),
                        ('baseline_skew', with_decode_skew(baseline)), ('physical', fixed)]:
    if variant not in args.variants:
        continue
    lib = str(out / variant)
    if not Path(lib).exists():
        run('library_' + variant, [str(bin_dir / 'vlib.exe'), lib])
    controller = out / (variant + '_session.v')
    controller.write_text(source, encoding='utf-8')
    physical_sources = ['E:/AnLuTD/sim_release/eg4/' + name + '.v' for name in
                        ['eg_phy_fifo', 'eg_phy_config', 'eg_phy_glbl']] + [str(root / 'prj/al_ip/audio_fifo_32x4096_sim.v')]
    run('compile_' + variant, [str(bin_dir / 'vlog.exe'), '-work', lib,
        'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v', 'E:/AnLuTD/sim_release/eg4/eg_logic_mult.v',
        *(physical_sources if variant == 'physical' else []),
        *[str(root / 'src' / (name + '.v')) for name in modules], str(controller),
        str(root / 'src/test/tb_game_background_playback.v'), str(root / 'src/test/tb_rhythm_session.v'),
        str(root / 'src/test/tb_rhythm_session_reset_phase.v')])
    for case in [1, 2, 3]:
        run('sim_' + variant + '_case' + str(case), [str(bin_dir / 'vsim.exe'), '-c', '-lib', lib,
            'tb_game_background_playback', '-gSCORE_END_CASE=' + str(case),
            *(['glbl', '-gPHYSICAL_AUDIO_FIFO=1'] if variant == 'physical' else []),
            '-do', str(root / 'src/test/run_pcm_audio_player.do')],
            'unexpected session reset after scoring' if variant == 'baseline_skew' else None)
    if variant == 'fixed':
        run('sim_session_controls', [str(bin_dir / 'vsim.exe'), '-c', '-lib', lib, 'tb_rhythm_session',
                                    '-do', str(root / 'src/test/run_pcm_audio_player.do')])
        run('sim_reset_phase', [str(bin_dir / 'vsim.exe'), '-c', '-lib', lib, 'tb_rhythm_session_reset_phase',
                               '-do', str(root / 'src/test/run_pcm_audio_player.do')])
