#!/bin/bash
set -e
cd ~
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
df -h / | tail -1
sudo growpart /dev/nvme0n1 1 2>/dev/null || true; sudo resize2fs /dev/nvme0n1p1 2>/dev/null || true; df -h / | tail -1
sudo apt-get -qq install -y libxrender1 libxi6 libxxf86vm1 libxfixes3 libxkbcommon0 libsm6 libgl1 libegl1 libxext6 >/dev/null 2>&1 || true
if [ ! -x ~/blender52/blender ]; then
  curl -sSL -o b.tar.xz https://download.blender.org/release/Blender5.2/blender-5.2.1-linux-x64.tar.xz
  mkdir -p blender52 && tar -xf b.tar.xz -C blender52 --strip-components=1 && rm b.tar.xz
fi
~/blender52/blender --version | head -1
nproc; free -g | head -2
