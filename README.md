# Kisaes OCR Server

Self-contained Docker image running [llama.cpp](https://github.com/ggml-org/llama.cpp) server with [GLM-OCR](https://huggingface.co/ggml-org/GLM-OCR-GGUF) (0.9B parameter multimodal OCR model). Provides an OpenAI-compatible `/v1/chat/completions` endpoint that accepts base64-encoded images and returns recognized text or structured Markdown tables.

**No HuggingFace downloads at runtime. No Ollama dependency. No model management. Pull the image, run it, send images.**

## Quick Start

```bash
# Pull and run
docker pull ghcr.io/kisaesdevlab/vibe-glm-ocr:latest
docker run -p 8090:8090 ghcr.io/kisaesdevlab/vibe-glm-ocr:latest

# Check health
curl http://localhost:8090/health

# OCR a document
BASE64=$(base64 -w0 document.png)
curl -s http://localhost:8090/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"GLM-OCR\",
    \"messages\": [{
      \"role\": \"user\",
      \"content\": [
        {\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/png;base64,$BASE64\"}},
        {\"type\": \"text\", \"text\": \"Text Recognition:\"}
      ]
    }],
    \"temperature\": 0.02
  }"
```

## Build from Source

```bash
# Clone and build
git clone https://github.com/KisaesDevLab/Vibe-GLM-OCR.git
cd Vibe-GLM-OCR
docker compose -f docker-compose.dev.yml build

# Run locally
docker compose -f docker-compose.dev.yml up
```

## GPU support (`:latest-cuda`)

The default `:latest` image is CPU-only. For ~25× faster inference
(40-60s/page → 2-3s/page per the resource table below) on hosts with
an NVIDIA GPU, pull the CUDA variant:

```bash
docker pull ghcr.io/kisaesdevlab/vibe-glm-ocr:latest-cuda

docker run --gpus all -p 8090:8090 \
  -e OCR_GPU_LAYERS=99 \
  ghcr.io/kisaesdevlab/vibe-glm-ocr:latest-cuda
```

`OCR_GPU_LAYERS=99` tells llama.cpp to offload every model layer to the
GPU. The default is `0` (CPU-only) so the same entrypoint works on the
plain `:latest` image without modification — set it explicitly on the
CUDA image.

**Prerequisites on the host:**

1. NVIDIA driver installed: `nvidia-smi` returns a device table.
2. `nvidia-container-toolkit` installed and configured:
   ```bash
   sudo apt-get install -y nvidia-container-toolkit
   sudo nvidia-ctk runtime configure --runtime=docker
   sudo systemctl restart docker
   ```
   Verify: `docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi` prints the same table as the host.

**Image size:** ~5 GB on disk (vs ~2.1 GB for `:latest`). The CUDA
runtime base alone is ~2.5 GB; the model files contribute another ~2 GB.

**Tags published:** `:latest-cuda`, `:vX.Y.Z-cuda`, `:sha-<sha>-cuda`,
and `:main-cuda` — same scheme as the CPU variant with a `-cuda`
suffix.

Running the CUDA image without `--gpus all` is wasteful but not
broken — `OCR_GPU_LAYERS=0` keeps everything on CPU. If the host has
no GPU at all, prefer the smaller `:latest` image.

## OCR Prompts

GLM-OCR supports two primary prompt modes:

| Prompt | Use Case |
|--------|----------|
| `Text Recognition:` | General text extraction — receipts, forms, letters, any unstructured document |
| `Table Recognition:` | Structured table extraction — returns Markdown or HTML tables |

## API

### Request

```json
{
  "model": "GLM-OCR",
  "messages": [{
    "role": "user",
    "content": [
      {
        "type": "image_url",
        "image_url": {
          "url": "data:image/png;base64,{base64data}"
        }
      },
      {
        "type": "text",
        "text": "Table Recognition:"
      }
    ]
  }],
  "temperature": 0.02
}
```

### Response

Standard OpenAI chat completion format. OCR text is in `choices[0].message.content`:

```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "content": "| Date | Description | Amount | Balance |\n|---|---|---|---|\n| 01/15 | Direct Deposit | 3,500.00 | 4,200.50 |"
    },
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 1842,
    "completion_tokens": 156,
    "total_tokens": 1998
  }
}
```

### Endpoints

| Path | Method | Description |
|------|--------|-------------|
| `/health` | GET | Returns `{"status":"ok"}` when model is loaded |
| `/v1/chat/completions` | POST | OpenAI-compatible chat endpoint (OCR requests) |
| `/metrics` | GET | Prometheus metrics (request count, latency, tokens) |

## Configuration

All configuration is via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `OCR_PORT` | `8090` | Server listen port |
| `OCR_THREADS` | `4` | CPU threads for inference |
| `OCR_CTX_SIZE` | `32768` | Context window (must be >= 16384 for GLM-OCR images) |
| `OCR_PARALLEL` | `2` | Concurrent request slots |
| `OCR_TEMPERATURE` | `0.02` | Sampling temperature (keep low for OCR) |
| `OCR_API_KEY` | *(empty)* | Bearer token for endpoint protection (optional) |
| `OCR_GPU_LAYERS` | `0` | GPU layers to offload. Only meaningful on the `:latest-cuda` image. Set to `99` (or any value ≥ the model's layer count) to offload everything. Default `0` keeps the same entrypoint working on the CPU image. |

### Example with custom config

```bash
docker run -p 9090:9090 \
  -e OCR_PORT=9090 \
  -e OCR_THREADS=8 \
  -e OCR_PARALLEL=4 \
  -e OCR_API_KEY=my-secret-key \
  ghcr.io/kisaesdevlab/vibe-glm-ocr:latest
```

## Architecture

```
                POST /v1/chat/completions
                (base64 image + prompt)
                        |
                +-------v--------+
                |  ocr-server    |
                |  :8090         |
                |                |
                |  llama-server  |
                |  GLM-OCR F16   |
                |  ~1.8 GB model |
                |  ~2-3 GB RAM   |
                +----------------+
                        |
                OCR text / Markdown table
```

## Resource Requirements

| Metric | Value |
|--------|-------|
| RAM (idle, model loaded) | ~2 GB |
| RAM (peak, during inference) | ~3 GB |
| CPU (during inference) | All configured threads saturated |
| Disk (image) | ~2.1 GB |
| Startup time (model load) | ~5-10s |
| Inference time per page | ~40-60s CPU, ~2-3s with GPU |

## Why llama.cpp Instead of Ollama

- **Smaller image**: No Ollama runtime, no model registry, no Go binary
- **More control**: Direct access to `--cache-type-k`, `--flash-attn`, `--temperature` flags
- **Slight speedup**: llama.cpp direct is marginally faster than Ollama for the same model
- **Simpler healthcheck**: `curl /health` on a single-purpose server
- **Appliance model**: One image, one model, one purpose

## Model Details

| File | Size | Purpose |
|------|------|---------|
| `GLM-OCR-F16.gguf` | 1.79 GB | Language decoder (GLM-0.5B) — F16 for max OCR accuracy |
| `mmproj-GLM-OCR-Q8_0.gguf` | ~160 MB | CogViT visual encoder + projection |

F16 is chosen for the decoder because at only 0.9B parameters, the size difference vs Q8_0 is negligible, while F16 preserves full precision for financial documents where a single misread digit matters.

### Slim variant (Q8_0 decoder)

For bandwidth-constrained deployments, a `:slim` tag using the Q8_0 decoder (~950 MB vs 1.79 GB) reduces the compressed image by roughly 700 MB. Accuracy loss is minimal for printed documents; for handwritten notes or faint scans, stick with the default F16 tag.

```bash
docker pull ghcr.io/kisaesdevlab/vibe-glm-ocr:slim
```

To build slim locally, override the decoder filename in a fork of the Dockerfile's `model-fetcher` stage (`GLM-OCR-Q8_0.gguf`) and update the entrypoint's `--model` path.

## Operations

### Log rotation

`llama-server` logs request lines and token counts to stdout. Under sustained traffic, unbounded Docker logs will eventually fill the host disk. Configure the `json-file` driver with rotation, or switch to `journald` / a remote syslog sink.

Per-container (Docker CLI):

```bash
docker run -p 8090:8090 \
  --log-driver json-file \
  --log-opt max-size=50m \
  --log-opt max-file=5 \
  ghcr.io/kisaesdevlab/vibe-glm-ocr:latest
```

Compose:

```yaml
services:
  ocr-server:
    image: ghcr.io/kisaesdevlab/vibe-glm-ocr:latest
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
```

Host-wide default lives in `/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "5" }
}
```

## License

MIT (Dockerfile, entrypoint scripts, and repository code). GLM-OCR model is MIT licensed. llama.cpp is MIT licensed.
