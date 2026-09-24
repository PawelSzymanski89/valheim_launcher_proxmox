#!/bin/bash
# Sign a draft release's files with the project release key and publish it:
#   scripts/sign-and-publish.sh v1.12.0
# The key lives on the maintainer's machine (~/.config/valheim-proxmox/release-signing.key),
# never on GitHub; launchers and panels verify every asset's .sig against its public half.
set -euo pipefail
TAG=${1:?tag}
REPO=PawelSzymanski89/valheim_launcher_proxmox
PY=${VH_SIGN_PY:-$HOME/.config/valheim-proxmox/venv/bin/python}
SIGN=${VH_SIGN_TOOL:-$HOME/HobbyProjects/valheim-proxmox/scripts/sign-release.py}
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cd "$D"
gh release download "$TAG" -R "$REPO" -p '*.zip'
n=$(ls *.zip | wc -l); [ "$n" -eq 6 ] || { echo "expected 6 zips, got $n - is the build finished?"; exit 1; }
"$PY" "$SIGN" *.zip
"$PY" "$SIGN" --verify *.zip
gh release upload "$TAG" -R "$REPO" --clobber *.sig
gh release edit "$TAG" -R "$REPO" --draft=false --latest
echo "published $TAG, signed"
