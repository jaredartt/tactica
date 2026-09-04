#!/usr/bin/env bash
# Build and publish to https://jaredartt.github.io/tactica/
#
# Publishes the built output to the gh-pages branch. That branch is generated,
# never edited by hand -- it gets force-pushed every time.
set -euo pipefail
cd "$(dirname "$0")"

npm run build

WORK="$(mktemp -d)"
cp -R dist/. "$WORK/"
touch "$WORK/.nojekyll"          # stop Pages running the output through Jekyll
cd "$WORK"
git init -q -b gh-pages
git add -A
git commit -q -m "Deploy $(date -u +%Y-%m-%dT%H:%MZ)"
git push -q --force "${TACTICA_REMOTE:-https://github.com/jaredartt/tactica.git}" gh-pages
cd - >/dev/null
rm -rf "$WORK"
echo "Deployed. Live in ~1 min: https://jaredartt.github.io/tactica/"
