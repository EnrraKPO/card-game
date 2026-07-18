# AudioGen SFX server

The sound twin of the ComfyUI image server: Meta's **AudioGen** (audiocraft)
loaded once and kept warm behind a tiny local HTTP API, so the authoring Tool
can generate sound-effect candidates for `data/sounds/sounds.json` entries.

## Run

    start_server.bat            # → http://127.0.0.1:8188

First launch downloads ~4GB of model weights (facebook/audiogen-medium) from
HuggingFace into the user cache. The bat file points Python at `ca_bundle.pem`
(standard CAs + Avast's HTTPS-scanning cert) — without it every download on
this machine fails SSL verification.

## Tool integration

The Tool (Tool/server.js) talks to this server via the `audiogenUrl` setting
(default `http://127.0.0.1:8188`):

- Sounds tab → "AI generation — local AudioGen" box: generate N candidate wavs
  from the entry's AI prompt, audition, install one as `assets/sound/<id>.wav`
  (also stamps the entry's `file` field).
- Candidates live in `Tool/workspace/sfx/<id>/` until installed or discarded.

## Setup notes (how the venv was built)

The RTX 5090 (Blackwell, sm_120) needs a torch newer than audiocraft's pins,
so the venv was built with explicit versions and `--no-deps`:

    python -m venv venv
    venv\Scripts\python -m pip install "torch==2.9.1+cu128" "torchaudio==2.9.1+cu128" numpy ^
        --index-url https://download.pytorch.org/whl/cu128 --extra-index-url https://pypi.org/simple
    venv\Scripts\python -m pip install audiocraft --no-deps
    venv\Scripts\python -m pip install av einops flashy hydra-core hydra_colorlog julius ^
        num2words sentencepiece tqdm transformers huggingface_hub encodec protobuf soundfile ^
        spacy librosa torchmetrics
    rem xformers MUST match the torch build (0.0.33.post1 ↔ torch 2.9.1); --no-deps keeps torch
    venv\Scripts\python -m pip install "xformers==0.0.33.post1" --no-deps ^
        --index-url https://download.pytorch.org/whl/cu128

The "A matching Triton is not available" warning at startup is benign (no Triton
on Windows). audiocraft's declared pins (torch 2.1, xformers<0.0.23, av 11) are
IGNORED on purpose — they predate Blackwell GPUs.

(All pip runs need `PIP_CERT=ca_bundle.pem` on this machine — Avast intercepts
HTTPS and Python doesn't trust its cert by default.)
