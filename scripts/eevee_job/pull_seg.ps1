# Pull finished segments (seg_XX.mp4, RGB x264 CRF 12) from the VM, up to 4 at a time, unpack each to frames\ through a
# temp folder (frames appear atomically), then 2x Real-CUGAN them into sr\. Stops when all 22 segments are local.
$g = "C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd"; $z = 'us-central1-b'; $D = 'H:\MV_making\render_jobs\aibo_v35'
$ff = 'ffmpeg'; $rc = 'H:\MV_making\senren_ai_op\tools\realcugan\realcugan-ncnn-vulkan-20220728-windows'
Set-Location $D; New-Item -ItemType Directory -Force frames, sr, seg | Out-Null
while ($true) {
    $have = @(Get-ChildItem seg -Filter 'seg_*.done').Count
    if ($have -ge 22) { 'DONE'; break }
    $ls = & $g compute ssh aibo-v35 --zone $z --quiet --strict-host-key-checking=no --command "ls seg | grep -v tmp; tail -1 logs/seg.log; ls job/out | wc -l" 2>&1 | Out-String
    $names = [regex]::Matches($ls, 'seg_\d\d\.mp4') | ForEach-Object { $_.Value } | Sort-Object -Unique
    $todo = @($names | Where-Object { -not (Test-Path ("seg\" + $_.Replace('.mp4', '.done'))) } | Select-Object -First 4)
    if (-not $todo) { "$(Get-Date -f HH:mm:ss) waiting, local segs $have"; Start-Sleep 30; continue }
    $t = Get-Date
    $procs = foreach ($n in $todo) { Start-Process -FilePath $g -ArgumentList @('compute','scp',"aibo-v35:seg/$n","seg/$n",'--zone',$z,'--quiet','--strict-host-key-checking=no') -NoNewWindow -PassThru -RedirectStandardError "seg\$n.err" -RedirectStandardOutput "seg\$n.out" }
    $procs | Wait-Process
    foreach ($n in $todo) {
        $k = [int]$n.Substring(4, 2); $a = $k * 300; $tmp = "seg\x_$k"; New-Item -ItemType Directory -Force $tmp | Out-Null
        & $ff -v error -y -i "seg\$n" -start_number $a "$tmp\f_%04d.png"
        $c = (Get-ChildItem $tmp -Filter 'f_*.png').Count; $want = [math]::Min(300, 6581 - $a)
        if ($c -ne $want) { "seg $k bad count $c"; Remove-Item $tmp -Recurse -Force; continue }
        & "$rc\realcugan-ncnn-vulkan.exe" -i $tmp -o sr -s 2 -n 0 -m "$rc\models-pro" -g 0 -j 2:2:2 2>&1 | Out-Null
        Get-ChildItem $tmp -Filter 'f_*.png' | Move-Item -Destination frames -Force
        Remove-Item $tmp -Recurse -Force; New-Item -ItemType File ("seg\" + $n.Replace('.mp4', '.done')) -Force | Out-Null
    }
    $mb = [int](($todo | ForEach-Object { (Get-Item "seg\$_").Length } | Measure-Object -Sum).Sum / 1MB)
    "$(Get-Date -f HH:mm:ss) got $($todo -join ' ') ($mb MB) in $([int]((Get-Date)-$t).TotalSeconds)s, local segs $((Get-ChildItem seg -Filter 'seg_*.done').Count)"
}
