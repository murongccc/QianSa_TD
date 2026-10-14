"""触摸链资源优化回归：旧RTL对照、既有协议/串口/坐标/视频测试。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess

BASELINE_COMMIT='0efcc24e3a52c527fff957e2f1da75c24534e2a1'
# 三指解析器在旧资源优化基线之后已升级；本次仅验证删除PC命令不改变它。
PARSER_BASELINE_COMMIT='9e3ad50'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case',choices=['equivalence','existing','changed'])
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    output=root/'prj/log/touch_priority5_20261010'
    output.mkdir(parents=True,exist_ok=True)
    commands={name:shutil.which(name) for name in ['vlib','vlog','vsim','git']}
    if not all(commands.values()):raise SystemExit('ModelSim and Git must be on PATH')
    library=output/('work_'+(args.case or 'all'))

    def run(label,command,require_pass=False):
        log=output/(label+'.log')
        with log.open('wb')as stream:
            result=subprocess.run(command,cwd=root,stdout=stream,stderr=subprocess.STDOUT,timeout=600)
        text=log.read_text(errors='replace')
        if result.returncode or 'FAIL' in text or (require_pass and 'PASS' not in text):
            print('\n'.join(text.splitlines()[-24:]),flush=True)
            raise SystemExit(f'FAIL {label}; see {log}')
        print('\n'.join(line for line in text.splitlines()if 'PASS' in line or 'Errors:' in line or 'Warnings:' in line),flush=True)

    if not library.exists():run('library',[commands['vlib'],str(library)])
    # 固定修改前提交，使忽略目录中的参考文件可由新检出环境复现。
    for name in ['ch9350_touch_parser','touch_serial_monitor','touch_pixel_mapper','touch_counter_increment']:
        reference=PARSER_BASELINE_COMMIT if name in ['ch9350_touch_parser','touch_counter_increment'] else BASELINE_COMMIT
        old_source=subprocess.check_output([commands['git'],'show',f'{reference}:src/{name}.v'],cwd=root).decode('utf-8')
        old_source=re.sub(r'\b'+name+r'\b','baseline_'+name,old_source)
        if name=='ch9350_touch_parser':old_source=re.sub(r'\btouch_counter_increment\b','baseline_touch_counter_increment',old_source)
        (output/('baseline_'+name+'.v')).write_text(old_source,encoding='utf-8')
    old_video=subprocess.check_output([commands['git'],'show','d2cea4d:src/video_presentation.v'],cwd=root).decode('utf-8')
    old_video=re.sub(r'\bvideo_presentation\b','baseline_video_presentation',old_video)
    (output/'baseline_video_presentation.v').write_text(old_video,encoding='utf-8')
    names=['uart_byte_rx','uart_byte_tx','ch9350_touch_parser','ch9350_touch_input','touch_serial_monitor',
           'frame_read_monitor','touch_counter_increment','touch_pixel_mapper',
           'touch_frame_snapshot','touch_marker','ring_spectrum_renderer','image_info_metadata','image_info_osd','image_osd_font','video_presentation']
    cases=['tb_touch_resource_equivalence']if args.case=='equivalence' else [
        'tb_ch9350_touch_parser','tb_touch_uart_integration','tb_touch_serial_monitor','tb_touch_stats_atomic',
        'tb_touch_counter_increment','tb_touch_pixel_mapper','tb_touch_frame_snapshot','tb_touch_stream_snapshot',
        'tb_touch_marker','tb_touch_video_overlay','tb_video_presentation','tb_video_presentation_startup']
    if not args.case:cases=['tb_touch_resource_equivalence']+cases
    if args.case=='changed':cases=['tb_touch_resource_equivalence','tb_ch9350_touch_parser','tb_touch_uart_integration','tb_touch_serial_monitor','tb_touch_stats_atomic','tb_touch_counter_increment']
    references=[output/('baseline_'+name+'.v')for name in ['ch9350_touch_parser','touch_serial_monitor','touch_pixel_mapper','touch_counter_increment','video_presentation']]
    if not all(path.exists()for path in references):raise SystemExit('Baseline RTL extraction failed')
    run('compile_'+(args.case or 'all'),[commands['vlog'],'-work',str(library),'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v','E:/AnLuTD/sim_release/eg4/eg_logic_dram.v',
        'src/test/eg_logic_mult_model.v',*[str(root/'src'/(name+'.v'))for name in names],*[str(p)for p in references],
        *[str(root/'src/test'/(name+'.v'))for name in cases]])
    for case in cases:
        run(case,[commands['vsim'],'-c','-lib',str(library),case,'-do','src/test/run_touch_uart_debug.do'],True)
    print(f'PASS touch resource regression; logs: {output}',flush=True)


if __name__=='__main__':main()
