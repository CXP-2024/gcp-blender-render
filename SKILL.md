---
name: gcp-blender-render
description: Rent a GPU VM on Google Cloud (Compute Engine, NVIDIA L4 or RTX PRO 6000, Spot) with the gcloud CLI, boot it from a pre-built Blender image, render headless with OptiX over SSH, download the frames, and delete the VM to stop billing. Use when the user wants to render Blender / MMD scenes on Google Cloud, use their GCP free-trial credit for rendering, check GPU quota or stockout, build or reuse the custom Blender image, or script instance create / render / delete from the command line instead of the console.
---

# Remote Blender rendering on Google Cloud (gcloud CLI)

Verified end to end: `g2-standard-8` (1x L4 24 GB) and `g4-standard-48` (1x RTX PRO 6000 96 GB), Spot, Ubuntu 22.04,
NVIDIA open kernel driver 595, Blender 5.2.2 LTS (snap), OptiX. Scripts are in `scripts/`; run with Windows PowerShell 5.1.

## Hard rules
- **Creating a VM bills money.** Never create one unless the user asked for it in this conversation.
  `gcp_render.ps1 -Action create` is a dry run unless `-Yes` is passed.
- **Delete the VM when done.** A stopped VM still bills for its disk. The disk is deleted with the VM, so fetch the
  frames first. `-Action delete` refuses when the VM has 0 frames (render probably failed: read `~/render.log`
  before deleting, it is the only evidence) or when local and remote frame counts differ (`-Force` overrides).
- Billing is per second (1 minute minimum). Console/API costs and the free-trial credit balance lag hours to a day
  and cannot be read through the CLI or API. Tell the user to check Billing > Credits / Reports in the console.
- Never store a project id, billing account id, token or email in this repo. Use `-Project` or `gcloud config`.
- **Save money and egress (user rule).** Upload (ingress) is free; every GB downloaded from the VM is billed
  (~0.12 USD/GB, more toward mainland China), and 15 GB of PNG frames cost as much as the whole GPU time once.
  - Never download raw PNG frame sequences. Encode on the VM first to a visually lossless 1080p video
    (`ffmpeg -framerate 30 -i out/f_%04d.png -c:v libx264 -crf 12 -preset slow -pix_fmt yuv444p frames.mp4`,
    ~1 GB per 3.5 min), download that, extract frames locally for SR/RIFE. Download only finished deliverables.
  - Run at the measured best settings from the first minute (local 3-frame test of samples and resolution, 2 EEVEE
    processes per PRO 6000, 32 samples for toon): no mid-run experiments on the billed VM.
  - Prefer a custom image with the needed Blender version baked in; delete the VM the moment the files are verified.
  - Before renting, compare with the local GPU (RTX 5080 ≈ half a PRO 6000 for EEVEE, zero cost) and tell the user the
    estimated VM hours, egress GB and USD.

## Prerequisites
1. Google Cloud CLI. Not necessarily on PATH (Windows: `C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd`); the script finds it.
2. `gcloud auth login` by the user (browser consent, the agent cannot), then `gcloud config set project <id>`.
3. A paid (upgraded) billing account. Free-trial accounts cannot get a GPU; upgrading keeps the trial credit.
4. Compute Engine API enabled and GPU quota (below).

## GPU quota
Per-model quota can be 1 and creation still fails while global `GPUS_ALL_REGIONS` is 0. `-Action quota` checks it.
Raise it without the console: enable `cloudquotas.googleapis.com`, then POST
`https://cloudquotas.googleapis.com/v1/projects/<P>/locations/global/quotaPreferences?quotaPreferenceId=gpus-all-regions`
(headers `Authorization: Bearer $(gcloud auth print-access-token)`, `x-goog-user-project: <P>`; body
`{"service":"compute.googleapis.com","quotaId":"GPUS-ALL-REGIONS-per-project","contactEmail":"<email>","justification":"Blender Cycles rendering","quotaConfig":{"preferredValue":"1"}}`).
It was auto-approved in seconds. It is an account change: ask first.
Newer GPUs do not appear in `gcloud compute regions describe`; list them through the Cloud Quotas API
(`.../services/compute.googleapis.com/quotaInfos`). On the verified account `PREEMPTIBLE-NVIDIA-RTX-PRO-6000-GPUS`
(Spot) was 1 in every region; no non-preemptible RTX PRO 6000 quota was listed (on-demand availability unknown).

## Custom image (do this once, then every VM skips setup)
The script's `create` automatically uses the newest image in family `blender-gpu` in the project, and then
**does not** pass `install-nvidia-driver=True` (that stock boot script can replace the baked driver). Without the
image it falls back to the stock Deep Learning VM image and you must run `-Action setup`.
Build it:
1. `create -Name blender-build -Yes` (L4 Spot), `setup`, then verify an OptiX render works.
2. Clean: `rm -rf ~/out ~/*.blend ~/scene.py ~/render.log ~/.cache ~/.bash_history ~/.ssh/authorized_keys`,
   `sudo apt-get clean`, `sudo journalctl --vacuum-time=1s`.
3. `gcloud compute instances stop blender-build`, then
   `gcloud compute images create blender-gpu-<date> --source-disk=blender-build --source-disk-zone=<z> --family=blender-gpu --storage-location=us`
   (compressed size was about 12 GB; storage is billed monthly, estimate about 1 USD/month, unverified).
4. Delete `blender-build`. The image holds no project files and no credentials.
The driver must be the **open kernel module** (`nvidia-driver-595-server-open`): it works on L4 and is required by
Blackwell (RTX PRO 6000). The same image booted and rendered with OptiX on both cards.

## Workflow
```powershell
$s = "<skill dir>\scripts\gcp_render.ps1"
& $s -Action quota
& $s -Action create                                  # dry run
& $s -Action create -Yes                             # L4 Spot, walks zones until one has capacity
& $s -Action create -Yes -Machine g4-standard-48 -DiskType hyperdisk-balanced   # RTX PRO 6000
& $s -Action setup                                   # ONLY when no custom image exists
& $s -Action render -Blend H:\proj\scene.blend -Start 1 -End 250
& $s -Action fetch -Local H:\proj\renders
& $s -Action delete -Local H:\proj\renders -Yes
```
Preempted Spot VM: `gcloud compute instances start`, then `render` again with `-Start` at the next missing frame.
Disk survives preemption, not `delete`.

## Full-length EEVEE jobs (read first for any song-length render)
[references/eevee-fullsong-multiprocess.md](references/eevee-fullsong-multiprocess.md), scripts in `scripts/eevee_job/`.
Short version: measure 3 frames locally first; lower resolution does not speed EEVEE, samples do (32 is enough for
toon, PSNR > 51 dB, 2x faster); **2 Blender processes per PRO 6000** (6 starve, 12 fill 96 GB VRAM); always `-y`;
pack + repoint MDD caches and diff a frame against the original; download during the render with 4 parallel scp
streams (1 stream ≈ 3 MB/s, 4 ≈ 10 MB/s) — but download an encoded video, not PNGs (`vm_encode.sh`); local Real-CUGAN 2x + RIFE 4K60 overlapped with the render.

## Lessons learned (each cost real time)
- **A process started from the SSH session dies when the session ends** (nohup, setsid and `&` all failed: Blender
  quit exactly at the denoise step, zero frames). `render` runs Blender as a transient systemd unit with absolute
  paths and runs `loginctl enable-linger` first (the user's `/run/user/UID` otherwise vanishes with the last SSH
  session). Keeping an SSH session open (`systemd-run --wait`) also hid the bug, so test with the session closed.
- **G4 machines reject `pd-balanced`**: use `-DiskType hyperdisk-balanced`.
- **The GPU device is a user preference, not stored in the .blend.** Without `-- --cycles-device OPTIX` headless
  Blender silently uses the CPU (nvidia-smi 0 %, about 5 min per simple frame). `render` always passes it.
- **OptiX error 7804** on the stock 580 driver with Blender 5.2: fixed by driver 595 (in the image).
- Missing libs for snap Blender on the stock image: `libxrender1 libxi6 libxxf86vm1 libxfixes3 libxkbcommon0 libsm6 libgl1 libegl1 libxext6`.
- **Windows quoting**: `gcloud` is a `.cmd`, so `|`, `&` and quotes in a `--command` string get eaten by cmd.exe.
  Put such commands in a script file, `scp` it, run `bash file.sh`. `pscp` treats `C:` as a host: `cd` to the local
  folder and use relative local paths; remote paths are relative to home.
- PowerShell variables are case-insensitive: a local `$start` overwrote the `-Start` parameter.
  `Measure-Command { ... }` swallows the script output.
- `gcloud ... --strict-host-key-checking=no` is needed to avoid prompts. A cached-host-key warning appears when a new
  VM reuses an old VM's external IP; expected here.
- Windows PowerShell shows `NativeCommandError` for harmless gcloud progress lines; judge by text and `$LASTEXITCODE`.
- **Spot stockout is common** (us-central1 a/b/c and us-east1 returned `ZONE_RESOURCE_POOL_EXHAUSTED` at times);
  the script walks a zone list. Quota is per region, so other regions work.
- MMD / external-texture scenes: pack resources first (File > External Data > Pack Resources) or upload the folder.
- A 50 GB disk is enough (about 31 GB free after OS, driver, Blender).
- `~/render.log` of Blender under systemd contains a harmless `mkdir: missing operand` line from the snap wrapper.

## Prices (Google's public pricing page, Iowa us-central1; Spot varies daily; machine only, no disk or egress)
| Machine | GPU | Spot | On-demand |
|---|---|---|---|
| g2-standard-8 | 1x L4 24 GB | 0.510832 USD/h | about 0.85 (inferred from the 1-year resource CUD of 0.5378 at 37 % off; the column was hidden) |
| g4-standard-48 | 1x RTX PRO 6000 96 GB | 1.62936 | 4.49993 |
| g4-standard-6 / -12 / -24 | 1/8, 1/4, 1/2 of a PRO 6000 | 0.2342 / 0.4684 / 0.9368 | 0.64688 / 1.29376 / 2.58752 |
Fractional slices cost about 15 % more per unit of compute than the full card and have less VRAM; use the full card
for a single job. The pricing page renders its tables with JavaScript (WebFetch only returns the title); read it in a
real browser or enable `cloudbilling.googleapis.com` and query the Catalog API. Remembered numbers were wrong before
(Spot L4 was assumed 0.3, real 0.51): never quote prices from memory.
With 300 USD: about 587 h of L4 Spot (24 days) or about 184 h of PRO 6000 Spot (7.7 days), before disk/egress and
before any credit already used. The trial credit also expires (usually 90 days).

## Measured performance (test scene: 1080p, 256 samples, glass and metals, OptiX)
- L4: about 15.5 s/frame (about 7 s sampling, about 9 s scene prep and denoise with the GPU idle).
- RTX PRO 6000: first frame 6.2 s, then about 3.3 s/frame (about 4.7x L4 on this light scene).
- Local RTX 5080: 3 frames in 49 s including startup.
- Short frames leave the GPU idle during scene prep and denoise; running 2 Blender processes on disjoint frame ranges
  can recover 10-40 %. Frames of several minutes already saturate the GPU. Check `nvidia-smi` utilisation first.
- Consumer GeForce cards are not offered on Google Cloud.

## 原神 / MMD 材质工作流

涉及原神三渲二场景时，先读 [原神材质提交前检查](references/genshin-material-preflight.md)，并使用 genshin-blender-render 建立多光向全身与脸部试片基线，再执行本文的调度和资源管理。

## MiniMax H3 视频生成

G4 / RTX PRO 6000 也已完成 H3 原生 1920×1088 Ref2VA 短镜头生成。H3 的模型、ComfyUI、两阶段缓存和专用镜像与 Blender 不同，按 [H3 云端工作流记录](../render-submit-queue/references/gcp-pro6000-h3.md) 执行；本 skill 的云实例生命周期工具可复用，但不要运行 Blender setup/render 代替 H3。

