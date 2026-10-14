"""中文图片OSD、元数据和保留控制回归；不生成位流。"""
from pathlib import Path
import re, shutil, subprocess
from PIL import Image
from generate_image_osd_font import make_font, HANZI, ASCII

root=Path(__file__).resolve().parents[2]
output=root/'prj/log/image_osd_20261014'
output.mkdir(parents=True,exist_ok=True)
def run(name,command,passed=False):
    log=output/(name+'.log')
    with log.open('wb') as stream:result=subprocess.run(command,cwd=root,stdout=stream,stderr=subprocess.STDOUT,timeout=600)
    text=log.read_text(errors='replace')
    if result.returncode or re.search(r'\*\* (?:Error|Fatal):|Errors: [1-9]|\bFAIL\b',text) or passed and 'PASS' not in text:
        raise RuntimeError(name+'\n'+'\n'.join(text.splitlines()[-18:]))
    print(name+': '+'; '.join(line for line in text.splitlines() if 'PASS' in line or 'Errors:' in line),flush=True)

library=str(output/'work')
if not Path(library).exists():run('library',[shutil.which('vlib'),library])
modules=['rhythm_block_ram','image_info_metadata','image_info_osd','image_osd_font','video_presentation','ring_spectrum_renderer',
         'pcm_audio_player','media_session_controller','image_controls']
cases=['tb_image_info_metadata','tb_image_info_video','tb_pcm_audio_player','tb_audio_playback_control','tb_image_controls']
run('compile',[shutil.which('vlog'),'-work',library,'E:/AnLuTD/sim_release/eg4/eg_logic_bram.v','src/test/eg_logic_mult_model.v',
    *[str(root/'src'/(name+'.v')) for name in modules],*[str(root/'src/test'/(name+'.v')) for name in cases]])
for case in cases:run(case,[shutil.which('vsim'),'-c','-lib',library,case,'-do','src/test/run_startup_regression.do'],True)
for name in ['default','adjusted','switched']:
    path=output/(name+'.ppm')
    with Image.open(path) as image:image.save(output/(name+'.png'))
font,_=make_font()
labels=['输入分辨率','输出分辨率','水平缩放','垂直缩放','亮度','对比度']
for name in ['default','adjusted','switched']:
    values=['1920×1080',' 640× 480','   33.33%','   44.44%',
            ' 50/100' if name=='default' else ' 75/100',
            ' 50/100' if name=='default' else ' 25/100']
    if name=='switched':values[:4]=[' 320× 240',' 640× 480','  200.00%','  200.00%']
    with Image.open(output/(name+'.png')) as image:
        for row,(label,value) in enumerate(zip(labels,values)):
            color=(255,223,64) if row==(4 if name=='default' else 5) else (255,255,255)
            # 外部字形参考逐位核对文字标签和数值，捕获缺字、错误位序和数字错配。
            for text,start,width in [(label,416,16),(value,512,8)]:
                for column,char in enumerate(text):
                    offset=HANZI.index(char)*16 if width==16 else 256+ASCII.index(char)*16
                    for y in range(16):
                        for x in range(width):
                            expected=bool(font[offset+y] & (1<<(15-x)))
                            observed=image.getpixel((start+column*width+x,24+row*24+y))==color
                            assert observed==expected, (name,row,char,x,y)
print('PASS captured Chinese labels and all numeric fields against external glyph reference',flush=True)
print('PASS image OSD regression; previews: '+str(output),flush=True)
