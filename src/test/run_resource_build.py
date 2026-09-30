"""使用当前 TD 工程的默认流程，在独立日志目录综合或布局布线，不生成 bitstream。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name')
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
