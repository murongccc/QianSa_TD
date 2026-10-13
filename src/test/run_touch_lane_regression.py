"""四轨触摸：完整原始值域阈值校验、局部及真实优化引擎仿真。"""
from pathlib import Path
import re
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
out = root / 'prj/log/touch_lane_20261011'
out.mkdir(parents=True, exist_ok=True)
project = (root/'prj/SD_to_Video.al').read_text(encoding='utf-8')
source_set = re.search(r'<Verilog>.*?</Verilog>', project, re.S)[0]
for module in ['touch_lane_input', 'touch_game_event_bridge']:
    entries = re.findall(r'<File Path="[^"]*/'+module+r'\.v">.*?</File>', source_set, re.S)
    assert len(entries)==1, f'{module}: board project must contain exactly one source entry; reload TD project after editing .al'
    assert 'Name="UsedInSyn" Val="true"' in entries[0], f'{module}: synthesis is disabled'
    assert 'Name="AutoExcluded" Val="true"' not in entries[0], f'{module}: source is excluded'
    assert (root/'src'/(module+'.v')).is_file(), f'{module}: missing RTL file'
for entry in re.findall(r'<File Path="[^"]*">.*?</File>', source_set, re.S):
    if 'src/test/' in entry.replace('\\','/'):
        assert 'Name="UsedInSyn" Val="false"' in entry, 'testbench must not be enabled for board synthesis'
print('PASS board project includes both touch lane modules for synthesis', flush=True)
mapper = (root/'src/touch_pixel_mapper.v').read_text(encoding='utf-8')
lane = (root/'src/touch_lane_input.v').read_text(encoding='utf-8')
def constant(text, name):
    return int(re.search(r'\b'+name+r"\s*=\s*(?:COMPACT_LAYOUT\s*\?\s*)?\d+'d(\d+)", text)[1])
def mapped(v, axis):
    low, high, scale = [constant(mapper, axis+n) for n in ['_MIN','_MAX','_SCALE_Q16']]
    return min(639 if axis=='X' else 479, ((min(high,max(low,v))-low)*scale+32768)>>16)
xs = [constant(lane, 'X'+str(i)) for i in range(5)]
y0 = constant(lane, 'Y0')
pixel_y_min = constant(lane, 'PIXEL_Y_MIN')
for x in range(65536):
    px = mapped(x, 'X')
    actual = 0 if x<xs[0] or x>=xs[4] else 1<<sum(x>=edge for edge in xs[1:4])
    expected = 0 if px<16 or px>=336 else 1<<((px-16)//80)
    assert actual==expected, (x,px,actual,expected)
for y in range(65536):
    assert (y>=y0)==(mapped(y,'Y')>=pixel_y_min), (y,mapped(y,'Y'))
print('PASS exhaustive 65536 X + 65536 Y values match current mapper constants', flush=True)
def run(label, command, passed=False):
    with (out/(label+'.log')).open('wb') as f:
        result=subprocess.run(command,cwd=root,stdout=f,stderr=subprocess.STDOUT,timeout=300)
    text=(out/(label+'.log')).read_text(errors='replace')
    if result.returncode or re.search(r'\*\* (?:Error|Fatal):|Errors: [1-9]',text) or (passed and 'PASS' not in text):
        raise RuntimeError(label+' failed: '+str(out/(label+'.log'))+'\n'+'\n'.join(text.splitlines()[-12:]))
    print('\n'.join(s for s in text.splitlines() if 'PASS' in s or 'Errors:' in s),flush=True)
lib=str(out/'work')
if not Path(lib).exists():run('library',[shutil.which('vlib'),lib])
names=['touch_lane_input','touch_game_event_bridge','rhythm_game_engine','rhythm_judge_core','rhythm_auto_input','rhythm_block_ram','touch_serial_monitor','uart_byte_tx','ch9350_touch_parser','touch_counter_increment']
cases=['tb_touch_lane_input','tb_touch_game_event_bridge','tb_touch_rhythm_integration','tb_touch_lane_serial','tb_touch_lane_parser']
reference = subprocess.check_output(['git','show','f9aa991:src/touch_lane_input.v'],cwd=root).decode('utf-8')
reference = re.sub(r"\bY0=16'd\d+",f"Y0=16'd{y0}",reference) # 仅对齐本轮有意修改的区域
for i, value in enumerate(xs):
    reference = re.sub(r"\bX"+str(i)+r"=16'd\d+", "X"+str(i)+"=16'd"+str(value), reference)
reference = re.sub(r'\btouch_lane_input\b','touch_lane_input_reference',reference)
reference_path = out/'touch_lane_input_reference.v'
reference_path.write_text(reference,encoding='utf-8')
cases.append('tb_touch_lane_resource_equivalence')
run('compile',[shutil.which('vlog'),'-work',lib,'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v','E:/AnLuTD/sim_release/eg4/eg_logic_dram.v','src/test/eg_logic_mult_model.v',
              *[str(root/'src'/(n+'.v')) for n in names],str(reference_path),*[str(root/'src/test'/(n+'.v')) for n in cases]])
for case in cases:run(case,[shutil.which('vsim'),'-c','-lib',lib,case,'-do','src/test/run_touch_uart_debug.do'],True)
for phase, half in [(0,20),(31,23),(1,11)]:
    run(f'bridge_phase_{phase}_{half}',[shutil.which('vsim'),'-c','-lib',lib,'tb_touch_game_event_bridge',
        f'-gPHASE={phase}',f'-gHALF={half}','-do','src/test/run_touch_uart_debug.do'],True)
