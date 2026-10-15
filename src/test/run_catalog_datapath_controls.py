"""目录移位缓存控制优化：固定当前基线逐拍对照与真实媒体集成。"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess

BASELINE='5080535521c161f3f25708bd6409315f53a2fb4b'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case',choices=['equivalence','existing','catalog','integration'])
    parser.add_argument('--output',default='prj/log/datapath_controls_catalog_regression_20261015')
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    output=root/args.output
    output.mkdir(parents=True,exist_ok=True)
    commands={name:shutil.which(name) for name in ['vlib','vlog','vsim','git']}
    if not all(commands.values()):raise SystemExit('ModelSim and Git must be on PATH')

    def run(label,command,expect_pass=False):
        path=output/(label+'.log')
        with path.open('wb') as log:
            result=subprocess.run(command,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=900)
        text=path.read_text(errors='replace')
        if result.returncode or re.search(r'\*\* (?:Fatal|Error):|Errors: [1-9]|FAIL',text) or (expect_pass and 'PASS' not in text):
            print('\n'.join(text.splitlines()[-20:]),flush=True)
            raise SystemExit(f'FAIL {label}; see {path}')
        summary=[line for line in text.splitlines() if 'PASS' in line or 'Errors:' in line]
        print('\n'.join(summary[-3:]),flush=True)

    def compile_group(name,sources,options=()):
        library=output/name
        if not library.exists():run(name+'_library',[commands['vlib'],str(library)])
        run(name+'_compile',[commands['vlog'],'-work',str(library),*options,*map(str,sources)])
        return library

    def simulate(label,library,top,parameters=()):
        run(label,[commands['vsim'],'-c','-lib',str(library),top,*parameters,'-do','src/test/run_pcm_audio_player.do'],True)

    bram=Path('E:/AnLuTD/sim_release/eg4/eg_logic_bram.v')
    if not args.case or args.case=='equivalence':
        references=[]
        for name,path in [('fat32_bmp_catalog','src/fat32_bmp_catalog.v')]:
            text=subprocess.check_output([commands['git'],'show',f'{BASELINE}:{path}'],cwd=root).decode('utf-8')
            text=re.sub(r'\b'+name+r'\b','baseline_'+name,text)
            reference=output/('baseline_'+name+'.v')
            reference.write_text(text,encoding='utf-8')
            references.append(reference)
        library=compile_group('equivalence',[bram,'src/rhythm_block_ram.v','src/fat32_bmp_catalog.v','src/SD/bmp_read.v',
            *references,'src/test/tb_image_catalog_stage1_equivalence.v'])
        for mbr in [0,1]:simulate(f'catalog_equivalence_{mbr}',library,'tb_image_catalog_stage1_equivalence',[f'-gMBR={mbr}'])

    if not args.case or args.case in ['existing','catalog']:
        names=['tb_fat32_bmp_catalog','tb_fat32_bmp_catalog_five','tb_bmp_catalog_fat_capture',
               'tb_bmp_read_resource_opt','tb_bmp_data_window','tb_bmp_read_v5_header','tb_bmp_read_fat_chain',
               'tb_bmp_sector_timing','tb_media_session_controller']
        disabled=[]
        for name in ['tb_bmp_read_resource_opt','tb_bmp_read_v5_header','tb_bmp_read_fat_chain','tb_bmp_sector_timing']:
            text=(root/'src/test'/f'{name}.v').read_text(encoding='utf-8')
            text=re.sub(r'\b'+name+r'\b',name+'_disabled',text)
            text=re.sub(r'\bbmp_read\s+(\w+)\s*\(',r'bmp_read #(.ENABLE_RAW_SCAN(0)) \1(',text)
            path=output/(name+'_disabled.v')
            path.write_text(text,encoding='utf-8')
            disabled.append(path)
        library=compile_group('existing',[bram,'src/rhythm_block_ram.v','src/fat32_bmp_catalog.v','src/SD/bmp_read.v',
            'src/media_session_controller.v',*[f'src/test/{n}.v' for n in names],*disabled])
        for name in names:
            if args.case!='catalog' or name in names[:3]:simulate(name,library,name)
        for count in range(6):simulate(f'catalog_count_{count}',library,'tb_fat32_bmp_catalog_five',
            [f'-gITEMS={count}','-gLAST_ENTRY=1','-gSAME_CYCLE=1'])
        simulate('catalog_reset_write',library,'tb_fat32_bmp_catalog_five',['-gRESET_WRITE=1','-gSAME_CYCLE=1'])
        simulate('catalog_fat_same_cycle',library,'tb_bmp_catalog_fat_capture',['-gSAME_CYCLE=1'])
        if args.case!='catalog':
            for name in ['tb_bmp_read_v5_header','tb_bmp_read_fat_chain','tb_bmp_sector_timing']:
                simulate(name+'_disabled',library,name+'_disabled')
            for offset in [54,488,512,513,1024,65536]:simulate(f'bmp_disabled_offset_{offset}',library,'tb_bmp_read_resource_opt_disabled',
                ['-gQUICK=1','-gSAME_CYCLE=1',f'-gPIXEL_OFFSET={offset}'])
            simulate('bmp_disabled_boundaries',library,'tb_bmp_read_resource_opt_disabled')

    if not args.case or args.case=='integration':
        library=compile_group('integration',[bram,'E:/AnLuTD/sim_release/eg4/eg_logic_ramfifo.v',
            'prj/al_ip/source_pixel_fifo_ip/RTL/soft_fifo_f9a960ae4922.v','prj/al_ip/source_pixel_fifo_ip/source_pixel_fifo_ip.v',
            'E:/AnLuTD/sim_release/eg4/eg_logic_mult.v','src/SD/bmp_bilinear_scaler.v','src/SD/bmp_read.v','src/domain_reset_sync.v',
            'src/fat32_bmp_catalog.v','src/fat32_wav_reader.v','src/sd_sector_arbiter.v','src/media_session_controller.v',
            'src/image_info_metadata.v','src/sd_media_pipeline.v','src/fat32_chart_reader.v','src/rhythm_chart_buffer.v','src/rhythm_sd_resources.v',
            'src/rhythm_block_ram.v','src/test/tb_sd_media_scaler_commit.v','src/test/tb_sd_media_audio_start.v'],
            ['+define+MEDIA_STARTUP_MODEL'])
        simulate('media_scaler_commit',library,'tb_sd_media_scaler_commit')
        simulate('media_rhythm_commit',library,'tb_sd_media_scaler_commit',['-gRHYTHM=1'])
        simulate('media_audio_start',library,'tb_sd_media_audio_start')
    print(f'PASS catalog datapath controls {args.case or "all"}; logs: {output}',flush=True)

if __name__=='__main__':main()
