# Deploying `rusto-server` (ARM64 Linux VM, built on macOS)

Validated end-to-end on 2026-11-13: built the image on an Apple Silicon Mac
(native `linux/arm64`, no emulation), served real OCR requests against
PP-OCRv6 medium weights, got >0.98 confidence scores on a test ID card image.

## 1. Build the image

```bash
docker buildx build --platform linux/arm64 -t meliclaw-ocr-mrust:arm64 .
```

Uses the `rten` feature only (pure Rust ONNX runtime) — no OpenCV, no MNN, no
CUDA, so it needs none of this repo's `vendor/` submodules or extra native
toolchains. Builder stage is `rust:slim-bookworm`; pin to a specific tag once
this is wired into CI. `rust:1.82` is too old — `rten` 0.27 needs rustc ≥ 1.94,
so stick with the rolling `slim-bookworm` tag or something newer.

To ship the same image to the Linux ARM64 VM: either `docker save` /
`docker load` the tar, push it to a registry the VM can pull from, or run the
same `buildx` command directly on the VM (it's native arm64 there too, no
cross-compilation needed either way).

## 2. Get model weights onto disk

**The repo's `models/` directory only ships dictionaries (`dict.txt`), not the
det/rec weight files.** `rusto-server` has no auto-download built in (that
exists only in the CLI/SDK via `rusto download`) — it hard-requires
`det.onnx` + `rec.onnx` + `dict.txt` already sitting on disk before it starts.

Weights already fetched for this project live at:

```
/Volumes/AILabs/Models/paddlex/2026/official_models/PP-OCRv6_medium_det_onnx/inference.onnx
/Volumes/AILabs/Models/paddlex/2026/official_models/PP-OCRv6_medium_rec_onnx/inference.onnx
```

Build a model directory from them — **copy the files, don't symlink**:
a symlink pointing outside the Docker bind-mount path resolves to nothing
inside the container.

```bash
mkdir -p /path/to/models/medium
cp "/Volumes/AILabs/Models/paddlex/2026/official_models/PP-OCRv6_medium_det_onnx/inference.onnx" /path/to/models/medium/det.onnx
cp "/Volumes/AILabs/Models/paddlex/2026/official_models/PP-OCRv6_medium_rec_onnx/inference.onnx" /path/to/models/medium/rec.onnx
cp models/PPOCR_v6_medium/dict.txt /path/to/models/medium/dict.txt
```

`OCR_MODELS_DIR` expects a *parent* directory containing one subdirectory per
model (each with its own `det.onnx`/`rec.onnx`/`dict.txt`); the subdirectory
name becomes the model's `model` id in API requests. Other PP-OCRv6/v5/v4
tiers can be added the same way as additional subdirectories, as long as
their ONNX exports and matching dict are both present.

Copy or rsync `/path/to/models` to the Linux VM before running the container
there too.

## 3. Run it

```bash
docker run -d -p 8080:8080 \
  -v /path/to/models:/app/models:ro \
  -e OCR_MODELS_DIR=/app/models \
  meliclaw-ocr-mrust:arm64
```

`OCR_LISTEN` defaults to `0.0.0.0:8080` in this image (set in the Dockerfile —
upstream's own default is `127.0.0.1:8895`, which wouldn't be reachable from
outside the container). Override with `-e OCR_LISTEN=...` if needed.

Other relevant env vars (see `crates/rusto-server/src/main.rs`):
- `OCR_DEFAULT_MODEL` — which model id answers requests that don't specify one.
- `OCR_POOL_SIZE` — inference worker pool size (default 2).
- `OCR_API_KEY` — require a bearer token.
- `OCR_ALLOWED_HOSTS` — comma-separated allowlist for `document_url` fetches.
- `OCR_AUTOROTATE` — `1`/`true`/`yes`/`on` to auto-correct image orientation.

## 4. Call it

The API is Mistral-OCR-compatible, **not** a bare `{"image": ...}` body:

```bash
curl -X POST http://<host>:8080/v1/ocr \
  -H "Content-Type: application/json" \
  -d '{
    "model": "medium",
    "document": {
      "type": "image_url",
      "image_url": "data:image/jpeg;base64,<...>"
    }
  }'
```

`document.type` can also be `"document_url"` for a remote/data URI pointing
at a PDF or image; `OCR_ALLOWED_HOSTS` gates which remote hosts are fetched.

## Known gaps / next steps

- No model-weight stage baked into the Dockerfile on purpose (per team
  decision 2026-11-13) — weights are mounted at run time, not shipped in the
  image. If that changes, add a build stage that copies them in from a fixed
  path or fetches them from Hugging Face (`byrizki/rusto-models`) at build
  time, and pin a `--locked` `Cargo.lock` compatible rustc version in the
  `FROM` line instead of the rolling `slim-bookworm` tag.
- Not yet tested on the actual Linux ARM64 VM — only cross-validated locally
  under Docker Desktop/OrbStack's native arm64 execution on Apple Silicon.
  Confirm the VM's kernel/cgroups support is current enough for the same
  base images before assuming parity.
