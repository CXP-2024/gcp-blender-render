#!/bin/bash
# pack finished frames not yet shipped (non-empty, unchanged for 60 s) into 4 tars ~/ship/batch_K.tar; prints count
cd ~/job/out; mkdir -p ~/ship; touch ~/ship/shipped.txt
find . -name 'f_*.png' -size +0 -mmin +1 -printf '%f\n' | sort > ~/ship/ready.txt
comm -23 ~/ship/ready.txt <(sort ~/ship/shipped.txt) | head -1200 > ~/ship/new.txt
n=$(wc -l < ~/ship/new.txt); rm -f ~/ship/batch_*.tar ~/ship/part_*
if [ "$n" -gt 0 ]; then split -n l/4 -d ~/ship/new.txt ~/ship/part_; for p in ~/ship/part_0*; do k=${p##*_}; tar -cf ~/ship/batch_$k.tar -T $p & done; wait; fi
echo "NEW $n TOTAL $(ls | wc -l) UNITS $(systemctl list-units 'bl*' --no-legend | grep -c running)"
