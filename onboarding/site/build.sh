#!/usr/bin/env bash
# Build the onboarding site into dist/: compile the Gleam project to
# JavaScript, bundle it into one script and copy the static files beside it.
# Every URL in the output is relative, so it works under any Pages subpath.
set -euo pipefail
cd "$(dirname "$0")"

gleam build --target javascript
rm -rf dist
mkdir -p dist
printf 'import { main } from "./build/dev/javascript/onboarding_site/onboarding_site.mjs";\nmain();\n' |
  esbuild --bundle --minify --format=iife --target=es2020 \
    --sourcefile=entry.mjs --log-level=warning \
    --outfile=dist/app.js
cp static/index.html static/style.css dist/
echo "built $(du -sh dist | cut -f1) into dist/"
