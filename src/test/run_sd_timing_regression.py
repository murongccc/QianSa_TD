"""SD 时序局部修改：簇内顺序、FAT 边界和真实 FIFO 集成回归。"""
import argparse
import re
import shutil
import subprocess
from pathlib import Path

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=Path('prj/log/fft_sd_timing_regression'))
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    output=(root/args.output).resolve();output.mkdir(parents=True,exist_ok=True)
    def run(name,tool,arguments,expect=False):
        with (output/(name+'.log')).open('wb') as log:
            result=subprocess.run([shutil.which(tool),*arguments],cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=600)
        text=(output/(name+'.log')).read_text(errors='replace')
        if result.returncode or re.search(r'\*\* (?:Fatal|Error):|Errors: [1-9]',text) or (expect and 'PASS' not in text):
            raise RuntimeError(f'{name} failed: {output/(name+".log")}')
        print('PASS '+name,flush=True)
    def compile_group(name,sources,options=()):
        library=(output/name/'work').as_posix();(output/name).mkdir(exist_ok=True)
        if not Path(library).exists():run(name+'_library','vlib',[library])
        run(name+'_compile','vlog',['-work',library,*options,*sources])
        return library
    def simulate(name,library,top,parameters=()):
        run(name,'vsim',['-c','-lib',library,top,*parameters,'-do','src/test/run_pcm_audio_player.do'],True)
    media_tests=['tb_fat32_wav_reader','tb_fat32_wav_reader_direct_volume','tb_wav_reader_resource_opt',
        'tb_wav_canonical_headers','tb_wav_done_boundary','tb_sd_media_audio_start','tb_fat32_bmp_catalog',
        'tb_fat32_bmp_catalog_five','tb_bmp_catalog_fat_capture','tb_sd_cluster_address','tb_bmp_read_resource_opt',
        'tb_bmp_data_window','tb_bmp_read_v5_header','tb_bmp_read_fat_chain','tb_media_session_controller']
    media=compile_group('media',['E:/AnLuTD/sim_release/eg4/eg_logic_bram.v','src/rhythm_block_ram.v',
        'src/fat32_wav_reader.v','src/fat32_bmp_catalog.v','src/SD/bmp_read.v','src/media_session_controller.v',
        *[f'src/test/{name}.v' for name in media_tests],'src/test/tb_bmp_sector_timing.v'])
    for edge in (0,1):
        for spc in (1,2,4,8,16,32,64,128):
            simulate(f'bmp_sectors_{spc}_edge_{edge}',media,'tb_bmp_sector_timing',[f'-gSPC={spc}',f'-gFAT_EDGE={edge}'])
    for top in media_tests:simulate(top,media,top)
    simulate('catalog_fat_same_cycle',media,'tb_bmp_catalog_fat_capture',['-gSAME_CYCLE=1'])
    for count in range(6):simulate(f'catalog_cache_{count}',media,'tb_fat32_bmp_catalog_five',[f'-gITEMS={count}','-gLAST_ENTRY=1','-gSAME_CYCLE=1'])
    simulate('catalog_reset_during_write',media,'tb_fat32_bmp_catalog_five',['-gRESET_WRITE=1','-gSAME_CYCLE=1'])
    simulate('wav_shared_volume',media,'tb_fat32_wav_reader',['-gUSE_SHARED_VOLUME=1'])
    simulate('bmp_last_fat_byte',media,'tb_bmp_read_fat_chain',['-gFAT_EDGE=1'])
    for offset in (54,488,512,513,1024,65536):
        simulate(f'bmp_window_{offset}',media,'tb_bmp_read_resource_opt',['-gQUICK=1','-gSAME_CYCLE=1',f'-gPIXEL_OFFSET={offset}'])
    integration=compile_group('integration',[
        'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v','E:/AnLuTD/sim_release/eg4/eg_logic_ramfifo.v',
        'prj/al_ip/source_pixel_fifo_ip/RTL/soft_fifo_f9a960ae4922.v','prj/al_ip/source_pixel_fifo_ip/source_pixel_fifo_ip.v',
        'src/test/eg_logic_mult_model.v','src/SD/bmp_bilinear_scaler.v','src/SD/bmp_read.v',
        'src/domain_reset_sync.v','src/fat32_bmp_catalog.v','src/fat32_wav_reader.v','src/sd_sector_arbiter.v',
        'src/media_session_controller.v','src/image_info_metadata.v','src/sd_media_pipeline.v','src/fat32_chart_reader.v','src/rhythm_chart_buffer.v',
        'src/rhythm_sd_resources.v','src/rhythm_block_ram.v','src/test/tb_sd_media_scaler_commit.v','src/test/tb_sd_resource_ready_equivalence.v','src/test/tb_sd_sector_arbiter.v',
        'src/test/tb_sd_registered_response.v','src/test/tb_sd_grant_equivalence.v'],['+define+MEDIA_STARTUP_MODEL'])
    simulate('grant_equivalence',integration,'tb_sd_grant_equivalence')
    simulate('arbiter_fairness',integration,'tb_sd_sector_arbiter')
    for mode in (0,1):simulate(f'arbiter_response_{mode}',integration,'tb_sd_registered_response',[f'-gREGISTER_RESPONSE={mode}'])
    simulate('resource_ready_equivalence',integration,'tb_sd_resource_ready_equivalence')
    simulate('media_scaler_commit',integration,'tb_sd_media_scaler_commit')
    simulate('media_rhythm_shell',integration,'tb_sd_media_scaler_commit',['-gRHYTHM=1'])
if __name__=='__main__':main()
