#!/usr/bin/env bash

base=$(dirname "$(readlink -f "$0")")
install=$base/install
export PATH="$base/.clang/bin:$PATH"

set -eu

function parse_parameters() {
    while (($#)); do
        case $1 in
            all | binutils | deps | llvm | compress | release) action=$1 ;;
            *) exit 33 ;;
        esac
        shift
    done
}

function do_all() {
    do_deps
    do_llvm
    do_binutils
}

function do_binutils() {
    "$base"/build-binutils.py \
        --install-folder "$install" \
        --show-build-commands \
        --targets aarch64 arm
}

function do_deps() {
    # We only run this when running on GitHub Actions
    [[ -z ${GITHUB_ACTIONS:-} ]] && return 0

    # Refresh mirrorlist to avoid dead mirrors
    apt update -y

    apt install -y --no-install-recommends \
        bc \
        bison \
        ca-certificates \
        clang \
        cmake \
        curl \
        file \
        flex \
        g++ \
        gcc \
        gh \
        git \
        libbsd-dev \
        libcap-dev \
        libedit-dev \
        libelf-dev \
        libffi-dev \
        libssl-dev \
        libstdc++-12-dev \
        lld \
        make \
        ninja-build \
        patchelf \
        python3 \
        texinfo \
        wget \
        xz-utils \
        zlib1g-dev

    #wget -q https://github.com/llvm/llvm-project/releases/download/llvmorg-20.1.6/LLVM-20.1.6-Linux-ARM64.tar.xz
    #mkdir -p "$base"/.clang
    #tar -xf LLVM-20.1.6-Linux-ARM64.tar.xz -C "$base"/.clang
    #rm LLVM-20.1.6-Linux-ARM64.tar.xz
}

function do_llvm() {
    extra_args=()
    [[ -n ${GITHUB_ACTIONS:-} ]] && extra_args+=(--no-ccache)
    TomTal=$(nproc)
    TomTal=$TomTal+1

    "$base"/build-llvm.py \
        --install-folder "$install" \
        --vendor-string "$LLVM_VENDOR_STRING" \
        --targets AArch64 ARM \
        --defines "LLVM_PARALLEL_COMPILE_JOBS=$TomTal LLVM_PARALLEL_LINK_JOBS=$TomTal CMAKE_C_FLAGS='-g0 -O3' CMAKE_CXX_FLAGS='-g0 -O3' LLVM_USE_LINKER=lld LLVM_ENABLE_LLD=ON" \
        --projects clang compiler-rt lld polly openmp \
        --no-ccache \
        --quiet-cmake \
        --llvm-folder "$base"/llvm-project \
        --lto thin \
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
    git_hash=$(git -C "$base"/llvm-project rev-parse --short HEAD)
    clang_version=$("$base"/install/bin/clang --version | head -n 1 | awk '{print $4}')
    file_name="$LLVM_VENDOR_STRING"-clang_"$clang_version"-bookworm-aarch64-"$git_hash".tar.xz

    # Compress the install folder to save space
    mkdir -p "$base"/dist
    cd "$install"
    tar -cJf "$base"/dist/"$file_name" -- *
    curl -X POST -F "file=@$base/dist/$file_name" https://temp.wulan17.dev/api/v1/upload
}

function do_release() {
    # Upload to GitHub Releases using GitHub CLI
    file_name=""
    while IFS= read -r -d '' f; do
        file_name="$f"
        break
    done < <(find "$base"/dist/ -maxdepth 1 -name "${LLVM_VENDOR_STRING}-clang_*.tar.xz" -print0)
    if [[ -z $file_name ]]; then
        echo "No file found to upload."
        exit 1
    fi
    clang_version=$("$base"/install/bin/clang --version | head -n 1 | awk '{print $4}')
    git_hash=$(git -C "$base"/llvm-project rev-parse --short HEAD)

    TAG="$clang_version-$git_hash"
    ASSET="$file_name"
    REPO="$GITHUB_REPOSITORY"
    TITLE="$LLVM_VENDOR_STRING Clang $clang_version ($git_hash)"
    NOTES="$LLVM_VENDOR_STRING Clang $clang_version ($git_hash)"

    # Check if release exists
    if gh release view "$TAG" --repo "$REPO" &>/dev/null; then
        echo "Release $TAG exists, uploading asset..."
        gh release upload "$TAG" "$ASSET" --repo "$REPO" --clobber
    else
        echo "Release $TAG does not exist, creating release and uploading asset..."
        gh release create "$TAG" "$ASSET" \
            --title "$TITLE" \
            --notes "$NOTES" \
            --target "$GITHUB_REF_NAME" \
            --repo "$REPO"
    fi
    echo "Released successfully."
}

parse_parameters "$@"
do_"${action:=all}"
