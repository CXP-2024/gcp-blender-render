#!/bin/bash
# usage: vm_start.sh NPROC START END  -- split frames into NPROC interleaved-chunk units, each a systemd transient unit
N=$1; S=$2; E=$3; H=$HOME
sudo loginctl enable-linger $(id -un)
mkdir -p $H/job/out $H/logs
TOT=$((E-S+1)); CH=$(( (TOT+N-1)/N ))
for i in $(seq 0 $((N-1))); do
  a=$((S+i*CH)); b=$((a+CH-1)); [ $b -gt $E ] && b=$E
  sudo systemd-run --unit=bl$i --uid=$(id -u) --gid=$(id -g) --setenv=HOME=$H --working-directory=$H/job \
    /bin/bash -c "$H/blender52/blender -b -y $H/job/aibo_v32_render.blend -s $a -e $b -a > $H/logs/r$i.log 2>&1"
  echo "unit bl$i frames $a-$b"
done
