#!/bin/sh
# Runs a pixi task on Linux in Docker, from this checkout, on the host's
# architecture (aarch64 on Apple silicon). The checkout is mounted read-only
# and copied in, so the host's macOS .pixi environments stay untouched; pixi's
# package cache lives in a named volume so reruns are fast.
#
#   tests/linux.sh                 # pixi run -e stable test
#   tests/linux.sh default test    # nightly
#   tests/linux.sh stable test-sandbox
set -eu
env_name="${1:-stable}"
task="${2:-test}"
root="$(cd "$(dirname "$0")/.." && pwd -P)"
exec docker run --rm \
  -v "$root:/src:ro" \
  -v process-mojo-pixi-cache:/root/.cache/rattler \
  -e ENV_NAME="$env_name" -e TASK="$task" \
  ubuntu:24.04 sh -euc '
    apt-get update -qq >/dev/null && apt-get install -y -qq curl ca-certificates git procps gcc libc6-dev >/dev/null
    curl -fsSL https://pixi.sh/install.sh | PIXI_VERSION=v0.78.0 sh >/dev/null 2>&1
    export PATH="$HOME/.pixi/bin:$PATH"
    mkdir /work && cd /src && tar --exclude=./.pixi --exclude=./build -cf - . | tar -C /work -xf -
    cd /work && uname -sr && pixi run -e "$ENV_NAME" "$TASK"
  '
