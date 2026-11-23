#!/bin/sh
# Installs mft and a command for each of its tools.
#
#   From an unpacked release folder:   ./install.sh
#   Straight from GitHub:              curl -fsSL https://github.com/earchibald/macos-file-tools/releases/latest/download/install.sh | sh
#
# Settings (environment variables):
#   MFT_PREFIX    where to install; default ~/.local  (programs go in $MFT_PREFIX/bin)
#   MFT_VERSION   release to download, such as 0.0.1; default: the latest release
set -eu

repo="earchibald/macos-file-tools"
asset="mft-macos-universal.zip"
prefix="${MFT_PREFIX:-$HOME/.local}"
version="${MFT_VERSION:-latest}"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "install.sh: mft runs on macOS only" >&2
  exit 1
fi

# Use the release folder this script sits in, if it is one.
here="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$here" ] && [ -x "$here/bin/mft" ] && [ -d "$here/share/mft" ]; then
  source_dir="$here"
else
  if [ "$version" = "latest" ]; then
    base="https://github.com/$repo/releases/latest/download"
  else
    base="https://github.com/$repo/releases/download/v$version"
  fi
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  echo "Downloading $base/$asset"
  curl -fsSL -o "$work/$asset" "$base/$asset"
  curl -fsSL -o "$work/$asset.sha256" "$base/$asset.sha256"
  (cd "$work" && shasum -a 256 -c "$asset.sha256" >/dev/null) || {
    echo "install.sh: the download does not match its published checksum; nothing was installed" >&2
    exit 1
  }
  ditto -x -k "$work/$asset" "$work/unpacked"
  source_dir="$(echo "$work"/unpacked/mft-*)"
fi

mkdir -p "$prefix/bin" "$prefix/share/mft"
cp "$source_dir/bin/mft" "$prefix/bin/mft"
chmod 755 "$prefix/bin/mft"
cp -R "$source_dir/share/mft/." "$prefix/share/mft/"
"$prefix/bin/mft" link --dir "$prefix/bin" --quiet

echo "Installed mft $("$prefix/bin/mft" --version) in $prefix/bin"
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) echo "Add it to your PATH:  export PATH=\"$prefix/bin:\$PATH\"" ;;
esac
echo "Start with:  mft guide"
