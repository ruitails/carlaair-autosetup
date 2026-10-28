#!/usr/bin/env bash
# =============================================================================
#  CarlaAir autosetup — Ubuntu 20.04 / 22.04 (Linux only)
#
#  Run from the repository:
#    bash autosetup.sh
#    bash autosetup.sh --with-binary     # download HF Linux shipping zip (~6.4 GB)
#    bash autosetup.sh --skip-binary     # system + conda/Python only
#    bash autosetup.sh --prefix /path/to/CarlaAir-v0.1.7
#
#  Installs: apt deps, Miniconda (if needed), conda env carlaAir, CarlaAir
#  carla module, AirSim settings, LD_LIBRARY_PATH activate hook for boost,
#  and optionally the Ubuntu binary release.
#
#  Not supported: Windows, macOS, UE4 source builds.
# =============================================================================
set -euo pipefail

# Do not name this VERSION — sourcing /etc/os-release overwrites VERSION.
RELEASE_TAG="v0.1.7"
RELEASE_DIR="CarlaAir-${RELEASE_TAG}"
RELEASE_ZIP="${RELEASE_DIR}.zip"
HF_URL="${CARLAIR_HF_URL:-https://huggingface.co/tianlezeng/CarlaAIr-v0.1.7/resolve/main/CarlaAir-v0.1.7.zip}"
ENV_NAME="carlaAir"
PYTHON_VER="3.10"

WITH_BINARY="auto"
PREFIX="${CARLAIR_PREFIX:-}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[!!]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-binary) WITH_BINARY=yes; shift ;;
    --skip-binary) WITH_BINARY=no; shift ;;
    --prefix) PREFIX="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) fail "Unknown argument: $1 (try --help)" ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_SETUP="${REPO_ROOT}/env_setup"
TARBALL="${ENV_SETUP}/carla_python_module.tar.gz"

# Checkouts edited on Windows often leave CRLF; Linux then sees /bin/bash^M.
strip_crlf() {
  local f
  for f in "$@"; do
    [[ -f "$f" ]] || continue
    sed -i 's/\r$//' "$f" 2>/dev/null || true
  done
}
strip_crlf \
  "${REPO_ROOT}/autosetup.sh" \
  "${REPO_ROOT}/CarlaAir.sh" \
  "${REPO_ROOT}/carlaAir.sh" \
  "${ENV_SETUP}/setup_env.sh" \
  "${ENV_SETUP}/test_env.sh" \
  "${REPO_ROOT}/CarlaAir_Release/install/"*.sh \
  "${REPO_ROOT}/examples/ros2/"*.sh

echo ""
echo "=========================================="
echo "  CarlaAir autosetup (${RELEASE_TAG})"
echo "=========================================="
echo "  Repo: ${REPO_ROOT}"
echo ""

if [[ "$(uname -s)" != "Linux" ]]; then
  fail "Linux only (uname=$(uname -s)). Run on Ubuntu 22.04."
fi

if [[ -f /etc/os-release ]]; then
  # Read only what we need; a full `. /etc/os-release` sets VERSION= and
  # would clobber a variable named VERSION (seen as extract path
  # "CarlaAir-22.04.5 LTS (Jammy Jellyfish)").
  OS_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
  OS_VERSION_ID="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
  OS_PRETTY="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"
  ok "OS: ${OS_PRETTY}"
  case "${OS_ID}:${OS_VERSION_ID}" in
    ubuntu:20.04|ubuntu:22.04) ;;
    ubuntu:*) warn "Untested Ubuntu ${OS_VERSION_ID}; official support is 20.04/22.04" ;;
    *) warn "Non-Ubuntu ID=${OS_ID}; apt steps may fail" ;;
  esac
fi

if [[ "$(id -u)" -eq 0 ]]; then
  warn "Root is fine for install; do not launch CarlaAir as root (UE4 refuses it)."
fi

if [[ "$(id -u)" -eq 0 ]]; then
  APT=(apt-get)
elif command -v sudo >/dev/null 2>&1; then
  APT=(sudo apt-get)
else
  fail "Need root or sudo for apt packages"
fi

export DEBIAN_FRONTEND=noninteractive
ok "Installing system packages..."
"${APT[@]}" update -y -qq
"${APT[@]}" install -y -qq \
  ca-certificates curl wget unzip tar gzip \
  build-essential git \
  libvulkan1 vulkan-tools mesa-vulkan-drivers \
  libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 libxi6 libxrandr2 \
  libxinerama1 libxss1 libxxf86vm1 libxkbcommon0 \
  libwayland-client0 libwayland-cursor0 libwayland-egl1 \
  libfontconfig1 libdbus-1-3 libnss3 libasound2 \
  libjpeg-turbo8 libpng16-16 \
  xdg-user-dirs iproute2 procps \
  python3 python3-pip python3-venv
ok "System packages installed"

ensure_conda() {
  if command -v conda >/dev/null 2>&1; then
    ok "conda on PATH: $(command -v conda)"
    return 0
  fi
  for base in "${HOME}/miniconda3" "${HOME}/anaconda3"; do
    if [[ -x "${base}/bin/conda" ]]; then
      # shellcheck source=/dev/null
      source "${base}/etc/profile.d/conda.sh"
      ok "Using ${base}"
      return 0
    fi
  done
  ok "Installing Miniconda into ${HOME}/miniconda3..."
  local installer="/tmp/Miniconda3-CarlaAir.sh"
  curl -fsSL -o "$installer" \
    "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
  bash "$installer" -b -p "${HOME}/miniconda3"
  # shellcheck source=/dev/null
  source "${HOME}/miniconda3/etc/profile.d/conda.sh"
  conda init bash >/dev/null 2>&1 || true
  ok "Miniconda installed"
}

ensure_conda
if ! command -v conda >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "${HOME}/miniconda3/etc/profile.d/conda.sh"
fi
conda --version >/dev/null || fail "conda not usable"

if conda tos accept --help >/dev/null 2>&1; then
  conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main || true
  conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r || true
  ok "Anaconda channel ToS accepted (if required)"
fi

has_shipping_tree() {
  local root="$1"
  [[ -x "${root}/CarlaAir.sh" || -x "${root}/carlaAir.sh" ]] \
    && [[ -f "${root}/Engine/Binaries/ThirdParty/PhysX3/Linux/x86_64-unknown-linux-gnu/libApexFramework.so" ]] \
    && [[ -f "${root}/CarlaUE4/Plugins/Carla/Carla.uplugin" ]]
}

ensure_binary() {
  if [[ -n "$PREFIX" ]] && has_shipping_tree "$PREFIX"; then
    ok "Using existing binary tree: $PREFIX"
    return 0
  fi
  if has_shipping_tree "$REPO_ROOT"; then
    PREFIX="$REPO_ROOT"
    ok "Repository already contains shipping binary"
    return 0
  fi
  if [[ "$WITH_BINARY" == "no" ]]; then
    warn "Skipping binary download (--skip-binary)."
    return 0
  fi
  if [[ "$WITH_BINARY" == "auto" ]]; then
    warn "No shipping binary in repo; downloading Ubuntu release (~6.4 GB)..."
  fi

  local dest_parent="${HOME}/CarlaAir"
  local zip="${dest_parent}/${RELEASE_ZIP}"
  mkdir -p "$dest_parent"
  # Recover a zip saved under a bad name from older autosetup (VERSION clobber).
  if [[ ! -f "$zip" ]]; then
    local orphan
    orphan="$(find "$dest_parent" -maxdepth 1 -type f -name 'CarlaAir-*.zip' -printf '%s %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2- || true)"
    if [[ -n "$orphan" && -f "$orphan" ]]; then
      warn "Renaming existing download to ${RELEASE_ZIP}"
      mv -f "$orphan" "$zip"
    fi
  fi
  if [[ ! -f "$zip" ]]; then
    ok "Downloading: $HF_URL"
    curl -fL --http1.1 --retry 5 --retry-delay 5 -C - -o "$zip" "$HF_URL"
  else
    ok "Using existing zip: $zip"
  fi
  ok "Extracting full tree..."
  unzip -q -o "$zip" -d "$dest_parent"
  if [[ -d "${dest_parent}/${RELEASE_DIR}" ]]; then
    PREFIX="${dest_parent}/${RELEASE_DIR}"
  else
    # Prefer any extracted tree that already looks like a shipping build.
    local found=""
    local d
    for d in "${dest_parent}"/CarlaAir-* "${dest_parent}"/LinuxNoEditor; do
      if [[ -d "$d" ]] && has_shipping_tree "$d"; then
        found="$d"
        break
      fi
    done
    [[ -n "$found" ]] || fail "Extract finished but ${dest_parent}/${RELEASE_DIR} not found"
    PREFIX="$found"
    warn "Using extracted tree at $PREFIX"
  fi
  has_shipping_tree "$PREFIX" || fail "Incomplete extract under $PREFIX"

  if [[ ! -f "${PREFIX}/env_setup/carla_python_module.tar.gz" && -f "$TARBALL" ]]; then
    mkdir -p "${PREFIX}/env_setup"
    cp -a "${ENV_SETUP}/." "${PREFIX}/env_setup/"
  fi
  if [[ ! -d "${PREFIX}/examples" && -d "${REPO_ROOT}/examples" ]]; then
    cp -a "${REPO_ROOT}/examples" "${PREFIX}/examples"
  fi
  strip_crlf "${PREFIX}/CarlaAir.sh" "${PREFIX}/carlaAir.sh" "${PREFIX}/env_setup/"*.sh
  chmod +x "${PREFIX}/CarlaAir.sh" "${PREFIX}/carlaAir.sh" 2>/dev/null || true
  ok "Binary ready: $PREFIX"
}

ensure_binary

mkdir -p "${HOME}/Documents/AirSim"
SETTINGS_SRC=""
for cand in \
  "${PREFIX:-}/AirSimConfig/settings.json" \
  "${REPO_ROOT}/CarlaAir_Release/install/settings.json" \
  "${REPO_ROOT}/AirSimConfig/settings.json"
do
  [[ -n "$cand" && -f "$cand" ]] && SETTINGS_SRC="$cand" && break
done
if [[ -n "$SETTINGS_SRC" ]]; then
  cp "$SETTINGS_SRC" "${HOME}/Documents/AirSim/settings.json"
  ok "AirSim settings installed"
else
  cat > "${HOME}/Documents/AirSim/settings.json" << 'JSON'
{
  "SettingsVersion": 1.2,
  "SimMode": "Multirotor",
  "Vehicles": {
    "SimpleFlight": {
      "VehicleType": "SimpleFlight",
      "AutoCreate": true
    }
  }
}
JSON
  ok "AirSim settings written (default Multirotor)"
fi

[[ -f "$TARBALL" ]] || fail "Missing $TARBALL"

# shellcheck source=/dev/null
source "$(conda info --base)/etc/profile.d/conda.sh"

if ! conda env list | grep -qw "$ENV_NAME"; then
  ok "Creating conda env $ENV_NAME (python $PYTHON_VER)..."
  conda create -n "$ENV_NAME" python="$PYTHON_VER" -y -q
else
  warn "conda env $ENV_NAME already exists; updating packages"
fi
conda activate "$ENV_NAME"

ok "Installing pip dependencies..."
pip install -q numpy Pillow pygame msgpack-rpc-python python-dateutil
pip install -q --no-build-isolation airsim

pip uninstall carla -y -q 2>/dev/null || true
SITE_PKG="$(python -c 'import site; print(site.getsitepackages()[0])')"
rm -rf "${SITE_PKG}/carla" "${SITE_PKG}/carla.libs"
tar xzf "$TARBALL" -C "$SITE_PKG"
[[ -d "${SITE_PKG}/carla.libs" ]] || fail "Missing ${SITE_PKG}/carla.libs after extract"
[[ -f "${SITE_PKG}/carla/libcarla.cpython-310-x86_64-linux-gnu.so" ]] \
  || fail "Missing libcarla extension after extract"
# HF binary env_setup ships libboost_python310; git tarball uses auditwheel-hashed libs.
BOOST_SO="${SITE_PKG}/carla.libs/libboost_python310.so.1.84.0"
if [[ -f "$BOOST_SO" ]]; then
  chmod +x "$BOOST_SO" 2>/dev/null || true
  ok "Found bundled libboost_python310"
else
  warn "No libboost_python310 in carla.libs (OK for git/auditwheel module tarball)"
fi
chmod +x "${SITE_PKG}/carla.libs/"*.so* 2>/dev/null || true
ok "Deployed CarlaAir carla module into $SITE_PKG ($(ls "${SITE_PKG}/carla.libs" | wc -l) libs)"

ACTIVATE_DIR="${CONDA_PREFIX}/etc/conda/activate.d"
DEACTIVATE_DIR="${CONDA_PREFIX}/etc/conda/deactivate.d"
mkdir -p "$ACTIVATE_DIR" "$DEACTIVATE_DIR"
cat > "${ACTIVATE_DIR}/carlaair_libs.sh" << EOF
_carla_libs="${SITE_PKG}/carla.libs"
case ":\${LD_LIBRARY_PATH:-}:" in
  *":\${_carla_libs}:"*) ;;
  *) export LD_LIBRARY_PATH="\${_carla_libs}\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}" ;;
esac
unset _carla_libs
EOF
cat > "${DEACTIVATE_DIR}/carlaair_libs.sh" << EOF
_carla_libs="${SITE_PKG}/carla.libs"
if [[ -n "\${LD_LIBRARY_PATH:-}" ]]; then
  LD_LIBRARY_PATH="\$(printf '%s' "\$LD_LIBRARY_PATH" | tr ':' '\n' | grep -vx "\${_carla_libs}" | paste -sd: - || true)"
  export LD_LIBRARY_PATH
fi
unset _carla_libs
EOF
ok "Installed conda activate hook for carla.libs"

export LD_LIBRARY_PATH="${SITE_PKG}/carla.libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
conda deactivate
conda activate "$ENV_NAME"

python -c 'import carla, airsim, pygame, numpy, PIL; print("imports OK")'

if [[ -f "${ENV_SETUP}/test_env.sh" ]]; then
  # Git checkouts on Windows can leave CRLF; strip before running on Linux.
  sed -i 's/\r$//' "${ENV_SETUP}/test_env.sh" "${ENV_SETUP}/setup_env.sh" 2>/dev/null || true
  set +e
  bash "${ENV_SETUP}/test_env.sh"
  TEST_RC=$?
  set -e
  if [[ $TEST_RC -ne 0 ]]; then
    warn "test_env.sh exited ${TEST_RC} (ports down before launch is OK)"
  else
    ok "test_env.sh passed"
  fi
fi

LAUNCH=""
if [[ -n "${PREFIX:-}" ]] && has_shipping_tree "$PREFIX"; then
  LAUNCH="${PREFIX}/CarlaAir.sh"
  [[ -x "$LAUNCH" ]] || LAUNCH="${PREFIX}/carlaAir.sh"
elif has_shipping_tree "$REPO_ROOT"; then
  PREFIX="$REPO_ROOT"
  LAUNCH="${PREFIX}/CarlaAir.sh"
  [[ -x "$LAUNCH" ]] || LAUNCH="${PREFIX}/carlaAir.sh"
fi

echo ""
echo "=========================================="
echo -e "  ${GREEN}Autosetup complete${NC}"
echo "=========================================="
echo ""
echo "  conda activate ${ENV_NAME}"
if [[ -n "$LAUNCH" ]]; then
  echo "  ${LAUNCH} Town10HD"
  echo "  # low VRAM: ${LAUNCH} Town01 --quality Low"
  echo "  python3 ${PREFIX}/examples/quick_start_showcase.py"
else
  echo "  No shipping binary yet. Install it with:"
  echo "    bash autosetup.sh --with-binary"
fi
echo ""
echo "  CARLA API   localhost:2000"
echo "  AirSim API  localhost:41451"
echo ""
