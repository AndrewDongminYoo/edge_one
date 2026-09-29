#!/usr/bin/env bash
set -euo pipefail

script_dir=${BASH_SOURCE[0]%/*}
if [[ $script_dir == "${BASH_SOURCE[0]}" ]]; then
  script_dir=.
fi
cd -- "$script_dir"

if [[ ${OSTYPE:-} != linux* ]]; then
  echo 'setup.sh requires Linux' >&2
  exit 1
fi

install_apt_packages() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "missing $1: apt-get is unavailable" >&2
    exit 1
  fi
  if (( EUID == 0 )); then
    apt-get update
    apt-get install -y "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y "$@"
  else
    echo "missing $1: apt-get requires root or sudo" >&2
    exit 1
  fi
}

if ! command -v python3.12 >/dev/null 2>&1; then
  install_apt_packages python3.12 python3.12-venv
fi
if ! command -v python3.12 >/dev/null 2>&1; then
  echo 'missing python3.12 after installation' >&2
  exit 1
fi
python3.12 -c 'import sys; assert sys.version_info[:2] == (3, 12)'
if ! python3.12 -m ensurepip --version >/dev/null 2>&1; then
  install_apt_packages python3.12-venv
fi
if ! python3.12 -m ensurepip --version >/dev/null 2>&1; then
  echo 'missing ensurepip after python3.12-venv installation' >&2
  exit 1
fi

if ! command -v c++ >/dev/null 2>&1 || {
  ! command -v ninja >/dev/null 2>&1 && ! command -v make >/dev/null 2>&1
}; then
  install_apt_packages build-essential
fi
if ! command -v c++ >/dev/null 2>&1; then
  echo 'missing c++ after installation' >&2
  exit 1
fi
if ! command -v ninja >/dev/null 2>&1 && ! command -v make >/dev/null 2>&1; then
  echo 'missing ninja or make after installation' >&2
  exit 1
fi
c++ --version >/dev/null
if command -v ninja >/dev/null 2>&1; then
  ninja --version >/dev/null
else
  make --version >/dev/null
fi

venv_python=.cache/m0/.venv/bin/python
if [[ ! -x $venv_python ]]; then
  python3.12 -m venv .cache/m0/.venv
fi
if ! command -v "$venv_python" >/dev/null 2>&1; then
  echo "missing $venv_python after venv creation" >&2
  exit 1
fi
"$venv_python" -c 'import sys; assert sys.version_info[:2] == (3, 12)'
"$venv_python" -m pip --version >/dev/null
"$venv_python" -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: -r spikes/m0/requirements.lock
"$venv_python" -m pip check

# Keep this pin equal to the Linux contract job's Flutter version.
flutter_version=3.47.5
flutter_archive=flutter_linux_${flutter_version}-stable.tar.xz
flutter_sha256=2132e990f236f8d22e7c6314b29a191a95b10d7cbcfec9b4e2e303d996652cbb
flutter_home=.cache/flutter/$flutter_version

install_flutter_sdk() {
  if [[ $(uname -m) != x86_64 ]]; then
    echo 'missing flutter: the pinned Linux archive requires x86_64' >&2
    exit 1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    install_apt_packages curl ca-certificates
  fi
  if ! command -v xz >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1 ||
    ! command -v git >/dev/null 2>&1; then
    install_apt_packages xz-utils unzip git
  fi
  local download=.cache/flutter/$flutter_archive.part
  local staging=$flutter_home.partial
  mkdir -p .cache/flutter
  rm -rf -- "$download" "$staging" "$flutter_home"
  if ! curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/$flutter_archive" -o "$download"; then
    rm -f -- "$download"
    echo 'missing flutter: archive download failed' >&2
    exit 1
  fi
  if ! printf '%s  %s\n' "$flutter_sha256" "$download" | sha256sum --check --status; then
    rm -f -- "$download"
    echo 'missing flutter: archive SHA-256 mismatch' >&2
    exit 1
  fi
  mkdir -p -- "$staging"
  tar --no-same-owner -xJf "$download" -C "$staging"
  rm -f -- "$download"
  mv -- "$staging" "$flutter_home"
}

if [[ ${EDGE_ONE_INSTALL_FLUTTER:-0} == 1 ]]; then
  if [[ ! -x $flutter_home/flutter/bin/flutter ]]; then
    install_flutter_sdk
  fi
  flutter_bin=$PWD/$flutter_home/flutter/bin
  for tool in flutter dart; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      if (( EUID == 0 )); then
        ln -sfn -- "$flutter_bin/$tool" "/usr/local/bin/$tool"
      elif command -v sudo >/dev/null 2>&1; then
        sudo ln -sfn -- "$flutter_bin/$tool" "/usr/local/bin/$tool"
      else
        echo "add $flutter_bin to PATH to use $tool" >&2
      fi
    fi
  done
  "$flutter_bin/flutter" --disable-analytics >/dev/null
  "$flutter_bin/flutter" --version
  # Resolve the locked workspace while setup still has network access.
  "$flutter_bin/flutter" pub get --enforce-lockfile
fi

install_trunk_launcher() {
  if ! command -v curl >/dev/null 2>&1; then
    install_apt_packages curl ca-certificates
  fi
  local launcher
  launcher=$(mktemp)
  if ! curl -fsSL https://trunk.io/releases/trunk -o "$launcher" ||
    ! grep -q '^readonly TRUNK_LAUNCHER_VERSION=' "$launcher"; then
    rm -f -- "$launcher"
    echo 'missing trunk: launcher download failed' >&2
    exit 1
  fi
  if (( EUID == 0 )); then
    install -m 0755 "$launcher" /usr/local/bin/trunk
  elif command -v sudo >/dev/null 2>&1; then
    sudo install -m 0755 "$launcher" /usr/local/bin/trunk
  else
    rm -f -- "$launcher"
    echo 'missing trunk: installing to /usr/local/bin requires root or sudo' >&2
    exit 1
  fi
  rm -f -- "$launcher"
}

if ! command -v trunk >/dev/null 2>&1; then
  install_trunk_launcher
fi
if ! command -v trunk >/dev/null 2>&1; then
  echo 'missing trunk after installation' >&2
  exit 1
fi
# Download the pinned CLI, runtimes, and linters while setup still has network access.
trunk install --ci
trunk git-hooks sync

if [[ ${EDGE_ONE_FETCH_MODEL:-0} == 1 ]]; then
  "$venv_python" spikes/m0/setup.py fetch
fi

echo 'M0 Linux environment ready. Fetch the pinned model only when a native task needs it.'
