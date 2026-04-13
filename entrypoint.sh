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
