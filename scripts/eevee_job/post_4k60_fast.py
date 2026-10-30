# Fast 4K60 part: same picture as post_4k60.py (RIFE HDv3 fp16 flow at 1080p, applied 2x to Real-CUGAN SR frames,
# holds only at MMD camera hard cuts from cut_pairs_cam.json), but tuned for throughput:
# - every PNG is decoded once (a background thread prefetches frame i+1 while frame i is on the GPU) and reused for
#   the next pair instead of being read twice;
# - RGB -> BT.709 limited-range YUV 4:2:0 is done on the GPU, so ffmpeg only gets raw yuv420p (half the bytes, no
#   swscale on the CPU) and encodes with NVENC (h264_nvenc p7 hq, CQ 22).
# usage: python post_4k60_fast.py PART START END   (END exclusive; the song's last frame is held)
import os, sys, time, json, types, importlib.util, subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import numpy as np, torch
import torch.nn.functional as F
from PIL import Image
R = Path(__file__).resolve().parent; M = Path('H:/MV_making/天天天国/codex_render/upscale_4k60_r1'); LAST = 6580
FF = os.environ.get('FFMPEG', 'ffmpeg')
part, start, end = map(int, sys.argv[1:]); device = torch.device('cuda:0'); cache = {}
def warp(img, flow):
    _, _, h, w = img.shape
    if (h, w, img.dtype) not in cache:
        yy, xx = torch.meshgrid(torch.linspace(-1, 1, h, device=device, dtype=img.dtype), torch.linspace(-1, 1, w, device=device, dtype=img.dtype), indexing='ij'); cache[h, w, img.dtype] = torch.stack((xx, yy), -1)[None]
    return F.grid_sample(img, cache[h, w, img.dtype] + torch.stack((flow[:, 0] / ((w - 1) / 2), flow[:, 1] / ((h - 1) / 2)), -1), mode='bilinear', padding_mode='border', align_corners=True)
m = types.ModuleType('model'); mw = types.ModuleType('model.warplayer'); mw.warp = warp; sys.modules['model'] = m; sys.modules['model.warplayer'] = mw
spec = importlib.util.spec_from_file_location('ifnet_local', M / 'rife_dependency/rife_model/train_log/IFNet_HDv3.py'); mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
net = mod.IFNet().to(device).half().eval(); net.load_state_dict(torch.load(M / 'rife_fp16.pt', map_location=device, weights_only=True), strict=True)
read = lambda p: np.asarray(Image.open(p).convert('RGB'))
def pair(i):                                       # decoded on a worker thread: (1080p src, 4K SR) uint8 arrays
    return read(R / 'frames' / f'f_{i:04d}.png'), read(R / 'sr' / f'f_{i:04d}.png')
gpu = lambda a: torch.from_numpy(a).to(device, non_blocking=True).permute(2, 0, 1)[None].half() / 255
pad = lambda x: F.pad(x, (0, 0, 0, 8), mode='replicate')                    # 1080 -> 1088 (multiple of 32)
KR, KB = 0.2126, 0.0722
def yuv420(x):                                      # 1x3xHxW float 0..1 RGB -> yuv420p bytes, BT.709 limited range
    x = x.float().clamp(0, 1); r, g, b = x[0, 0], x[0, 1], x[0, 2]
    y = KR * r + (1 - KR - KB) * g + KB * b; cb = (b - y) / (2 * (1 - KB)); cr = (r - y) / (2 * (1 - KR))
    Y = (16 + 219 * y).round().clamp(0, 255).byte()
    cb = F.avg_pool2d(cb[None, None], 2)[0, 0]; cr = F.avg_pool2d(cr[None, None], 2)[0, 0]
    U = (128 + 224 * cb).round().clamp(0, 255).byte(); V = (128 + 224 * cr).round().clamp(0, 255).byte()
    return torch.cat((Y.flatten(), U.flatten(), V.flatten())).cpu().numpy().tobytes()
cuts = set(json.loads((R / 'cut_pairs_cam.json').read_text())['cut_pairs']); out = R / 'post_parts'; out.mkdir(exist_ok=True)
cmd = [FF, '-y', '-v', 'warning', '-f', 'rawvideo', '-pix_fmt', 'yuv420p', '-s', '3840x2160', '-r', '60',
       '-color_range', 'tv', '-colorspace', 'bt709', '-i', '-', '-an',   # tag the input: untagged raw made ffmpeg insert a range conversion
       '-c:v', 'h264_nvenc', '-preset', 'p7', '-tune', 'hq', '-rc', 'vbr', '-cq', '22', '-b:v', '0', '-spatial-aq', '1', '-temporal-aq', '1',
       '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'tv', str(out / f'part_{part:02d}.mp4')]
enc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=open(out / f'encode_{part:02d}.log', 'w'))
pool = ThreadPoolExecutor(2); begin = time.time(); held = 0
with torch.inference_mode():
    cur = pair(start); fut = pool.submit(pair, start + 1) if start + 1 <= LAST else None
    for i in range(start, end):
        s_np, b_np = cur; large = gpu(b_np); assert large.shape[-2:] == (2160, 3840), i
        nxt = fut.result() if fut else None
        if nxt is not None and i + 2 <= LAST: fut = pool.submit(pair, i + 2)
        else: fut = None
        enc.stdin.write(yuv420(large))
        if i >= LAST or i in cuts or nxt is None: middle = large; held += 1
        else:
            flows, mask, _ = net(torch.cat((pad(gpu(s_np)), pad(gpu(nxt[0]))), 1))
            flow = flows[-1][:, :, :1080].float(); mask = mask[:, :, :1080].float(); assert torch.isfinite(flow).all()
            flow = F.interpolate(flow, size=(2160, 3840), mode='bilinear', align_corners=False) * 2; mask = F.interpolate(mask, size=(2160, 3840), mode='bilinear', align_corners=False)
            middle = warp(large.float(), flow[:, 0:2]) * mask + warp(gpu(nxt[1]).float(), flow[:, 2:4]) * (1 - mask)
        enc.stdin.write(yuv420(middle))
        if i % 150 == 0: print('RIFE_FRAME', part, i, 'seconds', round(time.time() - begin, 1), flush=True)
        cur = nxt
enc.stdin.close(); assert enc.wait() == 0
print('RIFE_PART_DONE', part, round(time.time() - begin, 1), 'held', held, flush=True)
