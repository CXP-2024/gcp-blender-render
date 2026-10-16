---
name: gcp-blender-render
description: Rent a GPU VM on Google Cloud (Compute Engine, NVIDIA L4 Spot) with the gcloud CLI, install headless Blender 5.x with working OptiX/CUDA Cycles, render over SSH, download the frames, and delete the VM to stop billing. Use when the user wants to render Blender / MMD scenes on Google Cloud, use their GCP free-trial credit for rendering, check GPU quota or stockout, or script instance create / render / delete from the command line instead of the console.
---

# Remote Blender rendering on Google Cloud (gcloud CLI)

Verified end to end on an `g2-standard-8` (8 vCPU, 32 GB, 1x NVIDIA L4 24 GB) Spot VM, Ubuntu 22.04 Deep Learning
image, Blender 5.2.2 LTS (snap). Scripts are in `scripts/`; run them with Windows PowerShell 5.1.

## Hard rules
- **Creating a VM bills money.** Never create one unless the user asked for it in this conversation.
  `gcp_render.ps1 -Action create` is a dry run (prints the plan) unless `-Yes` is passed.
- **Delete the VM when done.** A stopped VM still bills for its disk. The system disk is deleted with the VM, so
  fetch the frames first. `-Action delete` refuses when the local frame count differs from the remote one
  (override with `-Force` only if the user says so).
- Billing is per second (1 minute minimum). The console and API show costs only hours to a day late, and the
  free-trial credit figure cannot be read through the CLI or API. Do not promise exact spend; tell the user to look
  at Billing > Credits / Reports in the console.
- Never store a project id, billing account id, or token in this repo. Use `-Project` or `gcloud config`.

## Prerequisites
1. Google Cloud CLI installed. It may not be on PATH (Windows default:
   `C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd`); the script finds it.
2. `gcloud auth login` done by the user (browser consent; the agent cannot do this) and
   `gcloud config set project <id>`.
3. A paid (upgraded) billing account. Free-trial accounts cannot get a GPU. Upgrading keeps the trial credit.
4. Compute Engine API enabled and GPU quota (see below).

## GPU quota (the usual blocker)
Even with per-model quota of 1 (e.g. `NVIDIA_L4_GPUS`), VM creation fails while the global
`GPUS_ALL_REGIONS` quota is 0. Check with `gcp_render.ps1 -Action quota`. To raise it without the console:

1. `gcloud services enable cloudquotas.googleapis.com`
2. POST to `https://cloudquotas.googleapis.com/v1/projects/<PROJECT>/locations/global/quotaPreferences?quotaPreferenceId=gpus-all-regions`
   with header `Authorization: Bearer $(gcloud auth print-access-token)` and `x-goog-user-project: <PROJECT>`, body
   `{"service":"compute.googleapis.com","quotaId":"GPUS-ALL-REGIONS-per-project","contactEmail":"<email>","justification":"Blender Cycles rendering","quotaConfig":{"preferredValue":"1"}}`.
   (`gcloud beta quotas` needs an interactive component install; the REST call avoids that.)
   It was auto-approved in seconds. Submitting it is an account change: ask the user first.

## Workflow
```powershell
$s = "<skill dir>\scripts\gcp_render.ps1"
& $s -Action quota                                  # check GPU quota
& $s -Action create                                 # dry run: shows plan
& $s -Action create -Yes                            # tries zones until one has capacity
& $s -Action setup                                  # libs + Blender + driver upgrade (reboots if needed)
& $s -Action render -Blend H:\proj\scene.blend -Start 1 -End 250
& $s -Action fetch -Local H:\proj\renders           # download ~/out
& $s -Action delete -Local H:\proj\renders -Yes     # verifies frame count, then deletes VM + disk
```
`render` runs Blender under `nohup` and polls, so a dropped SSH session does not kill it. If a Spot VM is
preempted (status TERMINATED), `gcloud compute instances start` it and re-run `render` with `-Start` set to the
next missing frame. Disk contents survive preemption; they do not survive `delete`.

## Lessons learned (each one cost real time)
- **Spot stockout is common.** us-central1-a/b/c and us-west1-b/c returned `ZONE_RESOURCE_POOL_EXHAUSTED`; the
  script walks a zone list. Quota is per region (1 L4 each), so other regions work. On-demand (`-OnDemand`) is
  about 2.5x the price but avoids preemption.
- **The GPU device is a user preference, not stored in the .blend.** Without `-- --cycles-device OPTIX` after the
  Blender args, headless Blender silently renders on CPU (symptom: `nvidia-smi` shows 0 %, CPU at 800 %, about
  5 min per simple frame). `render` always passes the flag.
- **OptiX fails with `error code 7804`** on the image's stock driver (580.x) with Blender 5.2. Upgrading to
  `nvidia-driver-590-server` from apt (installed 595.x) and rebooting fixed it. `setup` does this when the
  driver major version is below 590. CUDA works on the stock driver if OptiX is not needed.
- **Missing shared libs** for snap Blender on the image: `libxrender1 libxi6 libxxf86vm1 libxfixes3 libxkbcommon0
  libsm6 libgl1 libegl1 libxext6`.
- **`gcloud compute scp` uses pscp on Windows, which treats `C:` as a host name.** Always `cd` to the local folder
  and use relative local paths; remote paths are relative to the home directory (`blender-render:scene.blend`).
- `gcloud compute ssh --quiet --strict-host-key-checking=no` avoids interactive prompts; the first call creates
  an SSH key and adds it to project metadata (mention this to the user).
- Windows PowerShell shows `NativeCommandError` for any gcloud stderr line, including successful progress
  messages. Judge by output text and `$LASTEXITCODE`, not by that error.
- **MMD / external-texture scenes**: pack resources first (File > External Data > Pack Resources) or upload the
  whole folder, otherwise textures render pink/black.
- A 100 GB disk is not needed: 50 GB pd-balanced leaves about 32 GB free after OS, driver and Blender.

## Benchmark and cost (estimates, not billing data)
- Test scene (1080p, 256 samples, glass + metals): L4 about 15.5 s/frame with OptiX, 17 s with CUDA. An RTX 5080
  locally did the same 3 frames in 49 s including startup, so a local high-end card is faster per frame; the cloud
  helps by running in parallel and freeing the user's PC.
- Approximate hourly price including machine: L4 Spot about 0.3 USD, L4 on-demand about 0.8 USD, T4 Spot about
  0.15 USD. These are remembered list prices; confirm in the console price estimator.
- Consumer GeForce cards are not offered on Google Cloud. Only T4, L4, A100, H100 and similar.
