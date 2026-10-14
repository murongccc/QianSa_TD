"""核对综合网表中中文OSD的512个ROM初始化字，不生成位流。"""
from pathlib import Path
import argparse,re,subprocess

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build',type=Path,default=Path('prj/log/image_osd_final_syn_20261014'))
    parser.add_argument('--td',default='E:/AnLuTD/bin/td_commands_prompt.exe')
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2];build=(root/args.build).resolve()
    script=build/'check_image_font.tcl'
    script.write_text('if {[catch {\nimport_device eagle_s20.db -package EG4S20BG256\n'
        'open_project SD_to_Video.prj -noanalyze\nimport_db SD_to_Video_gate.db\n'
        'write_verilog image_font_mapped.v\n} err]} {puts stderr $err;exit 1}\nexit\n')
    with (build/'image_font_mapped_console.log').open('wb') as stream:
        result=subprocess.run([args.td,script.name],cwd=build,stdout=stream,stderr=subprocess.STDOUT,timeout=180)
    mapped=build/'image_font_mapped.v'
    if result.returncode or not mapped.exists():raise RuntimeError('字库综合网表导出失败')
    blocks=[block for block in re.split(r'(?m)^\s*// ',mapped.read_text())
            if 'u_font/' in block.split('\n',1)[0] and 'EG_PHY_BRAM' in block]
    assert len(blocks)==1, [block.split('\n',1)[0] for block in blocks]
    block=blocks[0]
    assert re.search(r'\.DATA_WIDTH_A\("18"\)',block), '应映射为512x18物理BRAM'
    init={key.upper():int(value,16) for key,value in re.findall(r"\.(INIT_[0-9A-F]+)\(256'h([0-9A-F]+)\)",block,re.I)}
    assert len(init)==32, '应含32组256位数据初始化值'
    packed=sum(init[f'INIT_{i:02X}']<<(256*i) for i in range(32))
    parity_init={key.upper():int(value,16) for key,value in re.findall(r"\.(INITP_[0-9A-F]+)\(256'h([0-9A-F]+)\)",block,re.I)}
    assert len(parity_init)==4
    parity=sum(parity_init[f'INITP_{i:02X}']<<(256*i) for i in range(4))
    expected=[0]*512
    source=(root/'src/image_osd_font.v').read_text(encoding='utf-8')
    for address,value in re.findall(r"rows\[9'd(\d+)\]=16'h([0-9a-f]+)",source):expected[int(address)]=int(value,16)
    for address,value in enumerate(expected):
        # PDPW8K将逻辑低9位放DOA、高7位放DOB；第9位位于INITP的A奇偶位。
        raw=(packed>>(16*address))&65535
        actual=(raw&255)|(((parity>>(2*address))&1)<<8)|(((raw>>8)&127)<<9)
        assert actual==value,(address,hex(actual),hex(value))
    print('PASS mapped Chinese OSD font: one BRAM9K, all 512 initialized 16-bit words exact')

if __name__=='__main__':main()
