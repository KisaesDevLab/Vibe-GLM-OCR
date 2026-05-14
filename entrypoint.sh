#!/bin/bash
set -e

# Configurable via environment variables (with sensible defaults)
PORT="${OCR_PORT:-8090}"
THREADS="${OCR_THREADS:-4}"
CTX_SIZE="${OCR_CTX_SIZE:-32768}"
TEMPERATURE="${OCR_TEMPERATURE:-0.02}"
PARALLEL="${OCR_PARALLEL:-2}"
API_KEY="${OCR_API_KEY:-}"

# GPU offload count. Default 0 = CPU-only, which is the only sensible
# value on the default `:latest` (CPU-built) image. The `:latest-cuda`
# image is built with -DGGML_CUDA=ON and is intended to be run with
# `docker run --gpus all -e OCR_GPU_LAYERS=99 …` so llama.cpp offloads
# every model layer to the GPU. 99 is the canonical "all layers"
# sentinel in llama.cpp; for GLM-OCR (0.9B, far fewer than 99 layers)
# any value above the actual layer count is treated as "all".
GPU_LAYERS="${OCR_GPU_LAYERS:-0}"

ARGS=(
    --model /models/GLM-OCR-f16.gguf
    --mmproj /models/mmproj-GLM-OCR-Q8_0.gguf
    --host 0.0.0.0
    --port "$PORT"
    --threads "$THREADS"
    --ctx-size "$CTX_SIZE"
    --flash-attn off
    --cache-type-k f16
    --cache-type-v f16
    --no-mmproj-offload
    --n-gpu-layers "$GPU_LAYERS"
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
echo "GPU layers offloaded: $GPU_LAYERS"
echo "========================="

exec llama-server "${ARGS[@]}"
