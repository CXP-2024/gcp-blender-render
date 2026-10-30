#!/bin/bash
ls ~/job/out | wc -l
for f in ~/logs/r*.log; do echo "$f $(grep -c Saved $f) $(grep -m1 -i 'error\|segmentation' $f | grep -v visible_objects | head -c 150)"; done
nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader; uptime
systemctl list-units 'bl*' --no-legend | wc -l
