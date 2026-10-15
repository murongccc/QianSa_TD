"""帧诊断 RAM 基线迁移回归；历史参考固定为诊断恢复提交，不生成位流。"""
from pathlib import Path
import re
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
out = root / 'prj/log/video_diagnostics_ram_regression_20261015'
out.mkdir(parents=True, exist_ok=True)
library = str(out / 'work')

def run(name, command, require_pass=False):
    result = subprocess.run(command, cwd=root, capture_output=True, timeout=180)
    output = (result.stdout + result.stderr).decode(errors='replace')
    (out / (name + '.log')).write_text(output, encoding='utf-8')
    if result.returncode or re.search(r'\*\* (?:Error|Fatal):|Errors: [1-9]|\bFAIL\b', output) or (require_pass and 'PASS' not in output):
        raise RuntimeError(name + '\n' + '\n'.join(output.splitlines()[-15:]))
    print(name + ': ' + '; '.join(line for line in output.splitlines() if 'PASS' in line or 'Errors:' in line), flush=True)

baseline = subprocess.check_output(['git', 'show', '8e3dd70:src/frame_read_monitor.v'], cwd=root).decode('utf-8')
baseline = re.sub(r'\bframe_read_monitor\b', 'baseline_frame_read_monitor', baseline)
reference = out / 'baseline_frame_read_monitor.v'
reference.write_text(baseline, encoding='utf-8')
if not Path(library).exists():
    run('vlib', [shutil.which('vlib'), library])
cases = ['tb_frame_read_monitor', 'tb_frame_signature_switch', 'tb_frame_monitor_ram_equivalence',
         'tb_frame_diagnostic_sampler', 'tb_frame_diagnostic_pages']
run('compile', [shutil.which('vlog'), '-work', library, 'src/top_tf_hdmi_audio.v',
    'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v', 'src/frame_read_monitor.v', str(reference),
    *['src/test/' + case + '.v' for case in cases]])
for case in cases:
    run(case, [shutil.which('vsim'), '-c', '-lib', library, case,
        '-do', 'src/test/run_pcm_audio_player.do'], True)
