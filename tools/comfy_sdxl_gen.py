#!/usr/bin/env python
"""Drive a local ComfyUI server to render with an SDXL/Illustrious checkpoint.

Companion to comfy_gen.py (which is Flux-2 only). This one targets booru-style
SDXL checkpoints — default WAI-Illustrious — for card character art. It applies
the usual quality enhancers / negatives and clip-skip 2 (which Illustrious models
expect), then writes the finished PNG straight to --dest via ComfyUI's /view API.

Usage:
    python tools/comfy_sdxl_gen.py "1girl, knight, ..." --dest assets/cards/foo.png
      [--ckpt "Illustrious\\waiIllustriousSDXL_v170.safetensors"]
      [--neg "..."] [--no-enhance] [--w 832] [--h 1216]
      [--steps 30] [--cfg 5.0] [--sampler euler_ancestral] [--scheduler normal]
      [--seed N] [--port 8188]
"""
import argparse, json, time, urllib.request, urllib.parse, random, sys, os

# Quality enhancers / negatives the user asked for (booru-style SDXL convention).
POS_PREFIX = "masterpiece, best quality, high quality, "
NEG_DEFAULT = ("worst quality, low quality, lowres, bad anatomy, bad hands, "
               "missing fingers, extra digits, fewer digits, jpeg artifacts, "
               "signature, watermark, username, text, blurry, deformed")

DEFAULT_CKPT = "Illustrious\\waiIllustriousSDXL_v170.safetensors"


def build_workflow(pos, neg, ckpt, w, h, steps, cfg, sampler, scheduler, seed, prefix):
    return {
        "1": {"class_type": "CheckpointLoaderSimple",
              "inputs": {"ckpt_name": ckpt}},
        "2": {"class_type": "CLIPSetLastLayer",
              "inputs": {"clip": ["1", 1], "stop_at_clip_layer": -2}},
        "3": {"class_type": "CLIPTextEncode",
              "inputs": {"text": pos, "clip": ["2", 0]}},
        "4": {"class_type": "CLIPTextEncode",
              "inputs": {"text": neg, "clip": ["2", 0]}},
        "5": {"class_type": "EmptyLatentImage",
              "inputs": {"width": w, "height": h, "batch_size": 1}},
        "6": {"class_type": "KSampler",
              "inputs": {"model": ["1", 0], "positive": ["3", 0],
                         "negative": ["4", 0], "latent_image": ["5", 0],
                         "seed": seed, "steps": steps, "cfg": cfg,
                         "sampler_name": sampler, "scheduler": scheduler,
                         "denoise": 1.0}},
        "7": {"class_type": "VAEDecode",
              "inputs": {"samples": ["6", 0], "vae": ["1", 2]}},
        "8": {"class_type": "SaveImage",
              "inputs": {"images": ["7", 0], "filename_prefix": prefix}},
    }


def post(server, path, payload):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(server + path, data=data,
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=30))


def get_json(server, path):
    return json.load(urllib.request.urlopen(server + path, timeout=30))


def fetch_image(server, img):
    qs = urllib.parse.urlencode({"filename": img["filename"],
                                 "subfolder": img.get("subfolder", ""),
                                 "type": img.get("type", "output")})
    return urllib.request.urlopen(f"{server}/view?{qs}", timeout=60).read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt")
    ap.add_argument("--dest", help="path to write the final PNG (e.g. assets/cards/foo.png)")
    ap.add_argument("--ckpt", default=DEFAULT_CKPT)
    ap.add_argument("--neg", default=NEG_DEFAULT)
    ap.add_argument("--no-enhance", action="store_true",
                    help="don't prepend the masterpiece/best quality enhancers")
    ap.add_argument("--w", type=int, default=832)
    ap.add_argument("--h", type=int, default=1216)
    ap.add_argument("--steps", type=int, default=30)
    ap.add_argument("--cfg", type=float, default=5.0)
    ap.add_argument("--sampler", default="euler_ancestral")
    ap.add_argument("--scheduler", default="normal")
    ap.add_argument("--seed", type=int, default=-1)
    ap.add_argument("--out", default="cardgame_sdxl", help="ComfyUI SaveImage prefix")
    ap.add_argument("--port", type=int, default=8188)
    a = ap.parse_args()

    server = f"http://127.0.0.1:{a.port}"
    pos = a.prompt if a.no_enhance else POS_PREFIX + a.prompt
    seed = a.seed if a.seed >= 0 else random.randint(0, 2**32 - 1)
    wf = build_workflow(pos, a.neg, a.ckpt, a.w, a.h, a.steps, a.cfg,
                        a.sampler, a.scheduler, seed, a.out)

    pid = post(server, "/prompt", {"prompt": wf})["prompt_id"]
    print(f"[queued] port={a.port} prompt_id={pid} seed={seed}", flush=True)

    t0 = time.time()
    while True:
        hist = get_json(server, f"/history/{pid}")
        if pid in hist:
            break
        if time.time() - t0 > 600:
            print("[timeout]"); sys.exit(1)
        time.sleep(2)

    h = hist[pid]
    status = h.get("status", {}).get("status_str", "?")
    print(f"[done] status={status} elapsed={time.time()-t0:.1f}s", flush=True)
    if status == "error":
        for m in h.get("status", {}).get("messages", []):
            if m[0] == "execution_error":
                print("[error]", m[1].get("node_type"), "::",
                      m[1].get("exception_message", "")[:200])
        sys.exit(1)

    for node in h.get("outputs", {}).values():
        for img in node.get("images", []):
            print(f"[image] {img['subfolder']}/{img['filename']} ({img['type']})")
            if a.dest:
                os.makedirs(os.path.dirname(os.path.abspath(a.dest)), exist_ok=True)
                with open(a.dest, "wb") as f:
                    f.write(fetch_image(server, img))
                print(f"[saved] {a.dest}")
                return


if __name__ == "__main__":
    main()
