"""固定 GUI 失败运行的 gate.db，对比 medium/off HFN；不综合、不生成位流。"""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[2]
TAG='20261015'
AUDIT=ROOT/'prj/log'/f'mslice_hfn_same_netlist_{TAG}'
TD='E:/AnLuTD/bin/td_commands_prompt.exe'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def summarize(directory):
    text=(directory/'console.log').read_text(errors='replace')
    result={'directory':str(directory.relative_to(ROOT))}
    result['place_completed']=(directory/'.opt_place.end.f').exists()
    result['route_completed']=(directory/'.opt_route.end.f').exists()
    result['errors']=re.findall(r'^.*\b(?:PHY|RUN|OPT)-\d+ ERROR:.*$',text,re.M)
    result['hfn_settings']=re.findall(r'^.*hfn_opt_effort.*$',text,re.M)
    packs=re.findall(r'(\d+) mslices, (\d+) lslices',text)
    if packs:result['packing']={'mslice':int(packs[-1][0]),'lslice':int(packs[-1][1])}
    duplicates=re.findall(r'\bREG\s*\|\s*(\d+)\s*\|\s*(\d+)',text)
    result['hfn_replication']=[{'drivers':int(a),'copies':int(b)} for a,b in duplicates]
    result['prepack_hfn_effort']=re.findall(r'Start high-fanout net optimization in pre-pack flow with (\w+) effort',text)
    result['no_synthesis_steps']=not any((directory/f'.{step}.begin.f').exists() for step in ['read_design','opt_rtl','opt_gate'])
    result['unpaired_lut']=list(map(int,re.findall(r'(\d+) single LUT\x27s are left',text)))
    result['unpaired_seq']=list(map(int,re.findall(r'(\d+) single SEQ\x27s are left',text)))
    result['capacity_errors']=re.findall(r"Design's mslice number = (\d+), exceeds the limit (\d+)",text)
    for name in ['SD_to_Video_place.timing','SD_to_Video_pr.timing']:
        report=directory/name
        if report.exists():
            timing=report.read_text(errors='replace')
            result[name]={k:float(v) for k,v in re.findall(r'\b(SWNS|STNS|HWNS|HTNS):\s*([-\d.]+)ns',timing)}
    report=directory/'SD_to_Video_phy.area'
    if report.exists():
        area=report.read_text(errors='replace')
        result['area']={k:int(v) for k,v in re.findall(r'^\s*#(lut|reg|bram|bram9k|fifo9k|bram32k|dsp)\s+(\d+)',area,re.M)}
    result['bitgen_started']=(directory/'.bitgen.begin.f').exists()
    return result

def main():
    gui=ROOT/'prj/SD_to_Video_Runs/phy_1'
    gate=ROOT/'prj/SD_to_Video_Runs/syn_1/SD_to_Video_gate.db'
    destinations={mode:ROOT/'prj/log'/f'mslice_hfn_{mode}_{TAG}' for mode in ['medium','off']}
    for path in [AUDIT,*destinations.values()]:
        if path.exists():raise SystemExit(f'Refusing to overwrite {path}')
    AUDIT.mkdir(parents=True)
    for source,name in [(gate,'SD_to_Video_gate.db'),(gui/'SD_to_Video.prj','original_project.prj'),
        (gui/'settings.cfg','original_settings.cfg'),(gui/'SD_to_Video.tcl','original_flow.tcl'),
        (gui/'run.log','original_gui_run.log')]:
        shutil.copy2(source,AUDIT/name)
    for extension in ['area','timing']:
        shutil.copy2(gate.with_suffix('.'+extension),AUDIT/f'original_gate.{extension}')
    # 只读记录全部 RTL/IP、主工程及约束，运行后证明本工具没有更改它们。
    files=set((ROOT/'src').rglob('*.v'))
    for pattern in ['*.al','*.adc','*.sdc']:
        files.update((ROOT/'prj').glob(pattern))
    for pattern in ['*.v','*.vhd','*.tcl']:
        files.update((ROOT/'prj/al_ip').rglob(pattern))
    before={str(p.relative_to(ROOT)):digest(p) for p in sorted(files)}
    baseline={'gate_source':str(gate.relative_to(ROOT)),'gate_sha256':digest(gate),
        'source_and_constraint_sha256':before,'gui_log_sha256':digest(gui/'run.log'),
        'note':'All candidate runs import the frozen database. No synthesis or RTL analysis.'}
    (AUDIT/'input_manifest.json').write_text(json.dumps(baseline,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    project=(AUDIT/'original_project.prj').read_text(encoding='utf-8')
    settings=(AUDIT/'original_settings.cfg').read_text()
    settings=re.sub(r'(?m)^set parent .*',f'set parent ../{AUDIT.name}',settings)
    settings=re.sub(r'(?m)^set start_step .*','set start_step opt_place',settings)
    settings=re.sub(r'(?m)^set end_step .*','set end_step opt_route',settings)
    prepared={}
    for mode,dest in destinations.items():
        dest.mkdir()
        variant=project
        if '<hfn_opt_effort>' in variant:
            variant=re.sub(r'<hfn_opt_effort>.*?</hfn_opt_effort>',f'<hfn_opt_effort>{mode}</hfn_opt_effort>',variant,count=1)
        else:
            assert '<PlaceProperty>' in variant
            variant=variant.replace('<PlaceProperty>',f'<PlaceProperty>\n            <hfn_opt_effort>{mode}</hfn_opt_effort>',1)
        (dest/'SD_to_Video.prj').write_text(variant,encoding='utf-8')
        (dest/'settings.cfg').write_text(settings)
        shutil.copy2(AUDIT/'original_flow.tcl',dest/'SD_to_Video.tcl')
        (dest/'run.tcl').write_text('if {[catch {source SD_to_Video.tcl} task_error]} {puts stderr $task_error; exit 1}\nexit\n')
        prepared[mode]=variant
    assert prepared['medium'].replace('<hfn_opt_effort>medium</hfn_opt_effort>','<hfn_opt_effort>off</hfn_opt_effort>')==prepared['off']
    results={'input_gate_sha256':baseline['gate_sha256'],'only_strategy_difference':'place.hfn_opt_effort medium/off','runs':{}}
    print('Frozen gate.db SHA256: '+baseline['gate_sha256'],flush=True)
    for mode,dest in destinations.items():
        assert digest(AUDIT/'SD_to_Video_gate.db')==baseline['gate_sha256']
        with (dest/'console.log').open('wb') as log:
            run=subprocess.run([TD,'run.tcl'],cwd=dest,stdout=log,stderr=subprocess.STDOUT)
        item=summarize(dest)
        item['process_exit_code']=run.returncode
        assert any(re.search(r'hfn_opt_effort\s*\|\s*'+mode+r'\s*\|',s) for s in item['hfn_settings']),item
        assert not item['bitgen_started']
        results['runs'][mode]=item
        (AUDIT/'comparison.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        print(json.dumps({mode:item},ensure_ascii=False),flush=True)
    results['changed_source_or_constraint_files']=[name for name,sha in before.items() if digest(ROOT/name)!=sha]
    results['frozen_gate_unchanged']=digest(AUDIT/'SD_to_Video_gate.db')==baseline['gate_sha256']
    results['original_gate_unchanged']=digest(gate)==baseline['gate_sha256']
    (AUDIT/'comparison.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    assert not results['changed_source_or_constraint_files'],results['changed_source_or_constraint_files']
    print('COMPLETE same-netlist HFN comparison; inputs unchanged; no bitstream.',flush=True)

if __name__=='__main__':main()
