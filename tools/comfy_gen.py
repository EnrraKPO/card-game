#!/usr/bin/env python
"""Drive a local ComfyUI server to render images with Flux 2 dev.

Usage:
    python tools/comfy_gen.py "a prompt" [--out NAME] [--w 1024] [--h 1024]
                                          [--steps 20] [--guidance 4.0] [--seed N]

Saves the PNG(s) into ComfyUI's output dir and reports the path.
"""
import argparse, json, time, urllib.request, urllib.parse, random, sys

SERVER = "http://127.0.0.1:8187"

UNET = "flux2_dev_fp8mixed.safetensors"
CLIP = "mistral_3_small_flux2_bf16.safetensors"
VAE  = "flux2-vae.safetensors"


def build_workflow(prompt, w, h, steps, guidance, seed, prefix, rembg=False,
                   rembg_model="Inspyrenet"):
    save = ({"60": {"class_type": "easy imageRemBg",
                    "inputs": {"images": ["50", 0], "rem_mode": rembg_model,
                               "image_output": "Save", "save_prefix": prefix,
                               "torchscript_jit": False, "add_background": "none",
                               "refine_foreground": True}}}
            if rembg else
            {"60": {"class_type": "SaveImage",
                    "inputs": {"images": ["50", 0], "filename_prefix": prefix}}})
    return dict(save, **{
        "10": {"class_type": "UNETLoader",
               "inputs": {"unet_name": UNET, "weight_dtype": "default"}},
        "11": {"class_type": "CLIPLoader",
               "inputs": {"clip_name": CLIP, "type": "flux2"}},
        "12": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
        "20": {"class_type": "CLIPTextEncode",
               "inputs": {"text": prompt, "clip": ["11", 0]}},
        "21": {"class_type": "FluxGuidance",
               "inputs": {"conditioning": ["20", 0], "guidance": guidance}},
        "30": {"class_type": "BasicGuider",
               "inputs": {"model": ["10", 0], "conditioning": ["21", 0]}},
        "31": {"class_type": "KSamplerSelect",
               "inputs": {"sampler_name": "euler"}},
        "32": {"class_type": "Flux2Scheduler",
               "inputs": {"steps": steps, "width": w, "height": h}},
        "33": {"class_type": "RandomNoise", "inputs": {"noise_seed": seed}},
        "34": {"class_type": "EmptyFlux2LatentImage",
               "inputs": {"width": w, "height": h, "batch_size": 1}},
        "40": {"class_type": "SamplerCustomAdvanced",
               "inputs": {"noise": ["33", 0], "guider": ["30", 0],
                          "sampler": ["31", 0], "sigmas": ["32", 0],
                          "latent_image": ["34", 0]}},
        "50": {"class_type": "VAEDecode",
               "inputs": {"samples": ["40", 0], "vae": ["12", 0]}},
    })


def post(path, payload):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(SERVER + path, data=data,
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=30))


def get(path):
    return json.load(urllib.request.urlopen(SERVER + path, timeout=30))


def fetch_image(img):
    qs = urllib.parse.urlencode({"filename": img["filename"],
                                 "subfolder": img.get("subfolder", ""),
                                 "type": img.get("type", "output")})
    return urllib.request.urlopen(f"{SERVER}/view?{qs}", timeout=60).read()


def main():
    global SERVER
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt")
    ap.add_argument("--out", default="cardgame")
    ap.add_argument("--dest", help="path to write the final PNG (e.g. assets/cards/foo.png)")
    ap.add_argument("--w", type=int, default=1024)
    ap.add_argument("--h", type=int, default=1024)
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--guidance", type=float, default=4.0)
    ap.add_argument("--seed", type=int, default=-1)
    ap.add_argument("--port", type=int, default=8188,
                    help="ComfyUI port (8187 is often a stale/poisoned instance)")
    ap.add_argument("--rembg", action="store_true",
                    help="remove background -> transparent PNG (for sprites/artifacts)")
    ap.add_argument("--rembg-model", default="Inspyrenet",
                    help="RMBG-2.0 | RMBG-1.4 | Inspyrenet | BEN2")
    a = ap.parse_args()
    SERVER = f"http://127.0.0.1:{a.port}"

    seed = a.seed if a.seed >= 0 else random.randint(0, 2**32 - 1)
    wf = build_workflow(a.prompt, a.w, a.h, a.steps, a.guidance, seed, a.out,
                        a.rembg, a.rembg_model)

    pid = post("/prompt", {"prompt": wf})["prompt_id"]
    print(f"[queued] prompt_id={pid} seed={seed}", flush=True)

    t0 = time.time()
    while True:
        hist = get(f"/history/{pid}")
        if pid in hist:
            break
        if time.time() - t0 > 600:
            print("[timeout]"); sys.exit(1)
        time.sleep(2)

    h = hist[pid]
    status = h.get("status", {}).get("status_str", "?")
    print(f"[done] status={status} elapsed={time.time()-t0:.1f}s", flush=True)
    for node in h.get("outputs", {}).values():
        for img in node.get("images", []):
            print(f"[image] {img['subfolder']}/{img['filename']} ({img['type']})")
            if a.dest:
                import os
                os.makedirs(os.path.dirname(os.path.abspath(a.dest)), exist_ok=True)
                with open(a.dest, "wb") as f:
                    f.write(fetch_image(img))
                print(f"[saved] {a.dest}")
                return


if __name__ == "__main__":
    main()
