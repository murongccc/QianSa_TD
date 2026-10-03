"""独立综合第二阶段加载组件以核对 RAM 推断；不修改板级工程、不布局布线。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--td', default='E:/AnLuTD/bin/td_commands_prompt.exe')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    template = root / 'prj/SD_to_Video_Runs/syn_1'
    output = root / 'prj/log/rhythm_stage2_loader_syn'
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(template / 'SD_to_Video.tcl', output / 'SD_to_Video.tcl')
    # TD 工程把属性名 P&R 的 & 原样输出；解析副本时转义，交回 TD 时恢复其格式。
    project = ET.ElementTree(ET.fromstring((template / 'SD_to_Video.prj').read_text().replace('P&R', 'P&amp;R')))
    files = project.getroot().find('Source_Files')
    files.clear()
    verilog = ET.SubElement(files, 'Verilog')
    sources = ['fat32_chart_reader', 'rhythm_chart_buffer', 'fat32_wav_reader',
               'sd_sector_arbiter', 'rhythm_sd_resources']
    for index, name in enumerate(sources):
        element = ET.SubElement(verilog, 'File', Path=(root / 'src' / (name + '.v')).as_posix())
        info = ET.SubElement(element, 'FileInfo')
        for key, value in [('UsedInSyn', 'true'), ('UsedInP&R', 'true'),
                           ('BelongTo', 'design_1'), ('CompileOrder', str(index + 1))]:
            ET.SubElement(info, 'Attr', Name=key, Val=value)
    for name in ['LABEL', 'MODULE']:
        project.getroot().find('TOP_MODULE/' + name).text = 'rhythm_sd_resources'
    project.write(output / 'SD_to_Video.prj', encoding='utf-8', xml_declaration=True)
    project_path = output / 'SD_to_Video.prj'
    project_path.write_text(project_path.read_text().replace('P&amp;R', 'P&R'), encoding='utf-8')
    settings = (template / 'settings.cfg').read_text()
    for key, value in [('ADCList', '{}'), ('IpSDCList', '{}'), ('SDCList', '{"loader.sdc"}'),
                       ('top_model_name', '{rhythm_sd_resources}'), ('end_step', 'opt_gate')]:
        settings = re.sub(r'(?m)^set ' + key + r' .*', 'set ' + key + ' ' + value, settings)
    (output / 'settings.cfg').write_text(settings)
    (output / 'loader.sdc').write_text(
        'create_clock -name sd_clock -period 10.000 [get_ports clk]\n'
        'create_clock -name note_clock -period 40.000 [get_ports note_clk]\n'
        'set_clock_groups -asynchronous -group {sd_clock} -group {note_clock}\n')
    (output / 'run.tcl').write_text('source SD_to_Video.tcl\nexit\n')
    marker = output / '.opt_gate.end.f'
    report = output / 'SD_to_Video_gate.area'
    for path in [marker, report]:
        if path.exists():
            path.unlink()
    with (output / 'console.log').open('wb') as log:
        result = subprocess.run([args.td, 'run.tcl'], cwd=output, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode or not marker.exists() or not report.exists():
        raise RuntimeError(f'loader synthesis incomplete; see {output / "console.log"}')
    for line in report.read_text().splitlines():
        if re.match(r'^\s*#(?:lut\s|reg\s|bram\s|bram9k\s|fifo9k\s|bram32k\s|dsp\s)', line):
            print(line.strip())
    print(f'PASS standalone loader synthesis; logs: {output}')


if __name__ == '__main__':
    main()
