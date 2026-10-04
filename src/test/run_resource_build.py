"""使用当前 TD 工程的默认流程，在独立日志目录综合或布局布线，不生成 bitstream。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name')
    parser.add_argument('--rhythm', action='store_true', help='include integrated rhythm RTL source set')
    parser.add_argument('--route', action='store_true')
    parser.add_argument('--parent')
    parser.add_argument('--td', default='E:/AnLuTD/bin/td_commands_prompt.exe')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    if not re.fullmatch(r'[a-zA-Z0-9_-]+', args.name):
        parser.error('name must be a simple directory name')
    kind = 'phy' if args.route else 'syn'
    template = root/'prj/SD_to_Video_Runs'/f'{kind}_1'
    dest = root/'prj/log'/args.name
    dest.mkdir(parents=True, exist_ok=True)
    for name in ['SD_to_Video.tcl', 'SD_to_Video.prj', 'settings.cfg']:
        shutil.copyfile(template/name, dest/name)
    # GUI 运行目录可能仍含已删除旧文件；以当前工程的 Verilog 源集为准。
    project_path = dest/'SD_to_Video.prj'
    current_project = (root/'prj/SD_to_Video.al').read_text(encoding='utf-8')
    source_set = re.search(r'<Verilog>.*?</Verilog>', current_project, re.S)[0]
    source_set = re.sub(r'(<File Path=")([^"]+)(")',
                        lambda m: m[1]+(root/'prj'/m[2]).resolve().as_posix()+m[3], source_set)
    project = project_path.read_text(encoding='utf-8')
    project = re.sub(r'<Verilog>.*?</Verilog>', lambda _: source_set, project, count=1, flags=re.S)
    project_path.write_text(project, encoding='utf-8')
    if args.rhythm:
        project_path=dest/'SD_to_Video.prj'
        project=project_path.read_text(encoding='utf-8')
        sources=['rhythm_block_ram','fat32_chart_reader','rhythm_chart_buffer','rhythm_sd_resources','rhythm_judge_core',
                 'rhythm_auto_input','rhythm_game_engine','rhythm_session_controller','rhythm_font','rhythm_hud','rhythm_game_renderer']
        first_order=1+max(map(int,re.findall(r'Name="CompileOrder" Val="(\d+)"',project)),default=0)
        for index,name in enumerate(sources):
            if 'src/'+name+'.v' not in project:
                entry=f'<File Path="{(root/"src"/(name+".v")).as_posix()}"><FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&amp;R" Val="true"/><Attr Name="BelongTo" Val="design_1"/><Attr Name="CompileOrder" Val="{first_order+index}"/></FileInfo></File>'.replace('P&amp;R','P&R')
                project=project.replace('</Verilog>',entry+'\n</Verilog>',1)
        project_path.write_text(project,encoding='utf-8')
    settings = (dest/'settings.cfg').read_text()
    if args.route:
        if not args.parent:
            parser.error('--route requires --parent naming the synthesis directory')
        if not re.fullmatch(r'[a-zA-Z0-9_-]+', args.parent):
            parser.error('parent must be a simple directory name')
        settings = re.sub(r'(?m)^set parent .*', f'set parent ../{args.parent}', settings)
        settings = re.sub(r'(?m)^set end_step .*', 'set end_step opt_route', settings)
    else:
        settings = re.sub(r'(?m)^set end_step .*', 'set end_step opt_gate', settings)
    (dest/'settings.cfg').write_text(settings)
    # 默认流程自行载入工程文件，保持 GUI 的源集、IP 和默认参数。
    (dest/'run.tcl').write_text('source SD_to_Video.tcl\nexit\n')
    report = dest/f'SD_to_Video_{kind if args.route else "gate"}.area'
    marker = dest/('.opt_route.end.f' if args.route else '.opt_gate.end.f')
    # OEM Tcl 错误有时仍返回零；必须确认报告和完成标志来自本次运行。
    for previous in [report,marker]:
        if previous.exists():previous.unlink()
    with (dest/'console.log').open('wb') as log:
        result = subprocess.run([args.td, 'run.tcl'], cwd=dest, stdout=log, stderr=subprocess.STDOUT)
    text = (dest/'console.log').read_text(errors='replace')
    if result.returncode or not report.exists() or not marker.exists():
        print('\n'.join(text.splitlines()[-16:]))
        raise SystemExit(f'Build incomplete; see {dest}')
    content = report.read_text()
    for line in content.splitlines():
        if re.match(r'^\s*#(?:lut\s|reg\s|bram\s|bram9k\s|fifo9k\s|bram32k\s|dsp\s)', line):
            print(line.strip())
    if args.route:
        print((dest/'SD_to_Video_phy.ts').read_text().split('Clock Summary')[0][:220])
    print(f'PASS {kind}; logs: {dest}')

if __name__ == '__main__':
    main()
