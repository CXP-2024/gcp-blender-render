[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('quota', 'status', 'create', 'setup', 'render', 'fetch', 'delete')][string]$Action,
    [string]$Project,
    [string]$Name = 'blender-render',
    [string[]]$Zones = @(
        'us-central1-a', 'us-central1-b', 'us-central1-c',
        'us-east1-b', 'us-east1-c', 'us-east1-d',
        'us-west1-a', 'us-west1-b', 'us-west1-c',
        'asia-east1-a', 'asia-east1-b', 'asia-east1-c',
        'asia-northeast1-a', 'asia-northeast1-b', 'asia-northeast1-c',
        'asia-southeast1-a', 'asia-southeast1-b', 'asia-southeast1-c'),
    [string]$Machine = 'g2-standard-8',
    [int]$DiskGB = 50,
    [string]$DiskType = 'pd-balanced',
    [string]$ImageFamily = 'blender-gpu',
    [int]$MaxHours = 8,
    [switch]$OnDemand,
    [switch]$Yes,
    [switch]$Force,
    [string]$Blend,
    [int]$Start = 1,
    [int]$End = 1,
    [string]$Device = 'OPTIX',
    [string]$Format = 'PNG',
    [string]$Local = '.\renders'
)

$ErrorActionPreference = 'Continue'

# ---- locate gcloud (often not on PATH on Windows) ----
$script:gcloud = (Get-Command gcloud -ErrorAction SilentlyContinue).Source
if (-not $script:gcloud) {
    foreach ($p in @(
            "${env:ProgramFiles(x86)}\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
            "$env:ProgramFiles\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd",
            "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd")) {
        if (Test-Path $p) { $script:gcloud = $p; break }
    }
}
if (-not $script:gcloud) { throw 'gcloud not found. Install: winget install Google.CloudSDK, then gcloud auth login.' }

function G { & $script:gcloud @args 2>&1 | Out-String }

if (-not $Project) { $Project = (& $script:gcloud config get-value project 2>$null | Out-String).Trim() }
if (-not $Project) { throw 'No project. Pass -Project or run: gcloud config set project <id>' }

function Get-Zone {
    $z = (G compute instances list --project $Project --filter "name=$Name" --format "value(zone.basename())").Trim()
    if (-not $z) { throw "Instance '$Name' not found in project $Project." }
    $z
}

function Invoke-Remote([string]$Command) {
    $z = Get-Zone
    G compute ssh $Name --project $Project --zone $z --quiet --strict-host-key-checking=no --command $Command
}

switch ($Action) {

    'quota' {
        $info = G compute project-info describe --project $Project --format json | ConvertFrom-Json
        $all = $info.quotas | Where-Object { $_.metric -eq 'GPUS_ALL_REGIONS' }
        "GPUS_ALL_REGIONS limit=$($all.limit) usage=$($all.usage)"
        if ([double]$all.limit -lt 1) { 'BLOCKER: global GPU quota is 0. See SKILL.md "GPU quota" to request 1.' }
        foreach ($r in 'us-central1', 'us-east1', 'us-west1', 'asia-east1', 'asia-northeast1', 'asia-southeast1') {
            $q = (G compute regions describe $r --project $Project --format json | ConvertFrom-Json).quotas |
                Where-Object { $_.metric -in 'NVIDIA_L4_GPUS', 'PREEMPTIBLE_NVIDIA_L4_GPUS' }
            "$r : " + (($q | ForEach-Object { "$($_.metric)=$($_.limit)" }) -join '  ')
        }
    }

    'status' {
        G compute instances list --project $Project
        G compute disks list --project $Project
    }

    'create' {
        # Prefer the user's own pre-built image (family $ImageFamily, see SKILL.md "Custom image"); fall back to the stock DLVM image.
        $own = (G compute images describe-from-family $ImageFamily --project $Project --format 'value(name)').Trim()
        if ($own -and $own -notmatch 'ERROR|not found') {
            $imgArgs = @('--image', $own, '--image-project', $Project)
            $meta = @()   # never pass install-nvidia-driver: the stock boot script can replace the baked driver
            $imgDesc = "custom image $own (setup NOT needed)"
        } else {
            $image = (G compute images list --project deeplearning-platform-release `
                    --filter "family~'common-cu' AND family~ubuntu-2204" --format 'value(family)').Split("`n") |
                ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique | Select-Object -Last 1
            if (-not $image) { throw 'No Deep Learning VM image family found.' }
            $imgArgs = @('--image-family', $image, '--image-project', 'deeplearning-platform-release')
            $meta = @('--metadata', 'install-nvidia-driver=True')
            $imgDesc = "stock image family $image (run -Action setup afterwards)"
        }
        $model = if ($OnDemand) { 'STANDARD' } else { 'SPOT' }
        "Plan: $Machine, $model, ${DiskGB}GB $DiskType, $imgDesc, auto-stop after ${MaxHours}h, zones tried in order."
        if (-not $Yes) { 'DRY RUN. Add -Yes to create (this starts billing).'; return }
        foreach ($z in $Zones) {
            $out = G compute instances create $Name --project $Project --zone $z --machine-type $Machine `
                @imgArgs --boot-disk-size "${DiskGB}GB" --boot-disk-type $DiskType `
                --maintenance-policy TERMINATE --provisioning-model $model `
                --instance-termination-action STOP --max-run-duration "${MaxHours}h" @meta
            if ($out -match 'RUNNING') { "CREATED in $z"; $out; return }
            $reason = [regex]::Match($out, 'reason: (\w+)').Groups[1].Value
            if (-not $reason) { $reason = 'ERROR: ' + (($out -split "`n" | Where-Object { $_ -match '^\s*-|ERROR' } | Select-Object -First 2) -join ' ').Trim() }
            "$z : $reason"
            if ($out -match 'QUOTA' -or $reason -match 'QUOTA') { "Quota problem, stopping: $out"; return }
        }
        'All zones failed (stockout). Retry later or use -OnDemand.'
    }

    'setup' {
        'Waiting for SSH...'
        for ($i = 0; $i -lt 12; $i++) {
            if ((Invoke-Remote 'echo ready') -match 'ready') { break }
            Start-Sleep 10
        }
        Invoke-Remote 'sudo snap install blender --classic 2>&1 | tail -1'
        Invoke-Remote 'sudo apt-get update -qq; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libxrender1 libxi6 libxxf86vm1 libxfixes3 libxkbcommon0 libsm6 libgl1 libegl1 libxext6 >/dev/null 2>&1; /snap/bin/blender --version | head -1'
        $drv = (Invoke-Remote 'nvidia-smi --query-gpu=driver_version --format=csv,noheader').Trim()
        "Driver: $drv"
        if ($drv -match '^(\d+)\.' -and [int]$Matches[1] -lt 590) {
            'Upgrading driver to 595-server-open (needed for OptiX with Blender 5.x; open module also supports Blackwell) and rebooting...'
            Invoke-Remote 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-driver-595-server-open 2>&1 | tail -2' | Out-Null
            Invoke-Remote 'sudo reboot' | Out-Null
            Start-Sleep 60
            for ($i = 0; $i -lt 12; $i++) {
                $v = (Invoke-Remote 'nvidia-smi --query-gpu=driver_version --format=csv,noheader').Trim()
                if ($v -match '^\d+\.') { "Driver now: $v"; break }
                Start-Sleep 10
            }
        }
        'Setup done.'
    }

    'render' {
        if (-not $Blend -or -not (Test-Path $Blend)) { throw '-Blend <path to .blend> is required and must exist.' }
        $z = Get-Zone
        $dir = Split-Path -Parent (Resolve-Path $Blend)
        $file = Split-Path -Leaf $Blend
        Push-Location $dir
        try { G compute scp $file "${Name}:job.blend" --project $Project --zone $z --quiet --strict-host-key-checking=no | Out-Null }
        finally { Pop-Location }
        # A process started from the SSH session (nohup / setsid / &) is killed when the session ends (verified: Blender
        # died during denoising right after the SSH call returned). Run it as a transient systemd unit instead, with
        # absolute paths (a '~' launcher misbehaved under systemd). Poll the unit, not `pgrep -f` (matches itself).
        $h = (Invoke-Remote 'echo $HOME').Trim().Split("`n")[-1].Trim()
        $launcher = "#!/bin/bash`nH=$h`nmkdir -p `$H/out; rm -f `$H/out/*`nexec /snap/bin/blender -b `$H/job.blend -o `$H/out/f_#### -F $Format -s $Start -e $End -a -- --cycles-device $Device`n"
        $tmp = Join-Path $env:TEMP 'gcp_render_launch.sh'
        [IO.File]::WriteAllText($tmp, $launcher.Replace("`r`n", "`n"))
        Push-Location (Split-Path $tmp)
        try { G compute scp (Split-Path -Leaf $tmp) "${Name}:launch.sh" --project $Project --zone $z --quiet --strict-host-key-checking=no | Out-Null }
        finally { Pop-Location }
        # status.sh holds the pipes/quotes so Windows cmd.exe (gcloud.cmd) never sees them on the command line.
        $statusSh = "#!/bin/bash`nH=$h`nsystemctl is-active blenderrender`nls `$H/out | wc -l`ngrep -E ' Time:' `$H/render.log | tail -1`ngrep -E 'Found no Cycles device|OptiX initialization failed' `$H/render.log | tail -1`n"
        $tmp2 = Join-Path $env:TEMP 'gcp_render_status.sh'
        [IO.File]::WriteAllText($tmp2, $statusSh.Replace("`r`n", "`n"))
        Push-Location (Split-Path $tmp2)
        try { G compute scp (Split-Path -Leaf $tmp2) "${Name}:status.sh" --project $Project --zone $z --quiet --strict-host-key-checking=no | Out-Null }
        finally { Pop-Location }
        # enable-linger keeps /run/user/UID alive after the last SSH session ends (suspected cause of Blender exiting at the denoise step)
        $startCmd = 'H=' + $h + '; sudo loginctl enable-linger $(id -un); chmod +x $H/launch.sh; sudo systemctl reset-failed blenderrender 2>/dev/null; rm -f $H/render.log; ' +
            'sudo systemd-run --unit=blenderrender --uid=$(id -u) --gid=$(id -g) --setenv=HOME=$H --working-directory=$H ' +
            '-p StandardOutput=file:$H/render.log -p StandardError=file:$H/render.log $H/launch.sh'
        Invoke-Remote $startCmd | Out-Null
        'Render started. Polling...'
        $deadline = (Get-Date).AddHours($MaxHours)
        $seenRunning = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep 20
            $s = Invoke-Remote 'bash status.sh'
            $s.Trim()
            if ($s -match '(?m)^active') { $seenRunning = $true; continue }
            if (-not $seenRunning) { 'Unit already finished at the first poll (very fast job) or never started: check the frame count above and the log below.' }
            if ($s -match 'TERMINATED|connection') { 'VM may have been preempted. Check -Action status.' }
            break
        }
        'Last log lines:'
        Invoke-Remote 'tail -n 5 render.log'
    }

    'fetch' {
        $z = Get-Zone
        New-Item -ItemType Directory -Force $Local | Out-Null
        Push-Location $Local
        try { G compute scp --recurse "${Name}:out/*" . --project $Project --zone $z --quiet --strict-host-key-checking=no | Out-Null }
        finally { Pop-Location }
        "Downloaded to $Local : $((Get-ChildItem $Local -File).Count) files"
    }

    'delete' {
        $z = Get-Zone
        $remote = [int](Invoke-Remote 'ls ~/out | wc -l').Trim().Split("`n")[-1]
        $have = (Get-ChildItem $Local -File -ErrorAction SilentlyContinue).Count
        "Remote frames: $remote, local frames: $have"
        if ($remote -eq 0 -and -not $Force) { throw 'No frames on the VM: the render probably failed. Inspect ~/render.log first (do not delete the evidence); -Force overrides.' }
        if ($remote -ne $have -and -not $Force) { throw 'Frame counts differ. Run -Action fetch first, or pass -Force.' }
        if (-not $Yes) { 'DRY RUN. Add -Yes to delete the VM and its disk.'; return }
        G compute instances delete $Name --project $Project --zone $z --quiet
        'Remaining instances / disks:'
        G compute instances list --project $Project
        G compute disks list --project $Project
    }
}
