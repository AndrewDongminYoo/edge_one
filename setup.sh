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

if [[ ${EDGE_ONE_FETCH_MODEL:-0} == 1 ]]; then
  "$venv_python" spikes/m0/setup.py fetch
fi

echo 'M0 Linux environment ready. Fetch the pinned model only when a native task needs it.'
