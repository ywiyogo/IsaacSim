#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Launch the source-built Isaac Sim on a rolling distribution (Arch, Omarchy).
#
# A plain _build/linux-x86_64/release/isaac-sim.sh fails here for two reasons:
#
#   1. omni.kit.loop-isaac (the run loop) starts before omni.usd.libs and links
#      libusd_python.so. Nothing puts the USD libraries on the loader path, so the
#      plugin fails to load, Kit finds no run loop, and the app auto-quits after
#      0 frames. The USD libs shipped inside the omni.usd.libs extension must be
#      on LD_LIBRARY_PATH up front. (Using the packman USD at
#      _build/target-deps/usd/release/lib instead loads a second OpenUSD copy and
#      aborts with "Multiple definitions of TfEnvSetting".)
#
#   2. libxml2 2.15 bumped the SONAME to libxml2.so.16, while the prebuilt
#      libfbxsdk.so in the asset-converter extension links libxml2.so.2. A
#      compatibility link satisfies the loader.
#
#   3. the kernel driver must be loaded; without it every CUDA call fails with the
#      misleading "cudaErrorInsufficientDriver" because libcuda.so.1 cannot be
#      loaded at all.
#
# Usage: ./run_arch.sh [isaac-sim.sh arguments]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="${SCRIPT_DIR}/_build/linux-x86_64/release"

if [ ! -x "${RELEASE_DIR}/isaac-sim.sh" ]; then
    echo "run_arch.sh: '${RELEASE_DIR}/isaac-sim.sh' not found; run ./build_arch.sh first" >&2
    exit 1
fi

# --- NVIDIA kernel driver -------------------------------------------------------
if [ ! -e /proc/driver/nvidia/version ]; then
    echo "run_arch.sh: the NVIDIA kernel driver is not loaded; install nvidia-open-dkms" >&2
    echo "run_arch.sh: and nvidia-utils matching the toolkit (CUDA 13.4 needs driver >= 580)" >&2
    exit 1
fi

# --- libxml2.so.2 compatibility -------------------------------------------------
compat_dir="${ISAACSIM_XML2_COMPAT_DIR:-${RELEASE_DIR}/.arch-compat}"
mkdir -p "${compat_dir}"
if [ ! -e "${compat_dir}/libxml2.so.2" ]; then
    libxml2_16=""
    for candidate in /usr/lib/libxml2.so.16 /usr/lib64/libxml2.so.16 /usr/lib/x86_64-linux-gnu/libxml2.so.16; do
        if [ -e "${candidate}" ]; then
            libxml2_16="${candidate}"
            break
        fi
    done
    if [ -z "${libxml2_16}" ]; then
        # Fall back to ldconfig, keeping only the 64-bit entry (lib32-libxml2 may be installed too).
        libxml2_16="$(ldconfig -p | awk '/libxml2\.so\.16 .*x86-64/ { found = $NF } END { print found }')"
    fi
    if [ -z "${libxml2_16}" ]; then
        echo "run_arch.sh: libxml2.so.16 not found; cannot provide the libxml2.so.2 the Omni extensions expect" >&2
        exit 1
    fi
    ln -sfn "${libxml2_16}" "${compat_dir}/libxml2.so.2"
fi

# --- OpenUSD libraries for the run loop -----------------------------------------
usd_libs_bin=""
for candidate in "${RELEASE_DIR}"/extscache/omni.usd.libs-*/bin; do
    if [ -d "${candidate}" ]; then
        usd_libs_bin="${candidate}"
        break
    fi
done
if [ -z "${usd_libs_bin}" ]; then
    echo "run_arch.sh: no omni.usd.libs extension under '${RELEASE_DIR}/extscache'" >&2
    exit 1
fi

export LD_LIBRARY_PATH="${usd_libs_bin}:${compat_dir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# --- Render offload on hybrid graphics ------------------------------------------
# The integrated GPU drives the display on this class of laptop, so GLX/Vulkan would
# pick it and report no CUDA device. Force the NVIDIA GPU for both APIs.
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __VK_LAYER_NV_optimus=NVIDIA_only

cd "${RELEASE_DIR}"
exec ./isaac-sim.sh "$@"
