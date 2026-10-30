# Full-song EEVEE render on one RTX PRO 6000 + local 4K60 (measured 2026-10-30)

Job: 《愛包ダンスホール》 duo, Blender 5.2.1 EEVEE, 1920×1080, 30 fps, frames 0–6580 (219 s), two dancers + dome set,
DOF, outline solidifies, 12 MDD mesh caches (Houdini Vellum skirts), 64 scripted drivers. Scripts used are in
`scripts/eevee_job/` (paths inside are the job's; edit before reuse).

## Before renting: measure locally
- Render 3 representative frames locally first (`blender -b -y FILE -f A -f B -f C`, ignore the first frame:
  it includes shader compile). The local RTX 5080 did 2.0–2.2 s/frame at 64 samples.
- **Lower resolution does not help EEVEE scenes like this.** 720p took 2.65–3.0 s vs 1080p 2.1 s: the time is
  per-frame scene work plus sampling, not pixels. Do not drop to 720p + 3x SR (worse lines/lashes, no speed-up).
- **Samples are the real lever.** For toon shading 32 samples vs 64: PSNR 51.9–55.2 dB, < 0.08 % pixels differ by
  > 8/255, time 2.1 s → 1.1 s. 16 samples: 47–52 dB (slight noise at eye corners / DOF). Test PSNR on 3 frames,
  then pick. Mixing 64- and 32-sample frames in one video is invisible.

## Packaging (verify before upload)
- `prep_pack.py`: pack images, repoint every `MESH_CACHE` modifier to `//caches/<dir>/<file>`, output
  `//out/f_####.png`, `use_overwrite=False`, `use_placeholder=True`, save at frame 0. Copy the cache folders next to it.
- Render one frame from the package and from the original locally and diff them (got max 1/255). Then one frame from
  the VM vs local (mean 0.01/255).
- **`-y` is required** (scripted drivers stay dead without auto-run). The VRM add-on handler error
  (`'Context' object has no attribute 'visible_objects'`) is harmless and appears with the original too.

## VM
- No `blender-gpu` image existed; `--ImageFamily genshin-render` (driver 595 open, PRO 6000 OK) was used and Blender
  5.2.1 installed on top from `https://download.blender.org/release/Blender5.2/blender-5.2.1-linux-x64.tar.xz`
  (`vm_setup.sh`). That image ships Blender 4.2 only, which cannot open 5.2 files.
- `g4-standard-48`, 150 GB hyperdisk-balanced, Spot, us-central1-a/-b stocked out, -c worked.
- The script's `render` action is single-process and has no `-y`: use `vm_start.sh N START END` (N systemd units,
  contiguous chunks, linger enabled, logs in `~/logs`).

## Processes per GPU (the big trap)
| Units | Result |
|---|---|
| 6 | 0.9 frames/s at first, then GPU time-slicing starved some processes: a frame that takes 2 s locally sat > 5 min |
| 12 | 96 GB VRAM full (≈ 8 GB per process for this scene), throughput collapsed to ~10 frames/min |
| 2 | 0.93 frames/s steady at 64 samples, GPU 95–100 % SM, per-frame prep hidden by the other process |
| 2 @ 32 samples | **2.2 frames/s**, whole song ≈ 50 min |
So: **2 processes** for EEVEE on one PRO 6000 (≈ 2x one local 5080); more processes do not add throughput.
NVML "100 %" alone is not proof of good throughput: measure frames per 2 min (`vm_rate.sh`) and per-frame `Time:`
in the logs (`vm_diag.sh`).
To change process count or samples mid-run: stop all units, `find out -size 0 -delete` (placeholders of interrupted
frames), edit/save the blend on the VM if needed, start again over the full range (finished frames are skipped).

## Download while rendering
- Single `gcloud compute scp` from us-central1 to the user's PC: ~3 MB/s (~1.3 frames/s of 2.3 MB PNGs), slower
  than the 32-sample render. **4 parallel scp streams: ~10 MB/s.**
- `vm_ship.sh` tars finished frames (non-empty, unchanged for 60 s, not yet shipped) into 4 tars; `pull_loop.ps1`
  fetches them in parallel, extracts, acks. Check the local count (6581) before deleting the VM.

## Local 4K60 post (overlapped with the render)
- SR: Real-CUGAN ncnn `models-pro/up2x-no-denoise`, `-j 2:2:2`, batches of hardlinked new frames: 0.25 s/frame
  on the 5080 (the 1.3 s/frame of a 3-frame test was mostly startup).
- Interpolation: `post_4k60.py` = RIFE HDv3 fp16 flow at 1080p (padded to 1088), flow ×2 applied to the SR frames,
  no blending of whole frames; x264 crf 18 4K60 parts of 300 source frames, ~2 min per part per process.
  Uses the `H:\MiniMaxH3\.venv` torch (CUDA) with PIL only: the system Python has no CUDA torch, the venv has no cv2.
- Run 3 copies of `post_worker.ps1` (atomic `.lock` claim per part, `.done` when finished). The earlier
  `post_loop.ps1` / `post_loop_rev.ps1` pair raced and re-encoded finished parts; do not use them. 3 workers fill a
  16-core CPU with x264; verify every part has 2x its source frames before the mux.
- Camera-cut detection from camera motion flags fast moves too (361 "cuts"): hold a frame only when a flagged pair
  also has SSIM < 0.6 (or any pair < 0.2).
- `final_mux.sh`: check every part has 2x its source frames, concat with `-c copy`, audio offset = the VSE strip
  start (frame 1 → 1/30 s), no `-shortest` (the song ends 0.6 s before the video).

## Cost: do not let egress dominate
This run: VM ≈ 1.5 h × 1.63 USD ≈ 2.4 USD, but downloading 15 GB of PNG frames cost about as much again
(internet egress, ~0.12 USD/GB, more toward mainland China; ingress/upload is free). Next time:
- Encode the frames on the VM into a visually lossless 1080p30 video (x264 `-crf 12 -preset slow`, or FFV1 only if
  truly lossless is needed) and download that: ~1 GB instead of 15 GB, then extract frames locally for SR/RIFE.
- Use 32 samples and 2 processes from the start, and a custom image with Blender 5.2 baked in: ~1 h of VM.
- The local RTX 5080 renders the same scene at ~1.1 s/frame (32 samples), ~2 h for the whole song at zero cost;
  use the cloud only when the 1 h saved matters, or split frames between both.

## Encoder choice (300 SR 4K frames at 60 fps, local RTX 5080, times include ~1.9 s of PNG decode)
| Encoder | Time | Size | SSIM |
|---|---|---|---|
| libx264 CRF18 medium, 8 threads | 16.2 s | 29 MB | 0.9916 |
| h264_nvenc p7 hq CQ25 | 5.7 s | 38 MB | 0.9928 |
| hevc_nvenc p7 hq CQ21 | 7.0 s | 19 MB | 0.9902 |
| av1_nvenc p7 hq CQ26 | 4.0 s | 24 MB | 0.9917 |
- NVENC is a separate encoder block on the GPU: ~3x faster than x264 and nearly no CPU, visually identical at these
  rates. In this job x264 + 4K PNG I/O kept the CPU at 100 % while the GPU sat at ~40 %; NVENC should cut each
  4K60 part by an estimated 30-50 % (PNG I/O and RIFE remain; not measured per part).
- Default for new jobs: parts with `h264_nvenc -preset p7 -tune hq -rc vbr -cq 23 -b:v 0 -spatial-aq 1
  -temporal-aq 1` (`ENC=nvenc` in `post_4k60.py`); `av1_nvenc` for archive / bandwidth-limited delivery.
- Use one encoder and one parameter set for every part of a film, or `concat -c copy` may fail. Do not switch mid-job.
- The VM-side `vm_encode.sh` (CRF 12, yuv444p) is about egress, not delivery; keep it on x264 (Linux VM, no NVENC
  session limits to worry about) or use NVENC if the VM GPU is idle.

## Windows / shell pitfalls hit this time
- From Git Bash, `gcloud.cmd compute ssh ... --command "..."` under `C:\Program Files (x86)` fails
  (`'C:\Program' is not recognized`); scp worked. Drive gcloud from PowerShell.
- `pscp` rejects `~/` as the remote target: use `vm:file` (home-relative).
- PowerShell variables are case-insensitive: a loop `$p` overwrote `$P` (part size) and produced empty parts.
- `[math]::Ceiling()` returns a double; `"{0:D2}" -f $double` throws: cast with `[int]`.
- A redirected log that another (killed) process still holds cannot be reopened: use a new log name.
