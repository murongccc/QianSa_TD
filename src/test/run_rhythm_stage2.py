"""第二阶段 RTL 回归；日志写入独立目录，不生成 bitstream。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('prj/log/rhythm_stage2_regression'))
    parser.add_argument('--real-chart', type=Path, default=Path('prj/log/rhythm_assets/brave_shine_normal/GAME.BIN'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = (root / args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    binaries = {name: shutil.which(name) for name in ['vlib', 'vlog', 'vsim']}
    if not all(binaries.values()):
        raise RuntimeError('vlib/vlog/vsim must be on PATH')
    library = (output / 'work').as_posix()

    def run(name, command, expect_pass=False):
        with (output / (name + '.log')).open('wb') as log:
            result = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        text = (output / (name + '.log')).read_text(errors='replace')
        if result.returncode or re.search(r'\*\* (?:Fatal|Error):|Errors: [1-9]', text) or (expect_pass and 'PASS' not in text):
            raise RuntimeError(f'{name} failed; see {output / (name + ".log")}')
        print(f'PASS {name}', flush=True)

    if not (Path(library) / '_info').exists():
        run('library', [binaries['vlib'], library])
    tests = ['tb_chart_volume_validation', 'tb_rhythm_sd_resources', 'tb_rhythm_pcm_clock', 'tb_rhythm_arbiter', 'tb_pcm_audio_player',
             'tb_wav_canonical_headers', 'tb_fat32_wav_reader', 'tb_fat32_wav_reader_direct_volume',
             'tb_wav_reader_resource_opt', 'tb_wav_calc_cancel', 'tb_sd_sector_arbiter', 'tb_sd_speed_parameter', 'tb_sd_game_spi']
    if args.real_chart.exists():
        data = args.real_chart.read_bytes()
        if len(data) != 3368 or data[:4] != b'R4B1':
            raise RuntimeError('real fixture must be the 413-note Dell\'s Normal GAME.BIN')
        # 固定相对路径与 testbench 对应；仿真工作目录始终为项目根。
        fixture = root / 'prj/log/rhythm_stage2_regression/real_chart.hex'
        fixture.parent.mkdir(parents=True, exist_ok=True)
        fixture.write_text(''.join(f'{byte:02x}\n' for byte in data), encoding='ascii')
        tests.append('tb_rhythm_real_chart')
    else:
        print('SKIP real chart: asset not present; convert it first', flush=True)
    sources = ['rhythm_block_ram', 'pcm_audio_player', 'fat32_wav_reader', 'fat32_chart_reader', 'rhythm_chart_buffer',
               'sd_sector_arbiter', 'rhythm_sd_resources']
    run('compile', [binaries['vlog'], '-work', library,
                    'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v', 'src/SD/spi_master.v', 'src/SD/sd_card_cmd.v',
                    'src/SD/sd_card_sec_read_write.v', 'src/SD/sd_card_top.v',
                    *[f'src/{name}.v' for name in sources], *[f'src/test/{name}.v' for name in tests]])
    for test in tests:
        run(test, [binaries['vsim'], '-c', '-lib', library, test,
                   '-do', 'src/test/run_pcm_audio_player.do'], True)
    run('wav_shared_volume', [binaries['vsim'], '-c', '-lib', library, 'tb_fat32_wav_reader',
                             '-gUSE_SHARED_VOLUME=1', '-do', 'src/test/run_pcm_audio_player.do'], True)
    for name, parameters in [('spi_delay19', ['-gWAV_RETURN_DELAY_NS=19']),
                             ('spi_delay20_e8h', ['-gWAV_RETURN_DELAY_NS=20', '-gEXPECT_E8=1']),
                             ('spi_slow_delay25', ['-gHIGH_SPEED_DIV=2', '-gWAV_RETURN_DELAY_NS=25'])]:
        run(name, [binaries['vsim'], '-c', '-lib', library, 'tb_sd_game_spi', *parameters,
                   '-do', 'src/test/run_pcm_audio_player.do'], True)
    if (root / 'prj/log/rhythm_e8_diagnosis_20261006/card_startup.hex').exists():
        run('spi_actual_card', [binaries['vsim'], '-c', '-lib', library, 'tb_sd_game_spi',
                               '-gUSE_REAL_CARD=1', '-do', 'src/test/run_pcm_audio_player.do'], True)
    if 'tb_rhythm_real_chart' in tests:
        run('chart_last_fat_byte', [binaries['vsim'], '-c', '-lib', library, 'tb_rhythm_real_chart',
                                  '-gFAT_EDGE=1', '-do', 'src/test/run_pcm_audio_player.do'], True)
        run('chart_last_directory_entry', [binaries['vsim'], '-c', '-lib', library, 'tb_rhythm_real_chart',
                                  '-gFAT_EDGE=1', '-gDIR_EDGE=1', '-do', 'src/test/run_pcm_audio_player.do'], True)



if __name__ == '__main__':
    main()
