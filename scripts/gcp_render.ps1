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
        $image = (G compute images list --project deeplearning-platform-release `
                --filter "family~'common-cu' AND family~ubuntu-2204" --format 'value(family)').Split("`n") |
            ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique | Select-Object -Last 1
        if (-not $image) { throw 'No Deep Learning VM image family found.' }
        $model = if ($OnDemand) { 'STANDARD' } else { 'SPOT' }
        "Plan: $Machine (1x L4), $model, ${DiskGB}GB pd-balanced, image family $image, auto-stop after ${MaxHours}h, zones tried in order."
        if (-not $Yes) { 'DRY RUN. Add -Yes to create (this starts billing).'; return }
        foreach ($z in $Zones) {
            $out = G compute instances create $Name --project $Project --zone $z --machine-type $Machine `
                --image-family $image --image-project deeplearning-platform-release `
                --boot-disk-size "${DiskGB}GB" --boot-disk-type pd-balanced `
                --maintenance-policy TERMINATE --provisioning-model $model `
                --instance-termination-action STOP --max-run-duration "${MaxHours}h" `
                --metadata install-nvidia-driver=True
            if ($out -match 'RUNNING') { "CREATED in $z"; $out; return }
            $reason = [regex]::Match($out, 'reason: (\w+)').Groups[1].Value
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
            'Upgrading driver to 590-server (needed for OptiX with Blender 5.x) and rebooting...'
            Invoke-Remote 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nvidia-driver-590-server 2>&1 | tail -2' | Out-Null
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
        Invoke-Remote "mkdir -p ~/out; rm -f ~/out/*; nohup /snap/bin/blender -b ~/job.blend -o ~/out/f_#### -F $Format -s $Start -e $End -a -- --cycles-device $Device > ~/render.log 2>&1 &" | Out-Null
        'Render started. Polling...'
        while ($true) {
            Start-Sleep 20
            $s = Invoke-Remote "pgrep -f 'blender -b' >/dev/null && echo RUNNING || echo DONE; ls ~/out | wc -l; grep -E ' Time:' ~/render.log | tail -1; grep -E 'WARNING OptiX|Found no Cycles device' ~/render.log | tail -1"
            $s.Trim()
            if ($s -match 'DONE') { break }
            if ($s -match 'TERMINATED|connection') { 'VM may have been preempted. Check -Action status.'; break }
        }
        'Last log lines:'
        Invoke-Remote 'tail -5 ~/render.log'
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
        if ($remote -ne $have -and -not $Force) { throw 'Frame counts differ. Run -Action fetch first, or pass -Force.' }
        if (-not $Yes) { 'DRY RUN. Add -Yes to delete the VM and its disk.'; return }
        G compute instances delete $Name --project $Project --zone $z --quiet
        'Remaining instances / disks:'
        G compute instances list --project $Project
        G compute disks list --project $Project
    }
}
