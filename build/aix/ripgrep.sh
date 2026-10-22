#!/usr/bin/env bash
#
# Build the ripgrep binary that @vscode/ripgrep-universal expects for aix-ppc64, from the same
# upstream tag the package was built from (vscode-ripgrep -> ripgrep-prebuilt -> BurntSushi/ripgrep).
# Prints the path of the cached binary on stdout; everything else goes to stderr.
#
# Usage: build/aix/ripgrep.sh <vscode-root>            (reads remote/node_modules/@vscode/ripgrep-universal/package.json)
#        build/aix/ripgrep.sh --tag <ripgrep-tag>
# Environment:
#   VSCODE_AIX_RUST_HOME   bin dir of the IBM Open SDK for Rust (default: ~/local/RustSDK/1.86/bin, then PATH)
#   VSCODE_AIX_RG_CACHE    cache dir (default ~/.cache/vscodium-aix/ripgrep)
#   VSCODE_AIX_RG_FALLBACK fallback ripgrep tag if the chain cannot be resolved (default 15.0.0)

set -e

log() { echo "ripgrep.sh: $*" >&2; }
fetch() { curl -fsSL --retry 2 "$1" 2>/dev/null || true; }

RUST_HOME="${VSCODE_AIX_RUST_HOME:-${HOME}/local/RustSDK/1.86/bin}"
[[ -d "${RUST_HOME}" ]] && export PATH="${RUST_HOME}:${PATH}"
command -v cargo > /dev/null || { log "cargo not found (set VSCODE_AIX_RUST_HOME)"; exit 1; }
RUSTC_VERSION="$( rustc --version | awk '{print $2}' )"

TAG=""
if [[ "${1:-}" == "--tag" ]]; then
  TAG="${2:?tag}"
else
  ROOT="${1:-.}"
  PKG="${ROOT}/remote/node_modules/@vscode/ripgrep-universal/package.json"
  if [[ -f "${PKG}" ]]; then
    PKGVER="$( jq -r .version "${PKG}" )"
    # vscode-ripgrep pins a ripgrep-prebuilt release; its config.json names the BurntSushi tag
    PREBUILT="$( fetch "https://raw.githubusercontent.com/microsoft/vscode-ripgrep/v${PKGVER}/build/platforms.js" | grep -E "^const VERSION *= *'" | head -1 | cut -d"'" -f2 )"
    if [[ -n "${PREBUILT}" ]]; then
      TAG="$( fetch "https://raw.githubusercontent.com/microsoft/ripgrep-prebuilt/${PREBUILT}/config.json" | jq -r '.ripgrepTag // empty' 2>/dev/null || true )"
      [[ -n "${TAG}" ]] || TAG="$( sed -E 's/^v//; s/-[0-9]+$//' <<< "${PREBUILT}" )"
    fi
    log "ripgrep-universal ${PKGVER} -> prebuilt ${PREBUILT:-?} -> ripgrep ${TAG:-?}"
  fi
fi
if [[ -z "${TAG}" ]]; then
  TAG="${VSCODE_AIX_RG_FALLBACK:-15.0.0}"
  log "could not resolve the ripgrep tag; using fallback ${TAG}"
fi

CACHE="${VSCODE_AIX_RG_CACHE:-${HOME}/.cache/vscodium-aix/ripgrep}/${TAG}-rustc${RUSTC_VERSION}"
if [[ -x "${CACHE}/rg" ]]; then
  log "cached: ${CACHE}/rg ($("${CACHE}/rg" --version | head -1))"
  echo "${CACHE}/rg"
  exit 0
fi

WORK="$( mktemp -d "${TMPDIR:-/tmp}/ripgrep-aix.XXXXXX" )"
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}"
for t in "${TAG}" "v${TAG}"; do
  git clone -q --depth 1 --branch "${t}" https://github.com/BurntSushi/ripgrep.git src 2> /dev/null && break
done
[[ -d src ]] || { log "cannot clone ripgrep tag ${TAG}"; exit 1; }
cd src

# fail fast if the tag needs a newer compiler than the SDK provides
MSRV="$( sed -n 's/^rust-version *= *"\([^"]*\)".*/\1/p' Cargo.toml | head -1 )"
if [[ -n "${MSRV}" ]] && [[ "$( printf '%s\n%s\n' "${MSRV}" "${RUSTC_VERSION}" | sort -V | head -1 )" != "${MSRV}" ]]; then
  log "ripgrep ${TAG} needs rustc >= ${MSRV}, have ${RUSTC_VERSION}"; exit 1
fi

# memmap2: madvise() wants a caddr_t on AIX (upstream: RazrFalcon/memmap2-rs)
MM="$( awk '/^name = "memmap2"$/ {f=1; next} f && /^version = / {print $3; f=0; exit}' Cargo.lock | tr -d '"' )"
if [[ -n "${MM}" ]]; then
  mkdir -p vendor
  if git clone -q --depth 1 --branch "v${MM}" https://github.com/RazrFalcon/memmap2-rs.git vendor/memmap2 2> /dev/null \
     && grep -q 'madvise(self.ptr.offset(offset), len, advice)' vendor/memmap2/src/unix.rs; then
    sed -i 's/madvise(self\.ptr\.offset(offset), len, advice)/madvise(self.ptr.offset(offset) as libc::caddr_t, len, advice)/' vendor/memmap2/src/unix.rs
    printf '\n[patch.crates-io]\nmemmap2 = { path = "vendor/memmap2" }\n' >> Cargo.toml
    log "memmap2 ${MM} patched for AIX"
  else
    log "memmap2 ${MM}: pattern not found or clone failed; building unpatched"
    rm -rf vendor
  fi
fi

export CC=gcc CXX=g++
log "cargo build --release --features pcre2 (ripgrep ${TAG}, rustc ${RUSTC_VERSION})"
cargo build --release --features pcre2 >&2
./target/release/rg --version >&2
strip -X64 target/release/rg 2> /dev/null || true
mkdir -p "${CACHE}"
cp target/release/rg "${CACHE}/rg"
chmod 755 "${CACHE}/rg"
echo "${CACHE}/rg"
