#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build Isaac Sim natively on Arch Linux.
#
# Upstream pins CUDA 12.8 and a GCC 11-era toolchain. Arch ships GCC 15/16 and
# glibc 2.4x, which the pinned toolkit cannot compile against, so the vendored
# CUDA has to be replaced with the system toolkit and the host toolchain has to
# be selected explicitly. This wrapper does exactly that and then delegates to
# ./build.sh:
#
#   1. fetch dependencies and regenerate the premake projects,
#   2. points both build trees at the system CUDA toolkit,
#   3. selects a host compiler and C++/linker flags the pinned code accepts,
#   4. builds with --build-only so the dependency pull does not reset (2) again.
#
# Overridable via environment:
#   ISAACSIM_CUDA_ROOT   system CUDA toolkit          (default /opt/cuda)
#   ISAACSIM_HOST_CC     host C compiler              (default /usr/bin/gcc-15)
#   ISAACSIM_HOST_CXX    host C++ compiler            (default /usr/bin/g++-15)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CUDA_ROOT="${ISAACSIM_CUDA_ROOT:-/opt/cuda}"
HOST_CC="${ISAACSIM_HOST_CC:-/usr/bin/gcc-15}"
HOST_CXX="${ISAACSIM_HOST_CXX:-/usr/bin/g++-15}"

if [ ! -x "${CUDA_ROOT}/bin/nvcc" ]; then
    echo "build_arch.sh: no CUDA compiler at '${CUDA_ROOT}/bin/nvcc' (set ISAACSIM_CUDA_ROOT)" >&2
    exit 1
fi
if [ ! -x "${HOST_CC}" ]; then
    echo "build_arch.sh: host C compiler '${HOST_CC}' not found (set ISAACSIM_HOST_CC)" >&2
    exit 1
fi
if [ ! -x "${HOST_CXX}" ]; then
    echo "build_arch.sh: host C++ compiler '${HOST_CXX}' not found (set ISAACSIM_HOST_CXX)" >&2
    exit 1
fi

# --build-only does not pull dependencies or generate projects, so a fresh
# checkout must be fetched, and the premake projects must be regenerated here;
# otherwise a stale _compiler/gmake2 and exts/ layout from a previous revision is
# reused. On a clean tree the generation pass also runs the libraries CMake
# configure and fails there on the vendored CUDA 12.8, which step 2 below repairs,
# so only require that the projects were actually written.
if [ ! -d "${SCRIPT_DIR}/_cmake_build/isaacsim-libraries-target-deps" ]; then
    "${SCRIPT_DIR}/build.sh" --fetch-only --skip-compiler-version-check
fi
if ! "${SCRIPT_DIR}/build.sh" --generate --skip-compiler-version-check; then
    if [ ! -f "${SCRIPT_DIR}/_compiler/gmake2/Makefile" ]; then
        echo "build_arch.sh: project generation failed before writing makefiles" >&2
        exit 1
    fi
    echo "build_arch.sh: projects generated; libraries stage failed on the vendored toolkit as expected" >&2
fi

# Replace the pinned CUDA 12.8 toolkit with the system one in both build trees.
# This is build output, not source; --build-only keeps the pull from undoing it.
ln -sfn "${CUDA_ROOT}" "${SCRIPT_DIR}/_cmake_build/isaacsim-libraries-target-deps/cuda"
ln -sfn "${CUDA_ROOT}" "${SCRIPT_DIR}/_build/target-deps/cuda"

# Host toolchain the pinned sources accept:
#   - GCC 15 rather than 16: the carb SDK redefines std::hash<__int128>, which
#     GCC 16's libstdc++ already provides, and the CMake libraries build forces
#     strict C++17 where premake's gnu++17 workarounds do not apply.
#   - -include cstdint: two ovsim headers use uintptr_t without <cstdint>.
#   - --allow-shlib-undefined: the OpenUSD module leaves USD symbols for the
#     runtime usd-core, and binutils reports those when linking an executable.
export CC="${HOST_CC}"
export CXX="${HOST_CXX}"
export CXXFLAGS="-include cstdint${CXXFLAGS:+ ${CXXFLAGS}}"
export LDFLAGS="-Wl,--allow-shlib-undefined${LDFLAGS:+ ${LDFLAGS}}"

exec "${SCRIPT_DIR}/build.sh" --build-only --skip-compiler-version-check "$@"
