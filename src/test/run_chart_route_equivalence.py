"""对照簇选择优化前的谱面读取器，复用碎片链和取消场景逐周期比较。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-ref', default='9e3ad50')
    parser.add_argument('--output', type=Path, default=Path('prj/log/chart_route_equivalence_20261014'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = (root / args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    binaries = {name: shutil.which(name) for name in ['git', 'vlib', 'vlog', 'vsim']}
    if not all(binaries.values()):
        raise RuntimeError('git/vlib/vlog/vsim must be on PATH')

    def run(name, command, expect_pass=False):
        log = output / (name + '.log')
        with log.open('wb') as stream:
            result = subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT, timeout=180)
        text = log.read_text(errors='replace')
        if result.returncode or re.search(r'\*\* (?:Fatal|Error):|Errors: [1-9]', text) or (expect_pass and 'PASS' not in text):
            raise RuntimeError(f'{name} failed; see {log}')
        print('PASS ' + name, flush=True)

    baseline = subprocess.check_output(
        [binaries['git'], 'show', f'{args.baseline_ref}:src/fat32_chart_reader.v'], cwd=root).decode('utf-8')
    baseline = re.sub(r'\bfat32_chart_reader\b', 'baseline_chart_reader', baseline)
    reference = output / 'baseline_chart_reader.v'
    reference.write_text(baseline, encoding='utf-8')
    inputs = ['clk', 'rst', 'enable', 'cancel', 'volume_valid', 'volume_fat_start',
              'volume_data_start', 'volume_root_cluster', 'volume_sectors_per_cluster',
              'reserve_ready', 'sd_data', 'sd_valid', 'sd_done']
    outputs = ['sd_req', 'sd_addr', 'note_we', 'note_data', 'header_valid', 'song_frames',
               'note_count', 'hold_count', 'offset_samples', 'title', 'difficulty',
               'metadata_we', 'metadata_address', 'metadata_data', 'busy', 'eof',
               'cancelled', 'error_code', 'cluster', 'state']
    checks = '\n'.join(
        f'            if(dut.u_chart.{name}!==reference_chart.{name})'
        f'$fatal(1,"chart equivalence mismatch: {name}");' for name in outputs)
    bench = (root / 'src/test/tb_rhythm_sd_resources.v').read_text(encoding='utf-8')
    bench = bench.replace('module tb_rhythm_sd_resources;', 'module tb_chart_route_equivalence;')
    connections = ',\n'.join(f'        .{name}(dut.u_chart.{name})' for name in inputs)
    injected = f'''
    baseline_chart_reader reference_chart(
{connections});
    integer compared_cycles=0;
    always @(negedge clk)begin
        if(!rst)begin
            compared_cycles=compared_cycles+1;
{checks}
        end
    end
'''
    bench = bench.replace('endmodule', injected + '\nendmodule')
    bench = bench.replace('$finish;', '$display("PASS chart equivalence: %0d cycles",compared_cycles);$finish;')
    bench_path = output / 'tb_chart_route_equivalence.v'
    bench_path.write_text(bench, encoding='utf-8')
    library = (output / 'work').as_posix()
    if not (Path(library) / '_info').exists():
        run('library', [binaries['vlib'], library])
    sources = ['rhythm_block_ram', 'pcm_audio_player', 'fat32_wav_reader', 'fat32_chart_reader',
               'rhythm_chart_buffer', 'sd_sector_arbiter', 'rhythm_sd_resources']
    run('compile', [binaries['vlog'], '-work', library, 'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v',
                    *[f'src/{name}.v' for name in sources], str(reference), str(bench_path)])
    run('equivalence', [binaries['vsim'], '-c', '-lib', library, 'tb_chart_route_equivalence',
                        '-do', 'src/test/run_pcm_audio_player.do'], True)


if __name__ == '__main__':
    main()
