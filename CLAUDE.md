# Kisaes OCR Server

## Project Overview

Self-contained Docker image running llama.cpp server with GLM-OCR (0.9B parameter multimodal OCR model). Provides an OpenAI-compatible `/v1/chat/completions` endpoint for OCR.

## Architecture

- **Dockerfile**: Multi-stage build (builder -> model-fetcher -> runtime)
- **entrypoint.sh**: Configurable startup script with environment variables
- **Runtime**: llama-server serving GLM-OCR F16 on CPU

## Key Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Multi-stage build for the OCR server image |
| `entrypoint.sh` | Container entrypoint with env-var configuration |
| `docker-compose.dev.yml` | Local development/testing compose file |
| `.github/workflows/build-ocr-image.yml` | CI/CD to build and push to GHCR |

## Build & Run

```bash
# Build locally
docker compose -f docker-compose.dev.yml build

# Run
docker compose -f docker-compose.dev.yml up

# Test
curl http://localhost:8090/health
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OCR_PORT` | `8090` | Server listen port |
| `OCR_THREADS` | `4` | CPU threads for inference |
| `OCR_CTX_SIZE` | `16384` | Context window size |
| `OCR_PARALLEL` | `2` | Concurrent request slots |
| `OCR_TEMPERATURE` | `0.02` | Sampling temperature |
| `OCR_API_KEY` | *(empty)* | Bearer token for endpoint protection |

## Important Notes

- GLM-OCR requires `--flash-attn off` (produces incorrect output otherwise)
- Context size must be >= 16384 for image token processing
- F16 decoder chosen for OCR accuracy on financial documents
- Model files are baked into the Docker image (~2 GB total)
