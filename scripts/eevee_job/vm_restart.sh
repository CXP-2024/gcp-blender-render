#!/bin/bash
# stop all render units, drop empty placeholders, start N units over the full range (finished frames are skipped)
N=$1; for u in $(systemctl list-units 'bl*' 'bx*' --no-legend --plain | awk '{print $1}'); do sudo systemctl stop $u; done
sleep 3; find ~/job/out -name 'f_*.png' -size 0 -delete; bash ~/vm_start.sh $N 0 6580 | grep unit
sleep 150; bash ~/vm_rate.sh
