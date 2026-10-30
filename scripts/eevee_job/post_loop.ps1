# Interpolate + encode 4K60 parts of 300 source frames as soon as each range (plus the next frame) has its SR frames,
# one part at a time, until all 22 parts exist.
$D = 'H:\MV_making\render_jobs\aibo_v32'; Set-Location $D
$py = 'H:\MiniMaxH3\.venv\Scripts\python.exe'; $N = 6581; $PartLen = 300; $parts = [int][math]::Ceiling($N / $PartLen)
while ($true) {
    $next = $null
    for ($p = 0; $p -lt $parts; $p++) {
        if (Test-Path ("post_parts\part_{0:D2}.done" -f $p)) { continue }
        $a = $p * $PartLen; $b = [math]::Min($a + $PartLen, $N); $need = [math]::Min($b, $N - 1)
        $ok = $true; for ($i = $a; $i -le $need; $i++) { if (-not (Test-Path ("sr\f_{0:D4}.png" -f $i))) { $ok = $false; break } }
        if ($ok) { $next = $p; break }
    }
    if ($null -eq $next) {
        if (@(Get-ChildItem post_parts -Filter 'part_*.done').Count -ge $parts) { 'POST_ALL_DONE'; break }
        Start-Sleep 60; continue
    }
    $a = $next * $PartLen; $b = [math]::Min($a + $PartLen, $N)
    & $py post_4k60.py $next $a $b 2>&1 | Select-String 'RIFE_PART_DONE|Error|Traceback|assert' | Out-String
    if ($LASTEXITCODE -eq 0) { New-Item -ItemType File ("post_parts\part_{0:D2}.done" -f $next) | Out-Null }
    else { "part $next failed"; break }
}
