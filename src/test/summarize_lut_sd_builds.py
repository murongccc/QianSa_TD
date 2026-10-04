"""保存优化前后的小型资源/时序快照；完整厂商报告仍保留在 prj/log。"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re


def summarize(build):
    area=(build/'SD_to_Video_gate.area').read_text()
    timing=(build/'SD_to_Video_gate.timing').read_text()
    console=(build/'console.log').read_text(errors='replace')
    result={'directory':build.as_posix(),'resources':{},'modules':{},'clocks':{}}
    for key in ['lut','reg','bram9k','fifo9k','bram32k','dsp']:
        result['resources'][key]=int(re.search(r'^\s*#'+key+r'\s+(\d+)',area,re.M)[1])
    for line in area.splitlines():
        fields=[value.strip() for value in line.split('|')]
        if len(fields)>7 and fields[2] in ['sd_sector_arbiter','fat32_chart_reader','fat32_wav_reader',
            'bmp_read','fat32_bmp_catalog','bmp_bilinear_scaler','rhythm_hud','ring_spectrum_renderer']:
            result['modules'][fields[2]]={'lut':int(fields[3])+int(fields[4]),
                'registers':int(fields[5]),'bram':int(fields[6]),'dsp':int(fields[7])}
    for line in timing.splitlines():
        fields=line.split()
        if len(fields)==17 and re.fullmatch(r'clk\d+',fields[0]) and fields[1]=='local':
            result['clocks'][fields[0]]={key:float(fields[index]) for key,index in
                [('frequency_mhz',5),('fmax_mhz',7),('setup_wns_ns',8),('setup_tns_ns',9),('hold_wns_ns',10),('hold_tns_ns',11)]}
    result['setup_wns_ns']=float(re.search(r'SWNS:\s*([-\d.]+)ns',timing)[1])
    result['setup_tns_ns']=float(re.search(r'STNS:\s*([-\d.]+)ns',timing)[1])
    result['hold_wns_ns']=float(re.search(r'HWNS:\s*([-\d.]+)ns',timing)[1])
    result['hold_tns_ns']=float(re.search(r'HTNS:\s*([-\d.]+)ns',timing)[1])
    result['sta_coverage_percent']=float(re.search(r'STA coverage\s*:\s*([\d.]+)%',timing)[1])
    result['warnings']=dict(Counter(re.findall(r'((?:SYN|HDL)-\d+) WARNING',console)))
    section=timing.split('Path Group     :     sd_card_clk -> sd_card_clk',1)[1]
    result['first_sd_path']={key:re.search(r'^'+key+r'\s*:\s*(.*)',section,re.M)[1] for key in
        ['Slack','Begin Point','End Point','Data Path Delay','Logic Level']}
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('builds',nargs='+',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    reports=[summarize(build) for build in args.builds]
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(reports,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    for report in reports:
        print(report['directory'],report['resources'],'WNS',report['setup_wns_ns'],'warnings',sum(report['warnings'].values()))


if __name__=='__main__':
    main()
