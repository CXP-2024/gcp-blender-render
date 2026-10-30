#!/bin/bash
nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader
nvidia-smi --query-gpu=utilization.gpu,clocks.sm,clocks.mem,temperature.gpu,power.draw,clocks_throttle_reasons.active --format=csv
top -b -n1 | head -20
for f in ~/logs/r*.log; do echo "== $f"; tail -c 400 $f | tr '\r' '\n' | tail -3; done
