#!/bin/bash
a=$(find ~/job/out -name 'f_*.png' -size +0 | wc -l); sleep 120; b=$(find ~/job/out -name 'f_*.png' -size +0 | wc -l)
echo "RATE $(( (b-a) )) frames/120s total $b"; nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader; free -g | sed -n 2p; uptime
