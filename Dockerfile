# ============================================================
# Stage 1: Build llama.cpp from source (CPU-only)
# ============================================================
FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git ca-certificates libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

ARG LLAMA_CPP_VERSION=b8802
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

RUN hf download ggml-org/GLM-OCR-GGUF \
    GLM-OCR-f16.gguf mmproj-GLM-OCR-Q8_0.gguf \
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
COPY --from=model-fetcher /models/GLM-OCR-f16.gguf /models/GLM-OCR-f16.gguf
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
