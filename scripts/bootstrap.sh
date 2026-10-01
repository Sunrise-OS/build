#!/bin/sh
# Explicit bootstrap dependencies: Python 3.11+, uv, tar/xz/zstd, sh,
# host linker/libc or macOS SDK, and network access.
set -eu
cd "$(dirname "$0")/.."
if [ ! -x .venv/bin/python ]; then uv venv .venv; fi
uv pip install --python .venv/bin/python 'maturin==1.15.0'
.venv/bin/python - <<'PY'
from pathlib import Path
from crosspkg.model import BuildContext
from crosspkg.runner import host_triplet
from packages.rust_toolchain import install
root = Path('.crosspkg').resolve()
context = BuildContext(root, root / 'work/rust', root / 'packages/rust-1.99.0', host_triplet(), host_triplet(), 'native')
context.build.mkdir(parents=True, exist_ok=True)
context.destdir.mkdir(parents=True, exist_ok=True)
install(context)
PY
export PATH="$PWD/.crosspkg/packages/rust-1.99.0/bin:$PWD/.venv/bin:$PATH"
export RUSTC="$PWD/.crosspkg/packages/rust-1.99.0/bin/rustc"
export CARGO_HOME="$PWD/.crosspkg/cargo"
maturin develop --locked
