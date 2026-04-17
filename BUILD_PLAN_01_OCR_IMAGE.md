# Kisaes OCR Server — Docker Image Build Plan

**Project**: `kisaes-ocr-server`
**Repository**: `KisaesDevLab/kisaes-ocr-server`
**Purpose**: Self-contained Docker image running llama.cpp server with GLM-OCR, providing an OpenAI-compatible OCR endpoint
**Target hardware**: x86_64 mini PCs and servers (CPU-only inference, no discrete GPU required)
**License**: MIT (GLM-OCR model) · MIT (llama.cpp) · MIT (Dockerfile, entrypoint scripts, and repository code)

---

## 1. What This Image Does

A single Docker container running `llama-server` from llama.cpp with GLM-OCR (0.9B parameter multimodal OCR model) baked in. It exposes an OpenAI-compatible `/v1/chat/completions` endpoint that accepts base64-encoded images and returns recognized text or structured Markdown tables.

The model files are embedded in the image — no HuggingFace downloads, no Ollama dependency, no model management at runtime. Pull the image, run it, send images.

```
                    POST /v1/chat/completions
                    (base64 image + prompt)
                            │
                    ┌───────▼────────┐
                    │  ocr-server    │
                    │  :8090         │
                    │                │
                    │  llama-server  │
                    │  GLM-OCR F16   │
                    │  ~1.8 GB model │
                    │  ~2–3 GB RAM   │
                    └────────────────┘
                            │
                    OCR text / Markdown table
```

---

## 2. Why llama.cpp Instead of Ollama

Ollama wraps llama.cpp internally. For a dedicated single-model OCR container:

- **Smaller image**: No Ollama runtime, no model registry, no Go binary — just the C++ server plus two GGUF files.
- **More control**: Direct access to `--cache-type-k`, `--flash-attn`, `--temperature` and other flags that Ollama abstracts away.
- **Slight speedup**: Community benchmarks show llama.cpp direct is marginally faster than Ollama for the same model.
- **Simpler healthcheck**: `curl /health` on a single-purpose server vs managing Ollama's model-loading lifecycle.
- **Appliance distribution**: One image, one model, one purpose.

---

## 3. GLM-OCR Model Files

GLM-OCR is a multimodal vision-language model requiring two GGUF files:

| File | Source | Size | Purpose |
|------|--------|------|---------|
| `GLM-OCR-F16.gguf` | `ggml-org/GLM-OCR-GGUF:F16` | 1.79 GB | Language decoder (GLM-0.5B) |
| `mmproj-GLM-OCR-Q8_0.gguf` | `ggml-org/GLM-OCR-GGUF` | ~160 MB | CogViT visual encoder + projection |

**Quantization rationale — F16 for the decoder**: At only 0.9B parameters, the jump from Q8_0 (950 MB) to F16 (1.79 GB) is negligible on target hardware. F16 preserves full precision for OCR accuracy on financial documents where a single misread digit matters. The mmproj stays at Q8_0 since it's only the vision encoder projection and Q8_0 is effectively lossless at this scale.

---

## 4. Dockerfile

Multi-stage build: compile llama.cpp from source in a builder stage, download model files in a fetcher stage, copy both into a minimal runtime image.

```dockerfile
# ============================================================
# Stage 1: Build llama.cpp from source (CPU-only)
# ============================================================
FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git ca-certificates libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

ARG LLAMA_CPP_VERSION=master
RUN git clone --depth 1 --branch ${LLAMA_CPP_VERSION} \
    https://github.com/ggml-org/llama.cpp.git /build/llama.cpp

WORKDIR /build/llama.cpp
RUN cmake -B build \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_CUDA=OFF \
    -DGGML_METAL=OFF \
    -DGGML_VULKAN=OFF \
    -DLLAMA_CURL=ON \
    && cmake --build build --config Release -j$(nproc) \
       --target llama-server llama-cli

# ============================================================
# Stage 2: Download model files from HuggingFace
# ============================================================
FROM ubuntu:24.04 AS model-fetcher

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip ca-certificates \
    && pip3 install --break-system-packages huggingface_hub \
    && rm -rf /var/lib/apt/lists/*

RUN huggingface-cli download ggml-org/GLM-OCR-GGUF \
    GLM-OCR-F16.gguf mmproj-GLM-OCR-Q8_0.gguf \
    --local-dir /models

# ============================================================
# Stage 3: Minimal runtime image
# ============================================================
FROM ubuntu:24.04 AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4 libgomp1 curl \
    && rm -rf /var/lib/apt/lists/*

# Copy server binary
COPY --from=builder /build/llama.cpp/build/bin/llama-server /usr/local/bin/llama-server
COPY --from=builder /build/llama.cpp/build/bin/llama-cli /usr/local/bin/llama-cli

# Copy model files (baked into image)
COPY --from=model-fetcher /models/GLM-OCR-F16.gguf /models/GLM-OCR-F16.gguf
COPY --from=model-fetcher /models/mmproj-GLM-OCR-Q8_0.gguf /models/mmproj-GLM-OCR-Q8_0.gguf

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Non-root user
RUN useradd -r -s /bin/false llama
USER llama

EXPOSE 8090

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8090/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
```

---

## 5. Entrypoint Script

```bash
#!/bin/bash
set -e

# Configurable via environment variables (with sensible defaults)
PORT="${OCR_PORT:-8090}"
THREADS="${OCR_THREADS:-4}"
CTX_SIZE="${OCR_CTX_SIZE:-16384}"
TEMPERATURE="${OCR_TEMPERATURE:-0.02}"
PARALLEL="${OCR_PARALLEL:-2}"
API_KEY="${OCR_API_KEY:-}"

ARGS=(
    --model /models/GLM-OCR-F16.gguf
    --mmproj /models/mmproj-GLM-OCR-Q8_0.gguf
    --host 0.0.0.0
    --port "$PORT"
    --threads "$THREADS"
    --ctx-size "$CTX_SIZE"
    --flash-attn off
    --cache-type-k f16
    --cache-type-v f16
    --no-mmproj-offload
    --n-gpu-layers 0
    --parallel "$PARALLEL"
    --temp "$TEMPERATURE"
    --top-k 1
    --metrics
)

# Optional API key protection
if [ -n "$API_KEY" ]; then
    ARGS+=(--api-key "$API_KEY")
fi

echo "=== Kisaes OCR Server ==="
echo "Model: GLM-OCR F16 (0.9B)"
echo "Port: $PORT"
echo "Threads: $THREADS"
echo "Context: $CTX_SIZE"
echo "Parallel slots: $PARALLEL"
echo "========================="

exec llama-server "${ARGS[@]}"
```

---

## 6. Key Server Flags Explained

| Flag | Value | Rationale |
|------|-------|-----------|
| `--flash-attn off` | Required | GLM-OCR produces incorrect output with flash attention enabled |
| `--cache-type-k f16` / `--cache-type-v f16` | Recommended | F16 KV cache matches the GLM-OCR community-tested configuration |
| `--no-mmproj-offload` | CPU mode | No discrete GPU; keeps vision encoder on CPU |
| `--n-gpu-layers 0` | CPU mode | All layers on CPU |
| `--parallel 2` | Concurrency | Two simultaneous OCR requests |
| `--temp 0.02` | Determinism | Near-zero temperature for consistent OCR output |
| `--top-k 1` | Determinism | Greedy decoding — always pick the highest-probability token |
| `--ctx-size 16384` | Image headroom | GLM-OCR needs ≥16384 context for image token processing |
| `--metrics` | Observability | Exposes `/metrics` endpoint for Prometheus scraping |

---

## 7. Configuration Reference

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OCR_PORT` | `8090` | Server listen port |
| `OCR_THREADS` | `4` | CPU threads for inference |
| `OCR_CTX_SIZE` | `16384` | Context window (must be ≥16384 for GLM-OCR images) |
| `OCR_PARALLEL` | `2` | Concurrent request slots |
| `OCR_TEMPERATURE` | `0.02` | Sampling temperature (keep low for OCR) |
| `OCR_API_KEY` | *(empty)* | Bearer token for endpoint protection (optional) |

### Endpoints

| Path | Method | Description |
|------|--------|-------------|
| `/health` | GET | Returns `{"status":"ok"}` when model is loaded |
| `/v1/chat/completions` | POST | OpenAI-compatible chat endpoint (OCR requests) |
| `/metrics` | GET | Prometheus metrics (request count, latency, tokens) |

---

## 8. API Contract

### Request Format

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

GLM-OCR supports two primary prompt prefixes:

| Prompt | Use Case |
|--------|----------|
| `Text Recognition:` | General text extraction — receipts, forms, letters, any unstructured document |
| `Table Recognition:` | Structured table extraction — returns Markdown or HTML tables |

### Response Format

Standard OpenAI chat completion response. OCR text is in `choices[0].message.content`:

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

---

## 9. Build Phases

### Phase 1 — Repository & Dockerfile (Day 1)

1. Create repository `KisaesDevLab/kisaes-ocr-server`
2. Add `README.md`, `LICENSE` (MIT), `.gitignore`, `.dockerignore`
3. Write `Dockerfile` (§4)
4. Write `entrypoint.sh` (§5)
5. Write `docker-compose.dev.yml` for local testing:
   ```yaml
   services:
     ocr-server:
       build: .
       ports:
         - "8090:8090"
       environment:
         OCR_THREADS: "4"
   ```
6. Build locally: `docker compose -f docker-compose.dev.yml build`
7. Verify `/health` returns `{"status":"ok"}`
8. Smoke test with curl:
   ```bash
   BASE64=$(base64 -w0 test-image.png)
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

**Exit criteria**: Server starts, loads model, responds to OCR request with recognizable text.

### Phase 2 — OCR Accuracy Validation (Day 2)

Test with representative document types:

1. **Bank statement** (scanned, single column) — `Table Recognition:`
2. **Bank statement** (multi-column, dense) — `Table Recognition:`
3. **Receipt** (photo, angled/shadowed) — `Text Recognition:`
4. **Invoice** (PDF rendered to PNG) — `Table Recognition:`
5. **Payroll GL report** (scanned) — `Table Recognition:`
6. **Tax form (1099/W-2)** (scanned) — `Text Recognition:`

For each test, record:
- Raw OCR output
- Processing time (target: <60s per page on CPU)
- Character-level and field-level accuracy
- Systematic errors (e.g., `$` misread as `S`, column misalignment)

**Exit criteria**: ≥90% field-level accuracy on bank statements and invoices. Known failure modes documented.

### Phase 3 — GitHub Actions & Image Publishing (Day 3)

1. Create `.github/workflows/build-ocr-image.yml`:
   ```yaml
   name: Build OCR Server Image
   on:
     push:
       tags: ['v*']
     workflow_dispatch:

   env:
     REGISTRY: ghcr.io
     IMAGE_NAME: kisaesdevlab/kisaes-ocr-server

   jobs:
     build:
       runs-on: ubuntu-latest
       permissions:
         contents: read
         packages: write
       steps:
         - uses: actions/checkout@v4
         - uses: docker/setup-buildx-action@v3
         - uses: docker/login-action@v3
           with:
             registry: ${{ env.REGISTRY }}
             username: ${{ github.actor }}
             password: ${{ secrets.GITHUB_TOKEN }}
         - id: meta
           run: echo "version=${GITHUB_REF#refs/tags/v}" >> $GITHUB_OUTPUT
         - uses: docker/build-push-action@v6
           with:
             context: .
             push: true
             tags: |
               ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:latest
               ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ steps.meta.outputs.version }}
             cache-from: type=gha
             cache-to: type=gha,mode=max
             platforms: linux/amd64
   ```
2. Tag `v1.0.0` and verify GHCR image publishes
3. Test pull on clean machine: `docker pull ghcr.io/kisaesdevlab/kisaes-ocr-server:latest`
4. Write `CLAUDE.md` for the repository

**Exit criteria**: Tagged release on GHCR, pullable and runnable on a fresh Docker host.

### Phase 4 — Hardening (Day 4)

1. Pin `LLAMA_CPP_VERSION` build arg to a specific release tag (not `master`)
2. Add `.dockerignore` to exclude test files, docs from build context
3. Verify non-root user (`llama`) has no write access to `/models`
4. Test API key protection: requests without valid `Authorization` header return 401
5. Test memory behavior under sustained load (10 sequential OCR requests)
6. Test graceful shutdown: `docker stop` sends SIGTERM, server finishes in-flight requests
7. Add log rotation guidance to README
8. Document the Q8_0 slim variant option for bandwidth-constrained deployments

**Exit criteria**: Production-ready image with security, stability, and documentation.

---

## 10. Image Size Estimate

| Layer | Size |
|-------|------|
| Ubuntu 24.04 base | ~75 MB |
| Runtime libs (libcurl, libgomp, curl) | ~15 MB |
| llama-server binary (static) | ~25 MB |
| GLM-OCR-F16.gguf | ~1,790 MB |
| mmproj-GLM-OCR-Q8_0.gguf | ~160 MB |
| **Total compressed** | **~1.5 GB** |
| **Total uncompressed** | **~2.1 GB** |

Model files are the bulk. GGUF compresses well in Docker layers. First pull is ~1.5 GB; subsequent updates that only change the entrypoint or binary are tiny delta pulls.

---

## 11. Runtime Resource Requirements

| Metric | Value |
|--------|-------|
| **RAM (idle, model loaded)** | ~2 GB |
| **RAM (peak, during inference)** | ~3 GB |
| **CPU (during inference)** | All configured threads saturated |
| **Disk (image)** | ~2.1 GB |
| **Startup time (model load)** | ~5–10s |
| **Inference time per page** | ~40–60s CPU, ~2–3s with GPU |

---

## 12. Future Considerations

**Alternative OCR models**: llama.cpp now supports several OCR models beyond GLM-OCR. The Dockerfile and entrypoint are model-agnostic — swapping models means changing the two GGUF paths and adjusting server flags:
- Deepseek-OCR — potentially better on complex tables
- HunyuanOCR — Chinese document specialist
- Dots.OCR — alternative for handwritten notes
- Gemma 4 E2B/E4B — general-purpose VLM with OCR capability

**GPU acceleration**: If a deployment target has a discrete NVIDIA GPU, switch the builder stage to `-DGGML_CUDA=ON`, use the CUDA base image, and add `--n-gpu-layers 99`. Processing time drops from ~40–60s/page to ~2–3s/page.

**Q8_0 slim variant**: A `:slim` tag using the Q8_0 decoder (950 MB vs 1.79 GB) for bandwidth-constrained deployments. Accuracy trade-off is minimal for printed documents.

**PP-DocLayout-V3 sidecar**: For complex multi-column documents, GLM-OCR's full pipeline includes a PaddlePaddle layout detection stage. This could run as a separate Python sidecar container. Deferred until accuracy testing reveals whether single-shot OCR is sufficient.
