# Pull finished frames from the VM in batches until the render units are gone and nothing new remains.
$g = "C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd"; $z = 'us-central1-c'; $D = 'H:\MV_making\render_jobs\aibo_v32'
Set-Location $D; New-Item -ItemType Directory -Force frames | Out-Null
function Ssh($c) { (& $g compute ssh aibo-v32 --zone $z --quiet --strict-host-key-checking=no --command $c 2>&1 | Out-String) }
while ($true) {
    $st = ([regex]::Match((Ssh 'bash vm_ship.sh'), 'NEW (\d+) TOTAL (\d+) UNITS (\d+)'))
    if (-not $st.Success) { "$(Get-Date -f HH:mm:ss) ssh failed, retry in 60 s"; Start-Sleep 60; continue }
    $n = [int]$st.Groups[1].Value; $u = [int]$st.Groups[3].Value
    "$(Get-Date -f HH:mm:ss) new $n remote total $($st.Groups[2].Value) running units $u"
    if ($n -gt 0) {
        $ok = $true
        $procs = foreach ($k in '00','01','02','03') {
            Remove-Item "batch_$k.tar" -ErrorAction SilentlyContinue
            Start-Process -FilePath $g -ArgumentList @('compute','scp',"aibo-v32:ship/batch_$k.tar","batch_$k.tar",'--zone',$z,'--quiet','--strict-host-key-checking=no') -NoNewWindow -PassThru -RedirectStandardError "scp_$k.err" -RedirectStandardOutput "scp_$k.out"
        }
        $procs | Wait-Process
        foreach ($k in '00','01','02','03') {
            if ((Test-Path "batch_$k.tar") -and ((Get-Item "batch_$k.tar").Length -gt 0)) { tar -xf "batch_$k.tar" -C frames; if ($LASTEXITCODE -ne 0) { $ok = $false } else { Remove-Item "batch_$k.tar" } }
        }
        if ($ok) { Ssh 'bash vm_ack.sh' | Out-Null }
        "  local frames $((Get-ChildItem frames -Filter 'f_*.png').Count)"
    } elseif ($u -eq 0) { 'DONE'; break }
    else { Start-Sleep 300 }
}
