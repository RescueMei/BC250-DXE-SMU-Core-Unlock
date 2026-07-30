#!/usr/bin/env bash
set -euo pipefail

# PODMAN ONLY
# Containerized build helper for generating both the raw DXE PE32 image (.efi)
# and a firmware-file-system driver (.ffs) suitable for insertion into an AMI
# DXE firmware volume with UEFITool.
#
# Default behavior uses the Tianocore Fedora 41 development container so the
# build does not depend on a pre-existing host edk2 checkout. A host build mode
# is also available by setting NO_CONTAINER=1 and EDK2_DIR.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="$REPO_DIR/Bc250CoreUnlockPkg"
PLATFORM_DSC="$PKG_DIR/Bc250CoreUnlockPkg.dsc"
MODULE_INF="$PKG_DIR/Bc250CoreUnlockDxe/Bc250CoreUnlockDxe.inf"
OUTPUT_DIR="$REPO_DIR/Build/Output"
MODULE_NAME="MeiMeiBc250CoreUnlockDxe"
MODULE_GUID="2f3d426d-6a54-4a6b-82d0-1207cc5b6d92"

ARCH="${ARCH:-X64}"
TARGET="${TARGET:-RELEASE}"
TOOL_CHAIN_TAG="${TOOL_CHAIN_TAG:-CLANGDWARF}"

CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"
EDK2_IMAGE="${EDK2_IMAGE:-ghcr.io/tianocore/containers/fedora-41-dev:latest}"
EDK2_REPO="${EDK2_REPO:-https://github.com/tianocore/edk2.git}"
EDK2_REF="${EDK2_REF:-master}"
NO_CONTAINER="${NO_CONTAINER:-0}"

CACHE_DIR="$REPO_DIR/.cache"
EDK2_CACHE_DIR="$CACHE_DIR/edk2"
CONTAINER_CACHE_ROOT="/cache"
CONTAINER_EDK2_DIR="$CONTAINER_CACHE_ROOT/edk2"

find_basetool() {
  local tool_name="$1"
  local candidate

  for candidate in \
    "$EDK2_DIR/BaseTools/BinWrappers/PosixLike/${tool_name}" \
    "$EDK2_DIR/BaseTools/Source/C/bin/${tool_name}"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

source_edksetup() {
  local edksetup_path="$1"
  local had_nounset=0
  local had_errexit=0

  case $- in
    *e*) had_errexit=1 ;;
    *u*) had_nounset=1 ;;
  esac

  set +eu
  # shellcheck disable=SC1090
  source "$edksetup_path" >/dev/null

  if [[ "$had_errexit" == "1" ]]; then
    set -e
  else
    set +e
  fi

  if [[ "$had_nounset" == "1" ]]; then
    set -u
  else
    set +u
  fi
}

generate_ffs() {
  local efi_path="$1"
  local gensec="$2"
  local genffs="$3"
  local pe32_sec ui_sec ffs_path efi_copy

  mkdir -p "$OUTPUT_DIR"

  pe32_sec="$OUTPUT_DIR/${MODULE_NAME}.pe32.sec"
  ui_sec="$OUTPUT_DIR/${MODULE_NAME}.ui.sec"
  ffs_path="$OUTPUT_DIR/${MODULE_NAME}.ffs"
  efi_copy="$OUTPUT_DIR/${MODULE_NAME}.efi"

  cp "$efi_path" "$efi_copy"

  "$gensec" \
    -s EFI_SECTION_PE32 \
    -o "$pe32_sec" \
    "$efi_copy"

  "$gensec" \
    -s EFI_SECTION_USER_INTERFACE \
    -n "$MODULE_NAME" \
    -o "$ui_sec"

  "$genffs" \
    -t EFI_FV_FILETYPE_DRIVER \
    -g "$MODULE_GUID" \
    -o "$ffs_path" \
    -i "$pe32_sec" \
    -i "$ui_sec"

  echo "Build complete:"
  echo "  EFI: $efi_copy"
  echo "  FFS: $ffs_path"
}

build_with_host_edk2() {
  local gensec genffs efi_path

  if [[ -z "${EDK2_DIR:-}" ]]; then
    echo "error: set EDK2_DIR to your edk2 workspace root when NO_CONTAINER=1" >&2
    exit 1
  fi

  if [[ ! -d "$EDK2_DIR" ]]; then
    echo "error: EDK2_DIR does not exist: $EDK2_DIR" >&2
    exit 1
  fi

  if [[ ! -f "$EDK2_DIR/edksetup.sh" ]]; then
    echo "error: $EDK2_DIR does not look like an edk2 workspace (missing edksetup.sh)" >&2
    exit 1
  fi

  cd "$EDK2_DIR"
  export WORKSPACE="$EDK2_DIR"
  export PACKAGES_PATH="$REPO_DIR:$EDK2_DIR${PACKAGES_PATH:+:$PACKAGES_PATH}"
  export PYTHON_COMMAND="${PYTHON_COMMAND:-python3}"

  source_edksetup "$EDK2_DIR/edksetup.sh"

  gensec="$(find_basetool GenSec || true)"
  genffs="$(find_basetool GenFfs || true)"

  if [[ -z "$gensec" || -z "$genffs" ]]; then
    echo "error: BaseTools GenSec/GenFfs binaries are missing. Build BaseTools first." >&2
    exit 1
  fi

  build \
    -a "$ARCH" \
    -b "$TARGET" \
    -t "$TOOL_CHAIN_TAG" \
    -p "$PLATFORM_DSC" \
    -m "$MODULE_INF"

  efi_path="$EDK2_DIR/Build/MeiMeiBc250CoreUnlockPkg/${TARGET}_${TOOL_CHAIN_TAG}/$ARCH/${MODULE_NAME}.efi"
  if [[ ! -f "$efi_path" ]]; then
    efi_path="$(find "$EDK2_DIR/Build/MeiMeiBc250CoreUnlockPkg" -type f -name "${MODULE_NAME}.efi" | head -n 1)"
  fi

  if [[ -z "$efi_path" || ! -f "$efi_path" ]]; then
    echo "error: failed to locate built EFI image" >&2
    exit 1
  fi

  generate_ffs "$efi_path" "$gensec" "$genffs"
}

build_with_container() {
  if ! command -v "$CONTAINER_ENGINE" >/dev/null 2>&1; then
    echo "error: container engine not found: $CONTAINER_ENGINE" >&2
    exit 1
  fi

  mkdir -p "$CACHE_DIR" "$EDK2_CACHE_DIR" "$OUTPUT_DIR"

  "$CONTAINER_ENGINE" run --rm \
    -v "$REPO_DIR:/workspace/BC250-DXE-SMU-Core-Unlock:Z" \
    -v "$CACHE_DIR:$CONTAINER_CACHE_ROOT:Z" \
    -w /workspace/BC250-DXE-SMU-Core-Unlock \
    -e ARCH="$ARCH" \
    -e TARGET="$TARGET" \
    -e TOOL_CHAIN_TAG="$TOOL_CHAIN_TAG" \
    -e EDK2_REPO="$EDK2_REPO" \
    -e EDK2_REF="$EDK2_REF" \
    -e MODULE_GUID="$MODULE_GUID" \
    -e MODULE_NAME="$MODULE_NAME" \
    -e CONTAINER_CACHE_ROOT="$CONTAINER_CACHE_ROOT" \
    -e CONTAINER_EDK2_DIR="$CONTAINER_EDK2_DIR" \
    "$EDK2_IMAGE" \
    bash -lc '
      set -euo pipefail

      mkdir -p "$CONTAINER_CACHE_ROOT"

      refresh_edk2_checkout() {
        local tmp_dir="${CONTAINER_EDK2_DIR}.tmp.$$"

        rm -rf "$tmp_dir"
        git clone --depth 1 --branch "$EDK2_REF" "$EDK2_REPO" "$tmp_dir"
        rm -rf "$CONTAINER_EDK2_DIR.old"

        if [[ -e "$CONTAINER_EDK2_DIR" ]]; then
          mv "$CONTAINER_EDK2_DIR" "$CONTAINER_EDK2_DIR.old"
        fi

        mv "$tmp_dir" "$CONTAINER_EDK2_DIR"
        rm -rf "$CONTAINER_EDK2_DIR.old"
      }

      if [[ ! -e "$CONTAINER_EDK2_DIR" ]]; then
        refresh_edk2_checkout
      elif [[ ! -d "$CONTAINER_EDK2_DIR/.git" ]]; then
        echo "warning: cache path is not a git checkout, refreshing it"
        refresh_edk2_checkout
      fi

      cd "$CONTAINER_EDK2_DIR"
      if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "warning: cached checkout is invalid, refreshing it"
        cd "$CONTAINER_CACHE_ROOT"
        refresh_edk2_checkout
        cd "$CONTAINER_EDK2_DIR"
      fi

      if ! git fetch --depth 1 origin "$EDK2_REF"; then
        echo "warning: git fetch failed, refreshing cached checkout"
        cd "$CONTAINER_CACHE_ROOT"
        refresh_edk2_checkout
        cd "$CONTAINER_EDK2_DIR"
      fi

      if ! git checkout "$EDK2_REF"; then
        echo "warning: git checkout failed, refreshing cached checkout"
        cd "$CONTAINER_CACHE_ROOT"
        refresh_edk2_checkout
        cd "$CONTAINER_EDK2_DIR"
      fi

      git submodule update --init --recursive
      make -C BaseTools/Source/C -j"$(nproc)"

      export WORKSPACE="$CONTAINER_EDK2_DIR"
      export PACKAGES_PATH=/workspace/BC250-DXE-SMU-Core-Unlock:"$CONTAINER_EDK2_DIR"
      export PYTHON_COMMAND="${PYTHON_COMMAND:-python3}"
      export EDK_TOOLS_PATH="$CONTAINER_EDK2_DIR/BaseTools"

      source_edksetup() {
        local edksetup_path="$1"
        local had_nounset=0
        local had_errexit=0

        case $- in
          *e*) had_errexit=1 ;;
          *u*) had_nounset=1 ;;
        esac

        set +eu
        source "$edksetup_path" >/dev/null

        if [[ "$had_errexit" == "1" ]]; then
          set -e
        else
          set +e
        fi

        if [[ "$had_nounset" == "1" ]]; then
          set -u
        else
          set +u
        fi
      }

      source_edksetup "$CONTAINER_EDK2_DIR/edksetup.sh"

      export PATH="$CONTAINER_EDK2_DIR/BaseTools/BinWrappers/PosixLike:$CONTAINER_EDK2_DIR/BaseTools/Bin/Linux-x86_64:$PATH"

      mkdir -p "$CONTAINER_EDK2_DIR/Conf"
      cp -f "$CONTAINER_EDK2_DIR/BaseTools/Conf/build_rule.template" "$CONTAINER_EDK2_DIR/Conf/build_rule.txt"
      cp -f "$CONTAINER_EDK2_DIR/BaseTools/Conf/tools_def.template" "$CONTAINER_EDK2_DIR/Conf/tools_def.txt"
      cp -f "$CONTAINER_EDK2_DIR/BaseTools/Conf/target.template" "$CONTAINER_EDK2_DIR/Conf/target.txt"

      if ! command -v build >/dev/null 2>&1; then
        echo "error: edksetup.sh completed but 'build' is not on PATH" >&2
        echo "PATH=$PATH" >&2
        exit 1
      fi

      echo "Running EDK II build..."

      build \
        -a "$ARCH" \
        -b "$TARGET" \
        -t "$TOOL_CHAIN_TAG" \
        -p /workspace/BC250-DXE-SMU-Core-Unlock/Bc250CoreUnlockPkg/Bc250CoreUnlockPkg.dsc \
        -m /workspace/BC250-DXE-SMU-Core-Unlock/Bc250CoreUnlockPkg/Bc250CoreUnlockDxe/Bc250CoreUnlockDxe.inf \
        -Y PCD

      echo "EDK II build finished, locating EFI artifact..."

      EFI_PATH="$CONTAINER_EDK2_DIR/Build/MeiMeiBc250CoreUnlockPkg/${TARGET}_${TOOL_CHAIN_TAG}/${ARCH}/${MODULE_NAME}.efi"
      if [[ ! -f "$EFI_PATH" ]]; then
        EFI_PATH="$(find "$CONTAINER_EDK2_DIR/Build/MeiMeiBc250CoreUnlockPkg" -type f -name "${MODULE_NAME}.efi" | head -n 1)"
      fi

      if [[ -z "$EFI_PATH" || ! -f "$EFI_PATH" ]]; then
        echo "error: failed to locate built EFI image inside container" >&2
        exit 1
      fi

      mkdir -p /workspace/BC250-DXE-SMU-Core-Unlock/Build/Output
      cp "$EFI_PATH" "/workspace/BC250-DXE-SMU-Core-Unlock/Build/Output/${MODULE_NAME}.efi"

      "$CONTAINER_EDK2_DIR/BaseTools/BinWrappers/PosixLike/GenSec" \
        -s EFI_SECTION_PE32 \
        -o "/workspace/BC250-DXE-SMU-Core-Unlock/Build/Output/${MODULE_NAME}.pe32.sec" \
        "/workspace/BC250-DXE-SMU-Core-Unlock/Build/Output/${MODULE_NAME}.efi"

      "$CONTAINER_EDK2_DIR/BaseTools/BinWrappers/PosixLike/GenSec" \
        -s EFI_SECTION_USER_INTERFACE \
        -n "$MODULE_NAME" \
        -o "/workspace/BC250-DXE-SMU-Core-Unlock/Build/Output/${MODULE_NAME}.ui.sec"

      "$CONTAINER_EDK2_DIR/BaseTools/BinWrappers/PosixLike/GenFfs" \
        -t EFI_FV_FILETYPE_DRIVER \
        -g "$MODULE_GUID" \
        -o "/workspace/BC250-DXE-SMU-Core-Unlock/Build/Output/${MODULE_NAME}.ffs" \
        -i "/workspace/BC250-DXE-SMU-Core-Unlock/Build/Output/${MODULE_NAME}.pe32.sec" \
        -i "/workspace/BC250-DXE-SMU-Core-Unlock/Build/Output/${MODULE_NAME}.ui.sec"

      echo "Build complete:"
      echo "  EFI: /workspace/BC250-DXE-SMU-Core-Unlock/Build/Output/${MODULE_NAME}.efi"
      echo "  FFS: /workspace/BC250-DXE-SMU-Core-Unlock/Build/Output/${MODULE_NAME}.ffs"
    '
}

if [[ "$NO_CONTAINER" == "1" ]]; then
  build_with_host_edk2
else
  build_with_container
fi
