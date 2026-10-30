# One 4K60 part worker; run several. A part is claimed by creating post_parts\part_XX.lock (New-Item without -Force
# fails if another worker made it first), finished with part_XX.done; parts with .done or .lock are skipped.
$D = 'H:\MV_making\render_jobs\aibo_v32'; Set-Location $D
$py = 'H:\MiniMaxH3\.venv\Scripts\python.exe'; $N = 6581; $PartLen = 300; $parts = [int][math]::Ceiling($N / $PartLen)
while ($true) {
    $mine = $null
    for ($k = 0; $k -lt $parts; $k++) {
        $done = "post_parts\part_{0:D2}.done" -f $k; $lock = "post_parts\part_{0:D2}.lock" -f $k
        if ((Test-Path $done) -or (Test-Path $lock)) { continue }
        try { New-Item -ItemType File $lock -ErrorAction Stop | Out-Null; $mine = $k; break } catch { continue }
    }
    if ($null -eq $mine) { 'WORKER_DONE'; break }
    $a = $mine * $PartLen; $b = [math]::Min($a + $PartLen, $N)
    & $py post_4k60.py $mine $a $b 2>&1 | Select-String 'RIFE_PART_DONE|Error|Traceback|assert' | Out-String
    if ($LASTEXITCODE -eq 0) { New-Item -ItemType File ("post_parts\part_{0:D2}.done" -f $mine) -Force | Out-Null }
    else { "part $mine failed"; Remove-Item ("post_parts\part_{0:D2}.mp4" -f $mine) -ErrorAction SilentlyContinue }
    Remove-Item ("post_parts\part_{0:D2}.lock" -f $mine) -ErrorAction SilentlyContinue
}
