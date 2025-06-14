#!/usr/bin/env bash

base=$(dirname "$(readlink -f "$0")")
install=$base/install
src=$base/src
export PATH="$base/.clang/bin:$PATH"

set -eu

function parse_parameters() {
    while (($#)); do
        case $1 in
            all | binutils | deps | kernel | llvm | compress) action=$1 ;;
            *) exit 33 ;;
        esac
        shift
    done
}

function do_all() {
    do_deps
    do_llvm
    do_binutils
    do_kernel
}

function do_binutils() {
    "$base"/build-binutils.py \
        --install-folder "$install" \
        --show-build-commands \
        --targets aarch64 arm x86_64
}

function do_deps() {
    # We only run this when running on GitHub Actions
    [[ -z ${GITHUB_ACTIONS:-} ]] && return 0

    # Refresh mirrorlist to avoid dead mirrors
    pacman -Syu --noconfirm

    pacman -S --noconfirm --needed \
        base-devel \
        bc \
        bison \
        ccache \
        clang \
        cmake \
        compiler-rt \
        cpio \
        curl \
        flex \
        git \
        libarchive \
        libbsd \
        libcap \
        libedit \
        libelf \
        libffi \
        libtool \
        lld \
        llvm \
        ninja \
        openmp \
        openssl \
        patchelf \
        python3 \
        texinfo \
        uboot-tools \
        wget \
        xz \
        zlib

}

function do_kernel() {
    local branch=linux-rolling-stable
    local linux=$src/$branch

    if [[ -d $linux ]]; then
        git -C "$linux" fetch --depth=1 origin $branch
        git -C "$linux" reset --hard FETCH_HEAD
    else
        git clone \
            --branch "$branch" \
            --depth=1 \
            --single-branch \
            https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git \
            "$linux"
    fi

    cat <<EOF | env PYTHONPATH="$base"/tc_build python3 -
from pathlib import Path

from kernel import LLVMKernelBuilder

builder = LLVMKernelBuilder()
builder.folders.build = Path('$base/build/linux')
builder.folders.source = Path('$linux')
builder.matrix = {'defconfig': ['X86']}
builder.toolchain_prefix = Path('$install')

builder.build()
EOF
}

function do_llvm() {
    extra_args=()
    [[ -n ${GITHUB_ACTIONS:-} ]] && extra_args+=(--no-ccache)
    TomTal=$(nproc)
    TomTal=$TomTal+1

    "$base"/build-llvm.py \
        --install-folder "$install" \
        --vendor-string "Mayuri" \
        --targets AArch64 ARM X86 \
        --defines "LLVM_PARALLEL_COMPILE_JOBS=$TomTal LLVM_PARALLEL_LINK_JOBS=$TomTal CMAKE_C_FLAGS='-g0 -O3' CMAKE_CXX_FLAGS='-g0 -O3' LLVM_USE_LINKER=lld LLVM_ENABLE_LLD=ON" \
        --shallow-clone \
        --projects clang compiler-rt lld polly openmp \
        --no-ccache \
        --quiet-cmake \
        "${extra_args[@]}"
}

function do_compress() {

    # Remove unnecessary files
    rm -fr "$install"/include
    rm -f "$install"/lib/*.a "$install"/lib/*.la

    # Strip remaining binaries
    for f in $(find install -type f -exec file {} \; | grep 'not stripped' | awk '{print $1}'); do
        strip -s "${f::-1}"
    done

    # Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
    for bin in $(find install -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
        # Remove last character from file output (':')
        bin="${bin::-1}"

        echo "$bin"
        patchelf --set-rpath install/lib "$bin"
    done

    # Get git commit hash
    git_hash=$(git -C "$base"/src/llvm-project rev-parse --short HEAD)

    # Compress the install folder to save space
    make -p "$base"/dist
    cd "$install"
    tar -cJf "$base"/dist/Mayuri-clang_21.0.0git-archlinux-"$git_hash".tar.xz -- *
    curl -X POST -F "file=@$base/dist/Mayuri-clang_21.0.0git-archlinux-$git_hash.tar.xz" https://temp.wulan17.dev/api/v1/upload
}

parse_parameters "$@"
do_"${action:=all}"
