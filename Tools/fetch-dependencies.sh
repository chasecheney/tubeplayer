#!/bin/bash
# Downloads the embedded Python runtime and installs yt-dlp into the project.
# Run once after cloning, and again whenever you want a newer yt-dlp baked in:
#   ./Tools/fetch-dependencies.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"
PACKAGES="$ROOT/python/app_packages"

PY_TAG="3.14-b10"
PY_ASSET="Python-3.14-iOS-support.b10.tar.gz"
PY_SHA256="200ef60eb67be0483ceb638daa9048f84f41a9a952707a5ad4c3198037c7b583"
PY_URL="https://github.com/beeware/Python-Apple-support/releases/download/$PY_TAG/$PY_ASSET"

mkdir -p "$VENDOR"

if [ ! -d "$VENDOR/Python.xcframework" ] || [ "$(cat "$VENDOR/.python-version" 2>/dev/null)" != "$PY_TAG" ]; then
    echo "==> Downloading Python $PY_TAG for iOS"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    curl -fL --progress-bar -o "$TMP/python.tar.gz" "$PY_URL"
    echo "$PY_SHA256  $TMP/python.tar.gz" | shasum -a 256 -c -
    tar -xzf "$TMP/python.tar.gz" -C "$TMP"
    rm -rf "$VENDOR/Python.xcframework"
    mv "$TMP/Python.xcframework" "$VENDOR/Python.xcframework"
    echo "$PY_TAG" > "$VENDOR/.python-version"
else
    echo "==> Python $PY_TAG already present"
fi

echo "==> Installing yt-dlp into python/app_packages"
PIP=(python3 -m pip)
if ! python3 -m pip --version >/dev/null 2>&1; then
    echo "error: python3 with pip is required (install Xcode command line tools or Homebrew python)" >&2
    exit 1
fi
rm -rf "$PACKAGES"
mkdir -p "$PACKAGES"
# Pure-Python wheels only; target the embedded interpreter's version.
"${PIP[@]}" install --quiet --disable-pip-version-check \
    --target "$PACKAGES" --no-deps \
    --only-binary=:all: --platform any --python-version 3.14 --implementation py \
    yt-dlp yt-dlp-ejs certifi
# Executables and caches aren't needed inside the app.
rm -rf "$PACKAGES/bin" "$PACKAGES/share"
find "$PACKAGES" -name "__pycache__" -type d -prune -exec rm -rf {} +

VERSION=$(grep -m1 "__version__" "$PACKAGES/yt_dlp/version.py" | cut -d"'" -f2)
echo "==> Done. yt-dlp $VERSION is ready; open TubePlayer.xcodeproj and build."
