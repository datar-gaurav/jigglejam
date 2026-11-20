#!/bin/sh
# Turns a game pack folder into a shareable .jigglegame file.
#   scripts/make-pack.sh Packs/StarCatch            -> StarCatch.jigglegame
#   scripts/make-pack.sh Packs/StarCatch out.jigglegame
set -e
DIR="${1:?usage: make-pack.sh <pack folder> [output.jigglegame]}"
[ -f "$DIR/manifest.json" ] || { echo "error: $DIR has no manifest.json" >&2; exit 1; }
OUT="${2:-$(basename "$DIR").jigglegame}"
rm -f "$OUT"
ditto -c -k --norsrc "$DIR" "$OUT"
echo "Made $OUT — double-click it (or use Import game… in Jiggle Jam) to add it."
