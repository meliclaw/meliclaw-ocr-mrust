# Multi-stage build for rusto-server (pure-Rust `rten` OCR backend) — linux/arm64 target.
# No OpenCV/MNN/CUDA: those need vendor/ submodules and native toolchains not set up here.

FROM --platform=$TARGETPLATFORM rust:slim-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Cache deps separately from source changes.
COPY Cargo.toml Cargo.lock ./
COPY crates ./crates
COPY src ./src
COPY include ./include

RUN cargo build --release --locked -p rusto-server

FROM --platform=$TARGETPLATFORM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /build/target/release/rusto-server /app/rusto-server

# Model weights (det/rec .rten + dict.txt) are NOT in this repo (only dict.txt ships
# in models/) — they're fetched from https://huggingface.co/byrizki/rusto-models on
# first run and cached. Either let the container reach the internet on first start,
# or bake a cache in with a prior `rusto download` layer and mount/COPY it to
# /root/.cache/rusto/models.
ENV RUST_LOG=info
ENV OCR_LISTEN=0.0.0.0:8080
EXPOSE 8080

ENTRYPOINT ["/app/rusto-server"]
