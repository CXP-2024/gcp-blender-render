# 1080p30 frames/ + Real-CUGAN 2x sr/ -> 4K60 part video. Each source frame is followed by one RIFE in-between made from
# a flow computed at 1080p (HDv3 fp16) and applied 2x to the SR frames (no whole-frame blending); camera cuts
# (cut_pairs.json) and very different neighbours (SSIM < 0.2) hold the frame instead. Adapted from tttg_post_heaven_r12.
# usage: python post_4k60.py PART START END   (frame indices, END exclusive; last frame of the song held)
import os, sys, time, json, types, importlib.util, subprocess
from pathlib import Path
import numpy as np, torch
from PIL import Image
import torch.nn.functional as F
R = Path(__file__).resolve().parent; M = Path('H:/MV_making/天天天国/codex_render/upscale_4k60_r1'); LAST = 6580
FF = os.environ.get('FFMPEG', 'ffmpeg')
part, start, end = map(int, sys.argv[1:]); device = torch.device('cuda:0'); cache = {}
def warp(img, flow):
    _, _, h, w = img.shape
    if (h, w) not in cache:
        yy, xx = torch.meshgrid(torch.linspace(-1, 1, h, device=device, dtype=img.dtype), torch.linspace(-1, 1, w, device=device, dtype=img.dtype), indexing='ij'); cache[h, w] = torch.stack((xx, yy), -1)[None]
    return F.grid_sample(img, cache[h, w] + torch.stack((flow[:, 0] / ((w - 1) / 2), flow[:, 1] / ((h - 1) / 2)), -1), mode='bilinear', padding_mode='border', align_corners=True)
m = types.ModuleType('model'); mw = types.ModuleType('model.warplayer'); mw.warp = warp; sys.modules['model'] = m; sys.modules['model.warplayer'] = mw
spec = importlib.util.spec_from_file_location('ifnet_local', M / 'rife_dependency/rife_model/train_log/IFNet_HDv3.py'); mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
net = mod.IFNet().to(device).half().eval(); net.load_state_dict(torch.load(M / 'rife_fp16.pt', map_location=device, weights_only=True), strict=True)
def load(p):                                                                  # RGB uint8 -> 1x3xHxW fp16 on GPU
    return torch.from_numpy(np.asarray(Image.open(p).convert('RGB')).copy()).permute(2, 0, 1)[None].to(device=device, dtype=torch.float16) / 255
src = lambda i: load(R / 'frames' / f'f_{i:04d}.png'); big = lambda i: load(R / 'sr' / f'f_{i:04d}.png')
pad = lambda x: F.pad(x, (0, 0, 0, 8), mode='replicate')                    # 1080 -> 1088 (multiple of 32)
g1 = torch.exp(-((torch.arange(7, device=device) - 3.0) ** 2) / (2 * 1.5 ** 2)); g1 = (g1 / g1.sum()).float(); G2 = (g1[:, None] * g1[None, :])[None, None]
def ssim(a, b):
    a = F.interpolate(a.float().mean(1, keepdim=True), size=(90, 160), mode='area'); b = F.interpolate(b.float().mean(1, keepdim=True), size=(90, 160), mode='area')
    bl = lambda x: F.conv2d(F.pad(x, (3, 3, 3, 3), mode='reflect'), G2)
    ma, mb = bl(a), bl(b); va = bl(a * a) - ma * ma; vb = bl(b * b) - mb * mb; cov = bl(a * b) - ma * mb
    return float((((2 * ma * mb + .0001) * (2 * cov + .0009)) / ((ma * ma + mb * mb + .0001) * (va + vb + .0009))).mean())
u8 = lambda x: (x[0].clamp(0, 1) * 255).round().byte().permute(1, 2, 0).cpu().numpy()
cuts = set(json.loads((R / 'cut_pairs.json').read_text())['cut_pairs']); out = R / 'post_parts'; out.mkdir(exist_ok=True)
cmd = [FF, '-y', '-v', 'warning', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', '3840x2160', '-r', '60', '-i', '-', '-an', '-vf', 'scale=out_color_matrix=bt709:out_range=tv',
       '-c:v', 'libx264', '-crf', '18', '-preset', 'medium', '-threads', '8', '-pix_fmt', 'yuv420p', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', str(out / f'part_{part:02d}.mp4')]
enc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=open(out / f'encode_{part:02d}.log', 'w'))
begin = time.time(); held = 0
with torch.inference_mode():
    for i in range(start, end):
        large = big(i); assert large.shape[-2:] == (2160, 3840), i; enc.stdin.write(u8(large).tobytes())
        cut = i >= LAST                                                   # camera-flagged pairs include fast moves,
        if not cut:                                                       # so a flag only holds when the image changes
            small, nxt = src(i), src(i + 1); sv = ssim(small, nxt); cut = sv < .2 or (i in cuts and sv < .6)
        if cut: middle = large; held += 1
        else:
            flows, mask, _ = net(torch.cat((pad(small), pad(nxt)), 1))
            flow = flows[-1][:, :, :1080].float(); mask = mask[:, :, :1080].float(); assert torch.isfinite(flow).all()
            flow = F.interpolate(flow, size=(2160, 3840), mode='bilinear', align_corners=False) * 2; mask = F.interpolate(mask, size=(2160, 3840), mode='bilinear', align_corners=False)
            left = warp(large.float(), flow[:, 0:2]); right = warp(big(i + 1).float(), flow[:, 2:4])
            middle = left * mask + right * (1 - mask)
        enc.stdin.write(u8(middle).tobytes())
        if i % 150 == 0: print('RIFE_FRAME', part, i, 'seconds', round(time.time() - begin, 1), flush=True); Image.fromarray(u8(middle)).save(out / f'qc_{i:04d}.jpg', quality=90)
enc.stdin.close(); assert enc.wait() == 0
print('RIFE_PART_DONE', part, round(time.time() - begin, 1), 'held', held, flush=True)
