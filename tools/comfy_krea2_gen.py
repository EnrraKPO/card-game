#!/usr/bin/env python
"""Drive a local ComfyUI server to render images with Krea 2 Turbo (qwen3vl CLIP).

Matches the exact graph the authoring Tool (Tool/server.js buildKrea2Workflow)
uses for ability/relic art, so output is consistent with existing assets.

Usage:
    python tools/comfy_krea2_gen.py "a prompt" --dest assets/relics/foo.png \
        [--w 1024] [--h 1024] [--steps 8] [--cfg 1] [--seed N] [--port 8000] \
        [--rembg] [--rembg-model Inspyrenet] \
        [--ref path/to/ref.png --denoise 0.6]
"""
import argparse, json, time, urllib.request, urllib.parse, random, sys, os, base64, uuid

SERVER = "http://127.0.0.1:8000"

UNET = "krea2_turbo_bf16.safetensors"
CLIP = "qwen3vl_4b_bf16.safetensors"
VAE = "qwen_image_vae.safetensors"


def build_workflow(prompt, w, h, steps, cfg, seed, prefix, rembg=False,
                    rembg_model="Inspyrenet", ref_filename=None, denoise=1.0):
    latent_nodes = {
        "34": {"class_type": "EmptyLatentImage",
               "inputs": {"width": w, "height": h, "batch_size": 1}},
    }
    latent_src = ["34", 0]
    if ref_filename:
        latent_nodes = {
            "70": {"class_type": "LoadImage", "inputs": {"image": ref_filename}},
            "71": {"class_type": "ImageScale",
                   "inputs": {"image": ["70", 0], "upscale_method": "lanczos",
                              "width": w, "height": h, "crop": "disabled"}},
            "34": {"class_type": "VAEEncode",
                   "inputs": {"pixels": ["71", 0], "vae": ["12", 0]}},
        }
        latent_src = ["34", 0]

    save = ({"60": {"class_type": "easy imageRemBg",
                     "inputs": {"images": ["50", 0], "rem_mode": rembg_model,
                                "image_output": "Save", "save_prefix": prefix,
                                "torchscript_jit": False, "add_background": "none",
                                "refine_foreground": True}}}
            if rembg else
            {"60": {"class_type": "SaveImage",
                    "inputs": {"images": ["50", 0], "filename_prefix": prefix}}})

    return dict(save, **latent_nodes, **{
        "10": {"class_type": "UNETLoader",
               "inputs": {"unet_name": UNET, "weight_dtype": "default"}},
        "11": {"class_type": "CLIPLoader",
               "inputs": {"clip_name": CLIP, "type": "krea2"}},
        "12": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
        "20": {"class_type": "CLIPTextEncode",
               "inputs": {"text": prompt, "clip": ["11", 0]}},
        "21": {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": ["20", 0]}},
        "40": {"class_type": "KSampler",
               "inputs": {"model": ["10", 0], "positive": ["20", 0], "negative": ["21", 0],
                          "latent_image": latent_src, "seed": seed, "steps": steps,
                          "cfg": cfg, "sampler_name": "euler", "scheduler": "simple",
                          "denoise": denoise}},
        "50": {"class_type": "VAEDecode", "inputs": {"samples": ["40", 0], "vae": ["12", 0]}},
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


def upload_ref(path):
    with open(path, "rb") as f:
        data = f.read()
    boundary = uuid.uuid4().hex
    name = os.path.basename(path)
    body = (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{name}\"\r\n"
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode() + data + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(SERVER + "/upload/image", data=body,
                                  headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    resp = json.load(urllib.request.urlopen(req, timeout=60))
    return resp["name"]


def main():
    global SERVER
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt")
    ap.add_argument("--out", default="cardgame")
    ap.add_argument("--dest", help="path to write the final PNG (e.g. assets/relics/foo.png)")
    ap.add_argument("--w", type=int, default=1024)
    ap.add_argument("--h", type=int, default=1024)
    ap.add_argument("--steps", type=int, default=8)
    ap.add_argument("--cfg", type=float, default=1.0)
    ap.add_argument("--seed", type=int, default=-1)
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--rembg", action="store_true")
    ap.add_argument("--rembg-model", default="Inspyrenet")
    ap.add_argument("--ref", default=None, help="local image path to use as img2img reference")
    ap.add_argument("--denoise", type=float, default=0.6)
    a = ap.parse_args()
    SERVER = f"http://127.0.0.1:{a.port}"

    ref_filename = upload_ref(a.ref) if a.ref else None
    seed = a.seed if a.seed >= 0 else random.randint(0, 2**32 - 1)
    wf = build_workflow(a.prompt, a.w, a.h, a.steps, a.cfg, seed, a.out,
                         a.rembg, a.rembg_model, ref_filename,
                         a.denoise if ref_filename else 1.0)

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
                os.makedirs(os.path.dirname(os.path.abspath(a.dest)), exist_ok=True)
                with open(a.dest, "wb") as f:
                    f.write(fetch_image(img))
                print(f"[saved] {a.dest}")
                return


if __name__ == "__main__":
    main()
