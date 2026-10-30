#!/bin/bash
# verify every 4K60 part (2 output frames per source frame), concat without re-encoding, add the song (strip starts at
# frame 1 = 1/30 s), write the delivery mp4 next to the v32 blend.
set -e; cd H:/MV_making/render_jobs/aibo_v32; FB=${FFMPEG_DIR:?set FFMPEG_DIR to the folder with ffmpeg.exe/ffprobe.exe}
OUT="H:/MV_making/天天天国/aibo_replica/DeepSeek_Aibo_v32_4K60.mp4"; : > parts.txt; bad=0
for p in $(seq 0 21); do
  f=post_parts/part_$(printf %02d $p).mp4; a=$((p*300)); b=$((a+300)); [ $b -gt 6581 ] && b=6581
  n=$($FB/ffprobe.exe -v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets -of csv=p=0 $f)
  [ "$n" -eq $(( (b-a)*2 )) ] || { echo "BAD $f $n"; bad=1; }; echo "file '$f'" >> parts.txt
done
[ $bad -eq 0 ] || exit 1
$FB/ffmpeg.exe -v warning -y -f concat -safe 0 -i parts.txt -itsoffset 0.0333333 -i "H:/MV_making/天天天国/aibo_replica/audio/Aipai_audio_full_f19.m4a" \
  -map 0:v -map 1:a -c:v copy -c:a aac -b:a 256k -movflags +faststart "$OUT"
$FB/ffprobe.exe -v error -show_entries format=duration,size:stream=codec_name,width,height,r_frame_rate -of compact "$OUT"
