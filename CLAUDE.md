# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains resources for deploying Kubernetes clusters and AI/ML workloads on Rockchip-based single-board computers (SBCs), specifically optimized for the Turing Machines RK1 board (RK3588 SoC).

## Directory Structure

```
repo/
├── sbc-rockchip/      # Talos Linux overlay for Rockchip boards (21+ boards supported)
├── u-boot-rockchip/   # U-Boot bootloader (Rockchip fork)
├── rknn-toolkit2/     # RKNN SDK v2.3.2 for vision model conversion/deployment
├── rknn-llm/          # RKLLM v1.2.3 for LLM inference on NPU
└── rknn_model_zoo/    # Pre-built model examples (40+ models)
docs/                  # Talos setup guides and Rockchip SDK documentation (PDFs)
images/                # Talos Linux images (decompress before flashing)
```

## Build Commands

### sbc-rockchip (Talos overlay)

Requires: git, make, docker (19.03+), docker buildx

```bash
# Create buildx builder (one-time setup)
docker buildx create --name local --use

# Build all targets
make

# Build specific target
make target-<target_name>

# Build with local output
make local-<target_name> DEST=./output

# View help and available targets
make help

# Update checksums after version changes
make update-checksums

# Regenerate Makefile from .kres.yaml
make rekres
```

### rknn_model_zoo (AI model examples)

```bash
# Build a demo for Linux
./build-linux.sh -t <target> -a <arch> -d <demo_name> [-b <build_type>] [-m] [-r] [-j]

# Options:
#   -t: target SoC (rk356x/rk3588/rk3576/rv1126b/rv1106/rk1808/rv1126)
#   -a: architecture (aarch64/armhf)
#   -d: demo name (e.g., mobilenet, yolov5)
#   -b: build type (Debug/Release, default: Release)
#   -m: enable address sanitizer
#   -r: disable RGA (use CPU resize)
#   -j: disable libjpeg

# Example: Build mobilenet for RK3588
./build-linux.sh -t rk3588 -a aarch64 -d mobilenet

# Set cross-compiler if needed
export GCC_COMPILER=aarch64-linux-gnu
```

### rknn-llm examples

```bash
cd examples/rkllm_api_demo/deploy
./build-linux.sh   # or build-android.sh

# Server demos
cd examples/rkllm_server_demo
./build_rkllm_server_flask.sh
./build_rkllm_server_gradio.sh
```

## Target Platform Reference

| SoC Family | Targets |
|------------|---------|
| RK3588 | rk3588 (Orange Pi 5/5+/5 Max, Rock 5A/5B/5T, **Turing RK1**) |
| RK3576 | rk3576 |
| RK356x | rk356x (covers rk3562, rk3566, rk3568) |
| RV1126B | rv1126b |
| RV1106/1103 | rv1106 (requires arm-rockchip830 toolchain) |

## Architecture Notes

**Layered Stack**: U-Boot bootloader → Talos Linux OS → Kubernetes → AI workloads

**NPU Model Pipeline**:
1. Convert models using RKNN-Toolkit2 (vision) or RKLLM-Toolkit (LLM) on PC
2. Deploy converted `.rknn` or `.rkllm` models to device
3. Run inference using RKNN Runtime C/C++ API or Python bindings

**Cross-compilation**: Most components require ARM cross-compilers:
- `aarch64-linux-gnu` for RK3588/RK3576/RK356x
- `arm-linux-gnueabihf` for RV1109/RV1126
- `arm-rockchip830-linux-uclibcgnueabihf` for RV1106/RV1103

## Prerequisites

System tools needed for this project:
- `talosctl` - Talos cluster management CLI
- `tpi` - Turing Pi CLI
- `crane` - Container image management
- Docker with buildx support

## SSH Access

Access Turing BMC cluster:
```bash
ssh turing-bmc
```
SSH config is in `~/.ssh/`.

## Performance Testing (RKLLM)

```bash
# Set NPU frequency (run on target device from rknn-llm/scripts/)
./set_freq.sh

# Enable performance logging
export RKLLM_LOG_LEVEL=1

# Monitor CPU/NPU utilization
./eval_perf_watch_cpu.sh
./eval_perf_watch_npu.sh
```

## Supported LLM Models (RKLLM)

Qwen2/2.5/3 series, Llama, TinyLlama, Phi2/3, ChatGLM3, Gemma2/3, InternLM2, MiniCPM, DeepSeek-R1-Distill, and vision models: Qwen-VL, InternVL3, MiniCPM-V, Janus-Pro, DeepSeek-OCR.

## Python Environment

RKNN-Toolkit2: Python 3.6-3.12
RKLLM-Toolkit: Python 3.9-3.12 (RWKV models require Python 3.12)
