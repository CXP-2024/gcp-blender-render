#!/bin/bash
# encode finished 300-frame runs of ~/job/out into ~/seg/seg_XX.mp4 (RGB x264, CRF 12, no colour conversion), part by part
N=6581; P=300; mkdir -p ~/seg; cd ~/job/out
while true; do
  left=0
  for k in $(seq 0 21); do
    [ -f ~/seg/seg_$(printf %02d $k).mp4 ] && continue
    left=1; a=$((k*P)); b=$((a+P-1)); [ $b -ge $N ] && b=$((N-1)); ok=1
    for i in $(seq $a $b); do f=f_$(printf %04d $i).png; if [ ! -s $f ] || [ -n "$(find $f -mmin -0.5 2>/dev/null)" ]; then ok=0; break; fi; done
    [ $ok = 1 ] || continue
    s=~/seg/seg_$(printf %02d $k)
    ffmpeg -v error -y -framerate 30 -start_number $a -i f_%04d.png -frames:v $((b-a+1)) -c:v libx264rgb -crf 12 -preset medium -pix_fmt rgb24 -threads 16 $s.tmp.mp4 && mv $s.tmp.mp4 $s.mp4 && echo "seg $k done $(ls -la $s.mp4 | awk '{print $5}')" >> ~/logs/seg.log
  done
  [ $left = 0 ] && break; sleep 10
done
echo ALL_SEGS >> ~/logs/seg.log
