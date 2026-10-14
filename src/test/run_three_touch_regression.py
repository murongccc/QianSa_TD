from pathlib import Path
import json,re,shutil,subprocess
ROOT=Path(__file__).resolve().parents[2];OUT=ROOT/'prj/log/three_touch_20261013';OUT.mkdir(parents=True,exist_ok=True)
def run(label,cmd,passed=False):
 with (OUT/(label+'.log')).open('wb') as log:result=subprocess.run(cmd,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,timeout=600)
 text=(OUT/(label+'.log')).read_text(errors='replace')
 if result.returncode or re.search(r'\*\* (?:Error|Fatal):|\bFAIL\b|Errors: [1-9]',text) or passed and 'PASS' not in text:
  raise RuntimeError(label+'\n'+'\n'.join(text.splitlines()[-15:]))
 print(label+': '+'; '.join(l for l in text.splitlines() if 'PASS' in l or 'Errors:' in l),flush=True)
lib=str(OUT/'work')
if not Path(lib).exists():run('library',[shutil.which('vlib'),lib])
modules=['ch9350_touch_parser','ch9350_touch_input','touch_counter_increment','touch_lane_input','touch_game_event_bridge','rhythm_game_engine','rhythm_judge_core','rhythm_auto_input','rhythm_block_ram','rhythm_session_controller','touch_serial_monitor','uart_byte_tx','uart_byte_rx','frame_read_monitor','touch_pixel_mapper','touch_frame_snapshot','touch_marker']
cases=['tb_touch_three_rearm','tb_touch_three_engine','tb_touch_three_replay','tb_ch9350_touch_parser','tb_touch_lane_input','tb_touch_lane_parser','tb_touch_game_event_bridge','tb_touch_rhythm_integration','tb_touch_lane_serial','tb_touch_uart_integration','tb_touch_serial_monitor','tb_touch_pixel_mapper','tb_touch_frame_snapshot','tb_touch_marker','tb_rhythm_session']
run('compile',[shutil.which('vlog'),'-work',lib,'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v','E:/AnLuTD/sim_release/eg4/eg_logic_dram.v','src/test/eg_logic_mult_model.v',*[str(ROOT/'src'/(m+'.v')) for m in modules],*[str(ROOT/'src/test'/(m+'.v')) for m in cases]])
for e in json.loads((ROOT/'src/test/data/touch_three_manifest.json').read_text(encoding='utf-8')):
 run(e['fixture'],[shutil.which('vsim'),'-c','-lib',lib,'tb_touch_three_replay','-gFRAMES='+str(e['frames']),'-gFILE='+e['fixture'],'-do','src/test/run_touch_uart_debug.do'],True)
for c in [c for c in cases if c!='tb_touch_three_replay']:run(c,[shutil.which('vsim'),'-c','-lib',lib,c,'-do','src/test/run_touch_uart_debug.do'],True)
for phase,half in [(0,20),(31,23),(1,11)]:
 run(f'bridge_{phase}_{half}',[shutil.which('vsim'),'-c','-lib',lib,'tb_touch_game_event_bridge',f'-gPHASE={phase}',f'-gHALF={half}','-do','src/test/run_touch_uart_debug.do'],True)
print('PASS three touch regression')
