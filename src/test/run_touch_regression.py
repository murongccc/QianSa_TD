"""回放触摸实测日志并验证串口集成；不运行 TD 或生成 bitstream。"""
import argparse
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', choices=['parser', 'integration', 'monitor', 'diagnostics'])
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = root / 'prj/log/touch_regression_20261009'
    output.mkdir(parents=True, exist_ok=True)
    binaries = {name: shutil.which(name) for name in ['vlib', 'vlog', 'vsim']}
    if not all(binaries.values()):
        raise SystemExit('ModelSim vlib/vlog/vsim must be on PATH')
    library = output / 'work'

    def run(label, command, require_pass=False):
        log = output / (label + '.log')
        with log.open('wb') as stream:
            result = subprocess.run(command, cwd=root, stdout=stream,
                                    stderr=subprocess.STDOUT, timeout=600)
        text = log.read_text(errors='replace')
        if result.returncode or 'FAIL' in text or (require_pass and 'PASS' not in text):
            print('\n'.join(text.splitlines()[-20:]))
            raise SystemExit(f'FAIL {label}; see {log}')
        print('\n'.join(line for line in text.splitlines()
                        if 'PASS' in line or 'Errors:' in line or 'Warnings:' in line))

    if not library.exists():
        run('library', [binaries['vlib'], str(library)])
    cases = [args.case] if args.case else ['parser', 'integration', 'monitor', 'diagnostics']
    sources = ['uart_byte_rx', 'uart_byte_tx', 'ch9350_touch_parser',
               'ch9350_touch_input', 'touch_serial_monitor', 'uart_command_control', 'frame_read_monitor']
    tops = {'parser': 'tb_ch9350_touch_parser', 'integration': 'tb_touch_uart_integration',
            'monitor': 'tb_touch_serial_monitor', 'diagnostics': 'tb_frame_signature_switch'}
    test_sources = [str(root / 'src/test' / (tops[case] + '.v')) for case in cases]
    if 'diagnostics' in cases:
        test_sources.append(str(root / 'src/test/tb_frame_read_monitor.v'))
    run('compile', [binaries['vlog'], '-work', str(library),
                    *[str(root / 'src' / (name + '.v')) for name in sources],
                    *test_sources])
    for case in cases:
        run(case, [binaries['vsim'], '-c', '-lib', str(library), tops[case],
                   '-do', 'src/test/run_touch_uart_debug.do'], require_pass=True)
    if 'diagnostics' in cases:
        run('original_frame_monitor', [binaries['vsim'], '-c', '-lib', str(library),
                                      'tb_frame_read_monitor', '-do', 'src/test/run_touch_uart_debug.do'],
            require_pass=True)
    print(f'PASS touch regression; logs: {output}')


if __name__ == '__main__':
    main()
