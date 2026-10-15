"""验证 SDRAM 读写准入互斥；旧版必须复现冲突，修复版及提供的参考写侧必须通过。"""
from pathlib import Path
import argparse
import re
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
out = root / 'prj/log/frame_burst_regression_20261015'
out.mkdir(parents=True, exist_ok=True)
library = str(out / 'work')

def run(name, command, expected=None):
    result = subprocess.run(command, cwd=root, capture_output=True, timeout=180)
    text = (result.stdout + result.stderr).decode(errors='replace')
    (out / (name + '.log')).write_text(text, encoding='utf-8')
    if expected == 'collision':
        if 'overlapping SDRAM read/write commands' not in text:
            raise RuntimeError('historical collision did not reproduce: ' + name)
        print(name + ': EXPECTED overlapping read/write commands reproduced', flush=True)
        return
    if result.returncode or re.search(r'\*\* (?:Error|Fatal):|Errors: [1-9]|\bFAIL\b', text) or expected == 'pass' and 'PASS' not in text:
        raise RuntimeError(name + '\n' + '\n'.join(text.splitlines()[-12:]))
    print(name + ': ' + '; '.join(line for line in text.splitlines() if 'PASS' in line or 'Errors:' in line), flush=True)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reference', type=Path, help='参考例程的 hdl_source 目录，只读')
args = parser.parse_args()
baseline = subprocess.check_output(['git', 'show', '8e3dd70:src/SD/frame_fifo_write.v'], cwd=root).decode('utf-8')
baseline = re.sub(r'\bframe_fifo_write\b', 'baseline_frame_fifo_write', baseline)
baseline_path = out / 'baseline_frame_fifo_write.v'
baseline_path.write_text(baseline, encoding='utf-8')
test = (root / 'src/test/tb_frame_burst_mutual_exclusion.v').read_text(encoding='utf-8')
old_test = re.sub(r'\bframe_fifo_write\b', 'baseline_frame_fifo_write', test)
old_test = old_test.replace('tb_frame_burst_mutual_exclusion', 'tb_frame_burst_baseline')
old_test_path = out / 'tb_frame_burst_baseline.v'
old_test_path.write_text(old_test, encoding='utf-8')
sources = ['src/SD/frame_fifo_read.v', 'src/SD/frame_fifo_write.v', str(baseline_path), str(old_test_path),
           'src/test/tb_frame_burst_mutual_exclusion.v', 'src/test/tb_frame_fifo_refresh_gate.v',
           'src/test/tb_frame_fifo_write_address.v']
cases = ['tb_frame_burst_mutual_exclusion', 'tb_frame_fifo_refresh_gate', 'tb_frame_fifo_write_address']
if args.reference:
    reference = (args.reference / 'SD/frame_fifo_write.v').read_text(encoding='utf-8-sig')
    reference = re.sub(r'\bframe_fifo_write\b', 'reference_frame_fifo_write', reference)
    reference_path = out / 'reference_frame_fifo_write.v'
    reference_path.write_text(reference, encoding='utf-8')
    ref_test = test.replace('tb_frame_burst_mutual_exclusion', 'tb_frame_burst_reference')
    ref_test = ref_test.replace('frame_fifo_write #(', 'reference_frame_fifo_write #(.WRITE_V_FLIP(0),')
    ref_test = re.sub(r",\s*\.write_addr_4\(21'd0\)", '', ref_test)
    ref_test = ref_test.replace(".write_v_flip(1'b0),", '')
    ref_test = ref_test.replace(".refresh_hold(1'b0),.App_rd_busy", '.App_rd_busy')
    ref_test = ref_test.replace(".write_addr_index(3'd0)", ".write_addr_index(2'd0)")
    reference_test_path = out / 'tb_frame_burst_reference.v'
    reference_test_path.write_text(ref_test, encoding='utf-8')
    sources += [str(reference_path), str(reference_test_path)]
    cases.append('tb_frame_burst_reference')
if not Path(library).exists():
    run('vlib', [shutil.which('vlib'), library])
run('compile', [shutil.which('vlog'), '-work', library, *sources])
run('baseline_collision', [shutil.which('vsim'), '-c', '-lib', library, 'tb_frame_burst_baseline',
    '-do', 'src/test/run_pcm_audio_player.do'], 'collision')
for case in cases:
    run(case, [shutil.which('vsim'), '-c', '-lib', library, case,
        '-do', 'src/test/run_pcm_audio_player.do'], 'pass')
for case in ['tb_frame_burst_mutual_exclusion'] + (['tb_frame_burst_reference'] if args.reference else []):
    run(case + '_256', [shutil.which('vsim'), '-c', '-lib', library, case, '-gBURST_WORDS=256',
        '-do', 'src/test/run_pcm_audio_player.do'], 'pass')
