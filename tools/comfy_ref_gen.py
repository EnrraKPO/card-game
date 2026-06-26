#!/usr/bin/env python
"""Drive a local ComfyUI server to render with Flux 2 dev + multiple image refs.

Flux 2 (like Flux Kontext) accepts reference images by VAE-encoding each one and
chaining it onto the text conditioning through a `ReferenceLatent` node. This
script uploads any number of local images, wires up that chain, and renders.

Usage:
    python tools/comfy_ref_gen.py "a prompt" --ref a.png --ref b.png [...]
                                   [--out NAME] [--w 1024] [--h 1024]
                                   [--steps 20] [--guidance 4.0] [--seed N]
                                   [--no-scale] [--rembg [--rembg-model M]]

Each --ref may be a path to a local file or a filename already in ComfyUI's
input dir. Saves the PNG(s) into ComfyUI's output dir and reports the path.
"""
import argparse, json, time, urllib.request, random, sys, os, uuid

SERVER = "http://127.0.0.1:8187"

UNET = "flux2_dev_fp8mixed.safetensors"
CLIP = "mistral_3_small_flux2_bf16.safetensors"
VAE  = "flux2-vae.safetensors"


def build_workflow(prompt, refs, w, h, steps, guidance, seed, prefix,
                   scale=True, rembg=False, rembg_model="Inspyrenet"):
    """refs: list of filenames already present in ComfyUI's input dir."""
    wf = {
        "10": {"class_type": "UNETLoader",
               "inputs": {"unet_name": UNET, "weight_dtype": "default"}},
        "11": {"class_type": "CLIPLoader",
               "inputs": {"clip_name": CLIP, "type": "flux2"}},
        "12": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
        "20": {"class_type": "CLIPTextEncode",
               "inputs": {"text": prompt, "clip": ["11", 0]}},
    }

    # Build the reference chain: each ref image is VAE-encoded and appended to
    # the conditioning via ReferenceLatent. cond_src tracks the latest node.
    cond_src = ["20", 0]
    for i, name in enumerate(refs):
        load = f"100{i}"
        enc = f"110{i}"
        ref = f"120{i}"
        wf[load] = {"class_type": "LoadImage", "inputs": {"image": name}}
        img_src = [load, 0]
        if scale:
            sc = f"105{i}"
            wf[sc] = {"class_type": "FluxKontextImageScale",
                      "inputs": {"image": [load, 0]}}
            img_src = [sc, 0]
        wf[enc] = {"class_type": "VAEEncode",
                   "inputs": {"pixels": img_src, "vae": ["12", 0]}}
        wf[ref] = {"class_type": "ReferenceLatent",
                   "inputs": {"conditioning": cond_src, "latent": [enc, 0]}}
        cond_src = [ref, 0]

    wf.update({
        "21": {"class_type": "FluxGuidance",
               "inputs": {"conditioning": cond_src, "guidance": guidance}},
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

    if rembg:
        wf["60"] = {"class_type": "easy imageRemBg",
                    "inputs": {"images": ["50", 0], "rem_mode": rembg_model,
                               "image_output": "Save", "save_prefix": prefix,
                               "torchscript_jit": False, "add_background": "none",
                               "refine_foreground": True}}
    else:
        wf["60"] = {"class_type": "SaveImage",
                    "inputs": {"images": ["50", 0], "filename_prefix": prefix}}
    return wf


def post(path, payload):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(SERVER + path, data=data,
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=30))


def get(path):
    return json.load(urllib.request.urlopen(SERVER + path, timeout=30))


def upload_image(path):
    """Upload a local file to ComfyUI's input dir; return the stored filename.

    If `path` isn't an existing file, assume it's already an input filename.
    """
    if not os.path.isfile(path):
        return os.path.basename(path)
    name = os.path.basename(path)
    # Unique-ish name so repeated runs don't collide / silently reuse stale files.
    stored = f"ref_{uuid.uuid4().hex[:8]}_{name}"
    with open(path, "rb") as f:
        body = f.read()
    boundary = "----comfyref" + uuid.uuid4().hex
    parts = []
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(
        f'Content-Disposition: form-data; name="image"; filename="{stored}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n".encode())
    parts.append(body)
    parts.append(f"\r\n--{boundary}\r\n".encode())
    parts.append(
        b'Content-Disposition: form-data; name="overwrite"\r\n\r\ntrue\r\n')
    parts.append(f"--{boundary}--\r\n".encode())
    data = b"".join(parts)
    req = urllib.request.Request(
        SERVER + "/upload/image", data=data,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    res = json.load(urllib.request.urlopen(req, timeout=60))
    sub = res.get("subfolder", "")
    return f"{sub}/{res['name']}" if sub else res["name"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt")
    ap.add_argument("--ref", action="append", default=[], metavar="PATH",
                    help="reference image (repeatable); local path or input filename")
    ap.add_argument("--out", default="cardgame_ref")
    ap.add_argument("--w", type=int, default=1024)
    ap.add_argument("--h", type=int, default=1024)
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--guidance", type=float, default=4.0)
    ap.add_argument("--seed", type=int, default=-1)
    ap.add_argument("--no-scale", action="store_true",
                    help="don't rescale refs to Flux-preferred resolutions")
    ap.add_argument("--rembg", action="store_true",
                    help="remove background -> transparent PNG (for sprites/artifacts)")
    ap.add_argument("--rembg-model", default="Inspyrenet",
                    help="RMBG-2.0 | RMBG-1.4 | Inspyrenet | BEN2")
    a = ap.parse_args()

    if not a.ref:
        print("[warn] no --ref given; this is a plain text2img run "
              "(use comfy_gen.py for that)", flush=True)

    refs = []
    for p in a.ref:
        stored = upload_image(p)
        print(f"[ref] {p} -> {stored}", flush=True)
        refs.append(stored)

    seed = a.seed if a.seed >= 0 else random.randint(0, 2**32 - 1)
    wf = build_workflow(a.prompt, refs, a.w, a.h, a.steps, a.guidance, seed,
                        a.out, scale=not a.no_scale, rembg=a.rembg,
                        rembg_model=a.rembg_model)

    pid = post("/prompt", {"prompt": wf})["prompt_id"]
    print(f"[queued] prompt_id={pid} seed={seed} refs={len(refs)}", flush=True)

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


if __name__ == "__main__":
    main()
