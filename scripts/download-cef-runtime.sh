#!/bin/sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/.cef-cache"
ARCHIVE="$CACHE/cef_macosarm64.tar.bz2"
CEF_DIR="$CACHE/cef_binary_147.0.10+gd58e84d+chromium-147.0.7727.118_macosarm64"
URL="https://cef-builds.spotifycdn.com/cef_binary_147.0.10%2Bgd58e84d%2Bchromium-147.0.7727.118_macosarm64.tar.bz2"

mkdir -p "$CACHE"
if [ ! -f "$ARCHIVE" ]; then
  curl -L "$URL" -o "$ARCHIVE"
fi
if [ ! -d "$CEF_DIR" ]; then
  tar -xjf "$ARCHIVE" -C "$CACHE"
fi
ln -sfn "$(basename "$CEF_DIR")" "$CACHE/current"
