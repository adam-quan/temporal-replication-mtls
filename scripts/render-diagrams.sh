#!/usr/bin/env bash
#
# Renders the architecture diagrams in README.md to PNG files under docs/.
#
#   ./scripts/render-diagrams.sh
#
# The Mermaid source lives in README.md and nowhere else - GitHub renders those
# fenced blocks natively, and keeping a second copy in a .mmd file next to them
# is how the two quietly drift apart. This script extracts each block instead,
# so a regenerated PNG always matches what the README shows.
#
# Each diagram is named by an HTML comment on the line above its fence:
#
#   <!-- diagram: architecture-topology -->
#   ```mermaid
#   ...
#   ```
#
# Needs Node. It runs mermaid-cli through npx, which on a cold cache downloads
# mermaid-cli and a headless Chromium, so the first run is slow.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SOURCE=${SOURCE:-$ROOT_DIR/README.md}
OUT_DIR=${OUT_DIR:-$ROOT_DIR/docs}
WIDTH=${WIDTH:-1700}
SCALE=${SCALE:-2}   # device pixel ratio; -w alone will not upscale a small diagram
MERMAID_CLI=${MERMAID_CLI:-@mermaid-js/mermaid-cli@11}

command -v node >/dev/null || { echo "node is required (https://nodejs.org)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

mkdir -p "$OUT_DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Pull out every named mermaid block. Unnamed blocks are skipped rather than
# guessed at, so adding a diagram without a name is a no-op instead of a
# surprise file.
python3 - "$SOURCE" "$WORK" <<'PYTHON'
import re, sys, pathlib

source, work = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
pattern = re.compile(r"<!--\s*diagram:\s*([A-Za-z0-9._-]+)\s*-->\s*\n```mermaid\n(.*?)```", re.S)

names = []
for name, body in pattern.findall(source.read_text()):
    (work / f"{name}.mmd").write_text(body)
    names.append(name)

if not names:
    sys.exit("no named mermaid blocks found in %s" % source)
print("\n".join(names))
PYTHON

# White background rather than transparent: Mermaid's default theme draws dark
# text, which would vanish against a dark README background.
for mmd in "$WORK"/*.mmd; do
  name=$(basename "$mmd" .mmd)
  echo "Rendering $name..."
  npx -y "$MERMAID_CLI" -i "$mmd" -o "$OUT_DIR/$name.png" -b white -w "$WIDTH" -s "$SCALE" >/dev/null
done

echo
echo "Wrote:"
ls -1 "$OUT_DIR"/*.png
