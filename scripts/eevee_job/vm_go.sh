#!/bin/bash
mkdir -p ~/job && tar -xf pack.tar -C ~/job && rm pack.tar; du -sh ~/job; command -v ffmpeg >/dev/null || sudo apt-get -qq install -y ffmpeg >/dev/null 2>&1; ffmpeg -version | head -1; ffmpeg -hide_banner -encoders 2>/dev/null | grep -c libx264rgb
mkdir -p ~/logs; bash ~/vm_start.sh 2 0 6580 | grep unit
sudo systemd-run --unit=segenc --uid=$(id -u) --gid=$(id -g) --setenv=HOME=$HOME /bin/bash $HOME/vm_seg.sh
