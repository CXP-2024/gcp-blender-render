#!/bin/bash
# encoder benchmark on 300 SR 4K frames (f_0000..f_0299) at 60 fps: wall time, size, SSIM/PSNR vs the PNG source
FB=${FFMPEG_DIR:?set FFMPEG_DIR}; cd H:/MV_making/render_jobs/aibo_v32; mkdir -p bench
IN="-framerate 60 -start_number 0 -i sr/f_%04d.png -frames:v 300"
run() { n=$1; shift; s=$(date +%s%N); $FB/ffmpeg.exe -v error -y $IN "$@" -pix_fmt yuv420p bench/$n.mp4; e=$(date +%s%N)
  q=$($FB/ffmpeg.exe -v info -i bench/$n.mp4 -framerate 60 -start_number 0 -i sr/f_%04d.png -frames:v 300 -lavfi "[0:v][1:v]ssim" -f null - 2>&1 | grep -o "All:[0-9.]* ([0-9.]*)")
  echo "$n time $(( (e-s)/1000000 ))ms size $(( $(stat -c %s bench/$n.mp4)/1024/1024 ))MB ssim $q"; }
run x264_crf18_medium -c:v libx264 -crf 18 -preset medium -threads 8
run h264_nvenc_cq19 -c:v h264_nvenc -preset p7 -tune hq -rc vbr -cq 19 -b:v 0 -spatial-aq 1 -temporal-aq 1
run hevc_nvenc_cq21 -c:v hevc_nvenc -preset p7 -tune hq -rc vbr -cq 21 -b:v 0 -spatial-aq 1 -temporal-aq 1
run av1_nvenc_cq26 -c:v av1_nvenc -preset p7 -tune hq -rc vbr -cq 26 -b:v 0
run h264_nvenc_cq25 -c:v h264_nvenc -preset p7 -tune hq -rc vbr -cq 25 -b:v 0 -spatial-aq 1 -temporal-aq 1
run hevc_nvenc_cq18 -c:v hevc_nvenc -preset p7 -tune hq -rc vbr -cq 18 -b:v 0 -spatial-aq 1 -temporal-aq 1
s=$(date +%s%N); $FB/ffmpeg.exe -v error $IN -f null -; e=$(date +%s%N); echo "png decode only $(( (e-s)/1000000 ))ms"
