#!/bin/bash
# Copies a snapshot of FLX Film Lab's engine into engine/: the Swift sources
# its build.sh lists as ENGINE_SOURCES, the shader, and the stock data (every
# stock's JSON and its base spectral-upsampling table, no filter variants).
#
# The main repository is only read, never written: everything comes out of its
# last commit through `git archive`, so its working tree, index and build
# folder are untouched, and the commit is recorded in engine/SNAPSHOT. Re-run
# this to move FLX Film Convert to a newer engine on purpose; nothing syncs by
# itself. The previous snapshot goes to the Trash.
#
#   ./sync-engine.sh PATH            the FLX Film Lab checkout at PATH, its HEAD
#   REF=v1.3.0 ./sync-engine.sh PATH  a tag or commit of it instead
#   FLX_FILM_LAB=PATH ./sync-engine.sh
set -euo pipefail

MAIN="${1:-${FLX_FILM_LAB:-}}"
[[ -n "$MAIN" ]] || { echo "usage: ./sync-engine.sh PATH-TO-FLX-FILM-LAB (or set FLX_FILM_LAB)" >&2; exit 1; }
REF="${REF:-HEAD}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HERE/engine"

commit=$(git -C "$MAIN" rev-parse "$REF^{commit}")
sources=$(git -C "$MAIN" show "$commit:build.sh" | sed -n '/^ENGINE_SOURCES=(/,/^)/p' | grep -v '[()]' | tr -d ' ')
packs=$(git -C "$MAIN" ls-tree --name-only "$commit" FLXFilmLab/Resources/packs/ \
        | grep -E '/[a-z0-9_]+\.(json|tclut)$|/LICENSE')

staging="$HERE/engine.new"
[[ -e "$staging" ]] && mv "$staging" "$HOME/.Trash/flx-film-convert-engine-staging-$(date +%s)"
mkdir -p "$staging"
# shellcheck disable=SC2086
git -C "$MAIN" archive "$commit" $sources FLXFilmLab/Resources/Shaders/flx.metal $packs | tar -x -C "$staging"
echo "$sources" > "$staging/SOURCES"
echo "$commit" > "$staging/SNAPSHOT"
# The FLX Film Lab release it is, as that commit's build.sh names it.
git -C "$MAIN" show "$commit:build.sh" | sed -n 's/^VERSION="\${VERSION:-\(.*\)}"$/\1/p' | head -1 > "$staging/VERSION"

if [[ -e "$DEST" ]]; then
  mv "$DEST" "$HOME/.Trash/flx-film-convert-engine-$(cat "$DEST/SNAPSHOT" 2>/dev/null | cut -c1-7)-$(date +%s)"
fi
mv "$staging" "$DEST"
echo "engine snapshot of FLX Film Lab ${commit:0:7}: $(wc -l < "$DEST/SOURCES" | tr -d ' ') sources, $(ls "$DEST/FLXFilmLab/Resources/packs" | wc -l | tr -d ' ') pack files, $(du -sh "$DEST" | cut -f1)"
