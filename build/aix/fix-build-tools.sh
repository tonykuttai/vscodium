#!/usr/bin/env bash
#
# AIX (big-endian) fixes for the *build tooling* under the root node_modules, applied after
# `npm ci --ignore-scripts`. Nothing here changes what is shipped in the REH.
# Usage: build/aix/fix-build-tools.sh [vscode-root]   (default: .)

set -e

ROOT="${1:-.}"

# {{{ @vscode/l10n-dev: initialises web-tree-sitter (Emscripten wasm glue, little-endian only) at
# import time; on a big-endian host the init promise rejects, build/gulpfile.ts treats any
# unhandled rejection as fatal, and build/lib/i18n.ts imports l10n-dev unconditionally.
# The REH build never uses the parser (translation export only), so defer the error to first use.
# Upstream fix: lazy initialisation in @vscode/l10n-dev (and a lazy import in build/lib/i18n.ts).
L10N="${ROOT}/node_modules/@vscode/l10n-dev/dist/main.js"
if [[ -f "${L10N}" ]] && [[ "$( node -p 'require("os").endianness()' )" == "BE" ]]; then
  if ! grep -q 'catch(() => undefined)); // AIX' "${L10N}"; then
    COUNT="$( grep -c '^})());$' "${L10N}" || true )"
    if [[ "${COUNT}" != "4" ]]; then
      echo "fix-build-tools: @vscode/l10n-dev layout changed (${COUNT} static initialisers, expected 4); update this script" >&2
      exit 1
    fi
    sed -i 's|^})());$|})().catch(() => undefined)); // AIX (big-endian): tree-sitter wasm init fails; defer to first use|' "${L10N}"
    echo "fix-build-tools: @vscode/l10n-dev tree-sitter init deferred"
  fi
fi
# }}}

echo "fix-build-tools: done"
