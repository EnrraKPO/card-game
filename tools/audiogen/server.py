#!/usr/bin/env python
"""Persistent local AudioGen server — the SFX twin of the ComfyUI image server.

Loads Meta's AudioGen (audiocraft) once and keeps it warm on the GPU, so the
authoring Tool can churn through sound cues without paying the model-load cost
per generation.

    python server.py [--port 8188] [--model facebook/audiogen-medium]

API (JSON over HTTP, same spirit as ComfyUI's):
    GET  /health
        -> {"ok": true, "model": "...", "device": "cuda"}
    POST /generate
        {"prompt": "sword clashing against metal shield",
         "duration": 2.0,          # seconds, model max ~10
         "count": 1,               # batch variants of the same prompt
         "seed": 1234,             # optional, for reproducibility
         "top_k": 250, "cfg": 3.0, # optional sampling knobs
         "prefix": "sfx_sword"}    # output filename prefix
        -> {"ok": true, "files": ["D:\\...\\output\\sfx_sword_00.wav", ...],
            "seconds": 3.1}

Output wavs land in tools/audiogen/output/.
"""
import argparse
import json
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

OUT_DIR = Path(__file__).parent / "output"

MODEL = None
MODEL_NAME = ""
DEVICE = ""


def load_model(name: str):
    global MODEL, MODEL_NAME, DEVICE
    import torch
    from audiocraft.models import AudioGen

    DEVICE = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"[audiogen] loading {name} on {DEVICE} ...", flush=True)
    t0 = time.time()
    MODEL = AudioGen.get_pretrained(name, device=DEVICE)
    MODEL_NAME = name
    print(f"[audiogen] ready in {time.time() - t0:.1f}s", flush=True)


# audiocraft's own audio_write pipes through an ffmpeg binary (absent here) — write
# wavs ourselves: loudness-normalize to a consistent level, soft-limit, save via soundfile.
def write_wav(stem: Path, wav, sample_rate: int) -> str:
    import numpy as np
    import soundfile as sf

    data = wav.cpu().numpy().T  # (channels, time) -> (time, channels)
    try:
        import pyloudnorm
        meter = pyloudnorm.Meter(sample_rate)
        loudness = meter.integrated_loudness(data)
        if np.isfinite(loudness):
            data = data * (10.0 ** ((-14.0 - loudness) / 20.0))
    except Exception:
        pass  # too short / silent for a loudness measure — fall through to peak safety
    peak = float(np.max(np.abs(data))) or 1.0
    if peak > 0.99:
        data = data * (0.99 / peak)
    path = str(stem) + ".wav"
    sf.write(path, data, sample_rate)
    return path


def generate(body: dict) -> dict:
    import torch

    prompt = str(body.get("prompt", "")).strip()
    if not prompt:
        raise ValueError("prompt is required")
    duration = min(float(body.get("duration", 2.0)), 10.0)
    count = max(1, min(int(body.get("count", 1)), 8))
    seed = body.get("seed")
    prefix = re.sub(r"[^\w-]+", "_", str(body.get("prefix", "sfx"))) or "sfx"

    MODEL.set_generation_params(
        duration=duration,
        top_k=int(body.get("top_k", 250)),
        cfg_coef=float(body.get("cfg", 3.0)),
    )
    if seed is not None:
        torch.manual_seed(int(seed))

    t0 = time.time()
    wavs = MODEL.generate([prompt] * count)

    OUT_DIR.mkdir(exist_ok=True)
    stamp = time.strftime("%H%M%S")
    files = []
    for i, wav in enumerate(wavs):
        stem = OUT_DIR / f"{prefix}_{stamp}_{i:02d}"
        files.append(write_wav(stem, wav, MODEL.sample_rate))
    return {"ok": True, "files": files, "seconds": round(time.time() - t0, 1)}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, payload: dict):
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        # the Tool's browser UI may probe us directly
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"ok": True, "model": MODEL_NAME, "device": DEVICE})
        else:
            self._send(404, {"ok": False, "error": "unknown path"})

    def do_POST(self):
        if self.path != "/generate":
            return self._send(404, {"ok": False, "error": "unknown path"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            self._send(200, generate(body))
        except Exception as e:  # surface the real reason to the Tool
            self._send(500, {"ok": False, "error": str(e)})

    def log_message(self, fmt, *args):
        print(f"[audiogen] {self.address_string()} {fmt % args}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8188)
    ap.add_argument("--model", default="facebook/audiogen-medium")
    args = ap.parse_args()

    load_model(args.model)
    # generation holds the GPU anyway — ThreadingHTTPServer just keeps /health responsive
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"[audiogen] serving on http://127.0.0.1:{args.port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
