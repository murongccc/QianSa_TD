"""对照旧 32 段插值与直接 FFT 的同一音乐帧，输出统计和 RTL 预览输入。"""
import sys
sys.dont_write_bytecode=True
import argparse
import json
from pathlib import Path
import numpy as np
from analyze_ring_visual import lengths


def summary(bars,levels=None):
    result={"frames":len(bars),"mean_frame_change_px":float(np.abs(np.diff(bars,axis=0)).mean()),
            "mean_adjacent_difference_px":float(np.abs(np.diff(bars,axis=1)).mean()),
            "mean_seam_difference_px":float(np.abs(bars[:,0]-bars[:,-1]).mean()),
            "maximum_bar_length_px":int(bars.max())}
    if levels is not None:
        result["clipped_bar_ratio"]=float((levels==240).mean())
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("before",type=Path);p.add_argument("after",type=Path);p.add_argument("output",type=Path)
    args=p.parse_args()
    before=np.loadtxt(args.before,delimiter=",",skiprows=1).astype(int)
    after=np.loadtxt(args.after,delimiter=",",skiprows=1).astype(int)
    assert np.array_equal(before[:,0],after[:,0])
    levels=after[:,1:]
    bars=np.where(levels.any(axis=1)[:,None],np.maximum(levels>>2,2),0)
    frames=[]
    for index in [100,413]:
        frames.append({"sample":int(after[index,0]),"seconds":float(after[index,0]/48000),
            "before_bands":f"{sum(int(v)<<(8*i) for i,v in enumerate(before[index,1:])):064x}",
            "after_bars":f"{sum(int(v)<<(8*i) for i,v in enumerate(levels[index])):0160x}"})
    result={"input":"src/python/1.wav, 48 kHz 24-bit stereo, left channel raw volume",
            "fft_points":512,"sample_rate":48000,"frequency_spacing_hz":93.75,
            "highest_bar_target_hz":float((320**(79/80)-1)*44100/2048),
            "before":summary(lengths(before[:,1:],True)),"after":summary(bars,levels),
            "preview_frames":frames,
            "note":"Same source samples; reference-mode compression changes scale. No board-level audio/volume simulation."}
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({k:result[k] for k in ["before","after"]},indent=2))


if __name__=="__main__":main()
