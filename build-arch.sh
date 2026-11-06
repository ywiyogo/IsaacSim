#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build Isaac Sim natively on a rolling distribution (Arch, Omarchy).
#
# Upstream pins CUDA 12.8, whose cudafe++ frontend cannot parse the headers of
# GCC 16/glibc 2.4x. The distro toolkit is used instead, in both build trees:
#
#   1. fetch dependencies and regenerate the premake projects,
#   2. point both CUDA trees at the distro toolkit,
#   3. build with --build-only so the dependency pull cannot restore (2).
#
# Overridable via environment:
#   ISAACSIM_CUDA_ROOT   system CUDA toolkit   (default /opt/cuda)
#   ISAACSIM_JOBS        parallel build jobs   (default: every core but one)
#
# --clean removes build output only; fetched dependencies are kept.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CUDA_ROOT="${ISAACSIM_CUDA_ROOT:-/opt/cuda}"

# --clean is intercepted so it does not need a CUDA toolkit or a job count.
BUILD_ARGS=()
CLEAN=0
for argument in "$@"; do
    case "${argument}" in
        --clean | -c) CLEAN=1 ;;
        *) BUILD_ARGS+=("${argument}") ;;
    esac
done

if [ "${CLEAN}" -eq 1 ]; then
    "${SCRIPT_DIR}/build.sh" --clean --skip-compiler-version-check
    rm -rf "${SCRIPT_DIR}/_cmake_build/isaacsim-libraries-debug" \
        "${SCRIPT_DIR}/_cmake_build/isaacsim-libraries-release"
    echo "build_arch.sh: removed _build, _compiler, _builtpackages and the libraries build trees"
    exit 0
fi

# Leave one core for the desktop. The libraries CMake stage is a separate process
# chain that never receives -j, so it reads the job count from the environment.
JOBS="${ISAACSIM_JOBS:-$(nproc --ignore=1)}"
export CMAKE_BUILD_PARALLEL_LEVEL="${JOBS}"

if [ ! -x "${CUDA_ROOT}/bin/nvcc" ]; then
    echo "build_arch.sh: no CUDA compiler at '${CUDA_ROOT}/bin/nvcc' (set ISAACSIM_CUDA_ROOT)" >&2
    exit 1
fi

# --build-only neither pulls dependencies nor generates projects, so a fresh
# checkout must be fetched and the projects generated here. On a clean tree the
# generation pass configures the libraries CMake build and fails on the vendored
# CUDA 12.8, which step 2 repairs, so require only that makefiles were written.
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

# Replace the pinned CUDA 12.8 in both build trees. This is build output, not
# source; --build-only keeps the pull from undoing it.
ln -sfn "${CUDA_ROOT}" "${SCRIPT_DIR}/_cmake_build/isaacsim-libraries-target-deps/cuda"
ln -sfn "${CUDA_ROOT}" "${SCRIPT_DIR}/_build/target-deps/cuda"

# --- wheel-staged extension prebundles -------------------------------------------
# Six extensions ship their implementation as a library wheel built by the CMake
# stage, which premake copies (not links) into pip_prebundle together with the
# extension's own python overlays. That copy runs in the prebuild step with a
# timestamp check: on a fresh tree the stage is still empty, so only the overlays
# land and Kit later fails on every import from the package (`No module named
# ...impl._logging`, `cannot import name X (unknown location)`). Re-sync the
# copies once the wheels exist.
refresh_wheel_prebundles() {
    local stage_root="${SCRIPT_DIR}/_cmake_build/extension-wheel-stages/release"
    local ext_root="${SCRIPT_DIR}/_build/linux-x86_64/release/exts"
    local stage target name
    for stage in "${stage_root}"/*/pip_prebundle; do
        [ -d "${stage}" ] || continue
        name="$(basename "$(dirname "${stage}")")"
        target="${ext_root}/${name}/pip_prebundle"
        # Symlinked prebundles already resolve to the stage; only the copied ones drift.
        [ -d "${target}" ] && [ ! -L "${target}" ] || continue
        cp -a "${stage}/." "${target}/"
    done
}

"${SCRIPT_DIR}/build.sh" --build-only --skip-compiler-version-check -j "${JOBS}" "${BUILD_ARGS[@]}"
refresh_wheel_prebundles
