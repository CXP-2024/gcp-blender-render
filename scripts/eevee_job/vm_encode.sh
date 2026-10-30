#!/bin/bash
# Egress saver: pack the finished 1080p frame sequence into one visually lossless video on the VM (download ~1 GB
# instead of ~15 GB of PNG). Locally: ffmpeg -i frames.mp4 -start_number 0 frames/f_%04d.png
# usage: vm_encode.sh [START=0] [FPS=30]
S=${1:-0}; F=${2:-30}; cd ~/job/out
command -v ffmpeg >/dev/null || sudo apt-get -qq install -y ffmpeg >/dev/null
ffmpeg -v warning -y -framerate $F -start_number $S -i f_%04d.png -c:v libx264 -crf 12 -preset slow -pix_fmt yuv444p \
  -x264-params keyint=60 ~/frames.mp4 && ls -la ~/frames.mp4
