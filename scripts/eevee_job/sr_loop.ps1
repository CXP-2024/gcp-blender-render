# Real-CUGAN 2x (models-pro up2x-no-denoise) for every pulled frame without an SR result, in batches, until the
# pull loop has written DONE and every frame has its 4K version.
$D = 'H:\MV_making\render_jobs\aibo_v32'; Set-Location $D
$rc = 'H:\MV_making\senren_ai_op\tools\realcugan\realcugan-ncnn-vulkan-20220728-windows'
New-Item -ItemType Directory -Force sr | Out-Null
while ($true) {
    $done = (Test-Path pull3.log) -and (Select-String -Path pull3.log -Pattern '^DONE' -Quiet)
    $todo = Get-ChildItem frames -Filter 'f_*.png' | Where-Object { -not (Test-Path "sr\$($_.Name)") } | Select-Object -First 600
    if (-not $todo) { if ($done) { 'SR_ALL_DONE'; break }; Start-Sleep 60; continue }
    if (Test-Path sr_todo) { Remove-Item sr_todo -Recurse -Force }
    New-Item -ItemType Directory sr_todo | Out-Null
    foreach ($f in $todo) { New-Item -ItemType HardLink -Path "sr_todo\$($f.Name)" -Target $f.FullName | Out-Null }
    $t = Get-Date
    & "$rc\realcugan-ncnn-vulkan.exe" -i sr_todo -o sr -s 2 -n 0 -m "$rc\models-pro" -g 0 -j 2:2:2 2>&1 | Out-Null
    "$(Get-Date -f HH:mm:ss) SR batch $($todo.Count) in $([int]((Get-Date)-$t).TotalSeconds)s, total sr $((Get-ChildItem sr -Filter 'f_*.png').Count)"
}
