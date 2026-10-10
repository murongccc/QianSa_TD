"""第一优先级资源优化：固定源码基线的逐周期对照与位宽边界，不运行实现流程。"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess

BASELINE = '936a97b'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('prj/log/rhythm_priority1_complete_equivalence_20261010'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = (root / args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    binaries = {name: shutil.which(name) for name in ['git', 'vlib', 'vlog', 'vsim']}
    if not all(binaries.values()):
        raise RuntimeError('git/vlib/vlog/vsim must be on PATH')
    library = (output/'work').as_posix()
    results = []

    def run(name, command, expect_pass=False):
        log = output/(name+'.log')
        with log.open('wb') as stream:
            result = subprocess.run(command, cwd=root, stdout=stream, stderr=subprocess.STDOUT, timeout=300)
        text = log.read_text(errors='replace')
        if result.returncode or re.search(r'\*\* (?:Fatal|Error):|Errors: [1-9]', text) or (expect_pass and 'PASS' not in text):
            raise RuntimeError(f'{name} failed; see {log}')
        results.append(dict(name=name, status='PASS', warnings=len(re.findall(r'\*\* Warning:', text))))
        print('PASS '+name, flush=True)

    names = ['fat32_chart_reader', 'rhythm_judge_core', 'rhythm_game_renderer',
             'rhythm_session_controller', 'rhythm_game_engine', 'rhythm_sd_resources','rhythm_hud']
    references = []
    for name in names:
        text = subprocess.check_output([binaries['git'], 'show', f'{BASELINE}:src/{name}.v'], cwd=root).decode('utf-8')
        # 同时重命名父模块和被修改的子模块，形成独立的原版功能链。
        for original in names:
            text = re.sub(r'\b'+original+r'\b', original+'_baseline', text)
        path = output/(name+'_baseline.v')
        path.write_text(text, encoding='utf-8')
        references.append(str(path))

    def augment_named(test, module, instance, widths, gates=None, extra=''):
        text = (root/'src/test'/(test+'.v')).read_text(encoding='utf-8')
        text = text.replace('module '+test+';', 'module '+test+'_equivalence;')
        pattern = re.compile(r'^\s*'+module+r'\s*(?:#\(.*?\)\s*)?'+instance+r'\s*\(.*?\);', re.M|re.S)
        match = pattern.search(text)
        if not match:
            raise RuntimeError('cannot locate named instance '+test)
        reference = re.sub(r'\b'+module+r'\b', module+'_baseline', match.group())
        reference = re.sub(r'\b'+instance+r'\s*\(', 'baseline_dut(', reference, count=1)
        declarations, checks = [], []
        for port, width in widths.items():
            connection = re.search(r'\.'+port+r'\(([^()]*)\)', reference)
            if not connection or not connection[1].strip():
                continue
            signal = connection[1].strip()
            declarations.append(f'wire {width} baseline_{port};')
            reference = reference[:connection.start()]+f'.{port}(baseline_{port})'+reference[connection.end():]
            gate = (gates or {}).get(port, "1'b1")
            checks.append(f'if(({gate}) && ({signal}!==baseline_{port}))$fatal(1,"baseline mismatch {test}.{port}");')
        inserted = '\n'.join(declarations)+reference+f'''
    integer equivalence_cycles=0;
    always @(negedge clk)begin
        #1;
        if(!rst)begin
            equivalence_cycles=equivalence_cycles+1;
            {' '.join(checks)}
            {extra}
        end
    end
'''
        text = text[:match.end()]+inserted+text[match.end():]
        text = text.replace('$finish;', f'$display("PASS baseline {test}: %0d cycles",equivalence_cycles);$finish;')
        path = output/(test+'_equivalence.v')
        path.write_text(text, encoding='utf-8')
        return str(path)

    def augment_positional(test, module, widths, rst_expression):
        text = (root/'src/test'/(test+'.v')).read_text(encoding='utf-8')
        text = text.replace('module '+test+';', 'module '+test+'_equivalence;')
        match = re.search(r'^\s*'+module+r'\s*(?:#\(.*?\)\s*)?dut\s*\((.*?)\);', text, re.M|re.S)
        if not match:
            raise RuntimeError('cannot locate positional instance '+test)
        ports = [p.strip() for p in match[1].split(',')]
        checks, declarations = [], []
        for index, width in widths.items():
            signal=ports[index]
            ports[index]=f'baseline_port_{index}'
            declarations.append(f'wire {width} baseline_port_{index};')
            gate = 'view_valid' if signal in ['view_start','view_end'] else "1'b1"
            checks.append(f'if(({gate}) && ({signal}!==baseline_port_{index}))$fatal(1,"baseline mismatch {test}.{signal}");')
        reference = re.sub(r'\b'+module+r'\b', module+'_baseline', match.group())
        reference = re.sub(r'\bdut\s*\(.*?\);', 'baseline_dut('+','.join(ports)+');', reference, flags=re.S)
        inserted='\n'.join(declarations)+reference+f'''
    integer equivalence_cycles=0;
    always @(negedge clk)begin
        #1;
        if({rst_expression})begin
            equivalence_cycles=equivalence_cycles+1;
            {' '.join(checks)}
        end
    end
'''
        text=text[:match.end()]+inserted+text[match.end():]
        text=text.replace('$finish;',f'$display("PASS baseline {test}: %0d cycles",equivalence_cycles);$finish;')
        path=output/(test+'_equivalence.v')
        path.write_text(text,encoding='utf-8')
        return str(path)

    generated = [
        augment_named('tb_rhythm_note_style','rhythm_game_renderer','renderer',
            dict(view_index='[4:0]',capture_busy='',frame_enabled='',pixel_on='',pixel_rgb='[23:0]'),
            dict(pixel_rgb='on'),
            'if(renderer.progress!==baseline_dut.progress)$fatal(1,"baseline progress mismatch");'),
        augment_named('tb_rhythm_renderer','rhythm_game_renderer','renderer',
            dict(view_index='[4:0]',capture_busy='',frame_enabled='',pixel_on='',pixel_rgb='[23:0]',metadata_address='[5:0]'),
            dict(pixel_rgb='on'),
            'if(renderer.progress!==baseline_dut.progress)$fatal(1,"baseline progress mismatch");'),
        augment_named('tb_rhythm_sd_resources','rhythm_sd_resources','dut',
            dict(bmp_valid='',bmp_done='',sd_req='',sd_addr='[31:0]',audio_fifo_we='',audio_fifo_data='[31:0]',
                 audio_fifo_level='[31:0]',note_valid='',note_data='[63:0]',song_frames='[31:0]',note_count='[15:0]',
                 hold_count='[15:0]',resources_ready='',cancelled='',audio_eof='',chart_eof='',error_code='[3:0]'),
            dict(note_data='nvalid',audio_fifo_data='awe')),
        augment_positional('tb_rhythm_judge_core','rhythm_game_engine',
            {11:'',13:'',18:'[3:0]',19:'[127:0]',20:'[3:0]',22:'',23:'[31:0]',24:'[31:0]',25:'',26:'[1:0]',27:'[1:0]',
             28:'[15:0]',29:'[15:0]',30:'[15:0]',31:'[15:0]',32:'[15:0]',33:'[15:0]',34:'[19:0]',35:'',36:''},'rst_n'),
        augment_positional('tb_rhythm_session','rhythm_session_controller',
            {24:'',25:'',26:'',27:'',28:'',29:'',30:'',31:'',32:'',33:'[1:0]',34:'signed [32:0]',35:'[31:0]',
             36:'[15:0]',37:'signed [31:0]',38:'',39:'[3:0]',40:'[3:0]'},'!rst'),
    ]
    sources=['rhythm_block_ram','fat32_chart_reader','rhythm_chart_buffer','fat32_wav_reader','sd_sector_arbiter',
             'rhythm_sd_resources','rhythm_judge_core','rhythm_auto_input','rhythm_game_engine','rhythm_game_renderer',
             'rhythm_font','rhythm_hud','rhythm_session_controller','pcm_audio_player','ring_spectrum_renderer',
             'video_presentation','image_controls','media_session_controller','domain_reset_sync','fat32_bmp_catalog',
             'sd_media_pipeline','touch_marker']
    tests=['tb_rhythm_priority1_arithmetic','tb_rhythm_priority1_directory','tb_chart_volume_validation',
           'tb_rhythm_priority1_constants','tb_rhythm_priority1_hud_coordinates']
    run('library',[binaries['vlib'],library])
    run('compile',[binaries['vlog'],'-work',library,'+incdir+src/SD',
        'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v','src/test/eg_logic_mult_model.v','src/SD/color_bar.v',
        *[f'src/{n}.v' for n in sources],*references,*generated,*[f'src/test/{n}.v' for n in tests]])
    cases=[('constants','tb_rhythm_priority1_constants',[]),
           ('constants_lut','tb_rhythm_priority1_constants',['-gSCORE_DSP=0']),
           ('hud_coordinates','tb_rhythm_priority1_hud_coordinates',[]),
           ('arithmetic','tb_rhythm_priority1_arithmetic',[]),
           ('volume','tb_chart_volume_validation',[]),
           ('directory_1024_128','tb_rhythm_priority1_directory',[]),
           ('directory_2_1','tb_rhythm_priority1_directory',['-gLIMIT=2','-gSPC=1']),
           ('directory_1_128','tb_rhythm_priority1_directory',['-gLIMIT=1','-gSPC=128']),
           ('judge_equivalence','tb_rhythm_judge_core_equivalence',[]),
           ('judge_packed_equivalence','tb_rhythm_judge_core_equivalence',['-gBLOCK_QUEUE=1']),
           ('session_equivalence','tb_rhythm_session_equivalence',[]),
           ('resources_equivalence','tb_rhythm_sd_resources_equivalence',[]),
           ('style_equivalence','tb_rhythm_note_style_equivalence',[]),
           ('style_distributed_equivalence','tb_rhythm_note_style_equivalence',['-gBLOCK_GEOMETRY=0']),
           ('renderer_equivalence','tb_rhythm_renderer_equivalence',[])]
    for name,top,parameters in cases:
        run(name,[binaries['vsim'],'-c','-lib',library,top,*parameters,'-do','src/test/run_pcm_audio_player.do'],True)
    (output/'summary.json').write_text(json.dumps(dict(baseline=BASELINE,results=results),ensure_ascii=False,indent=2),encoding='utf-8')


if __name__=='__main__':
    main()
