#!/usr/bin/env bash
# shellcheck disable=SC1091
#
# Build the Remote Extension Host for IBM AIX (aix-ppc64) from a prepared VS Code tree.
#
# Mirrors build/linux/package_reh.sh, but runs natively on an AIX 7.3 host (there is no
# cross toolchain or container for AIX), without root, with the Toolbox GNU userland and
# a user-local Node.js matching .nvmrc. See docs/howto-build-aix.md.
#
# Expects: ./vscode prepared by prepare_vscode.sh with OS_NAME=aix (VSCodium patches +
# patches/aix applied, product.json rewritten, NO npm install yet), dev/build.env sourced
# (RELEASE_VERSION, MS_COMMIT, BUILD_SOURCEVERSION), APP_NAME_LC from utils.sh.
# Environment knobs:
#   VSCODE_AIX_LIBUTIL   portlibforaix libutil.so.2 for node-pty   (default ~/local/portlibforaix/lib/libutil.so.2)
#   VSCODE_AIX_RIPGREP   aix-ppc64 rg binary (build/aix/ripgrep.sh)  (required)
#   SHOULD_BUILD_REH     "no" to skip the REH                        (default yes)
#   SHOULD_BUILD_REH_WEB "yes" to also build REH-web                 (default no on AIX)

set -ex

# include common functions
. ./utils.sh

mkdir -p assets

cd vscode || { echo "'vscode' dir not found"; exit 1; }

export VSCODE_PLATFORM='aix'
export VSCODE_ARCH='ppc64'
export NODE_OPTIONS="--max-old-space-size=${MAX_OLD_SPACE_SIZE:-8192}"
export VSCODE_PUBLISH_COUNTER=1
export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export VSCODE_SKIP_NODE_VERSION_CHECK=1
# build/npm/postinstall.ts drops CC/CXX for remote/ unless these are set; gyp would then call "cc"
export VSCODE_REMOTE_CC="${VSCODE_REMOTE_CC:-gcc}"
export VSCODE_REMOTE_CXX="${VSCODE_REMOTE_CXX:-g++}"
export CC="${CC:-gcc}"
export CXX="${CXX:-g++}"

NODE_VERSION=$( grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' remote/.npmrc )
echo "NODE_VERSION=${NODE_VERSION}"

# Toolbox GCC rejects -fstack-protector-strong; addons need -fPIC AND the global-dynamic TLS model
# (without -fPIC GCC keeps local-exec TLS and the loader refuses the module). gyp reads
# ~/.gyp/include.gypi for every node-gyp build (same mechanism as USE_GNUPP2A on arm64).
mkdir -p "${HOME}/.gyp"
if [[ -f "${HOME}/.gyp/include.gypi" ]]; then
  cp "${HOME}/.gyp/include.gypi" "${HOME}/.gyp/include.gypi.pre-vscodium"
fi
{
  cat > "${HOME}/.gyp/include.gypi" <<'GYPI'
{
  "target_defaults": {
    "cflags!": [ "-fstack-protector-strong", "-fstack-protector" ],
    "cflags_cc!": [ "-fstack-protector-strong", "-fstack-protector" ],
    "cflags": [ "-ftls-model=global-dynamic", "-fPIC", "-pthread" ],
    "cflags_cc": [ "-ftls-model=global-dynamic", "-fPIC", "-pthread" ],
    "ldflags": [ "-pthread" ]
  }
}
GYPI
}

if [[ -d "../patches/aix/reh/" ]]; then
  for file in "../patches/aix/reh/"*.patch; do
    if [[ -f "${file}" ]]; then
      apply_patch "${file}"
    fi
  done
fi

for i in {1..5}; do # try 5 times
  npm ci --prefix build && break
  if [[ $i == 5 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

node build/npm/preinstall.ts

# Root: the client-only native modules (native-keymap, policy-watcher, ...) neither build nor
# matter for the server, so install without scripts. The sub-directories are installed below.
for i in {1..5}; do
  npm ci --ignore-scripts && break
  if [[ $i == 5 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

# The addons must be linked against the import file (node.exp) of the exact Node we bundle: on AIX
# node-gyp resolves C++ template symbols that the executable exports through node.exp, and it takes
# node.exp from the *running* node's tree (not from --nodedir). So fetch the full target runtime once
# (the same tarball gulp bundles) and run the remote/ npm + node-gyp steps with THAT node.
NODE_CACHE="${VSCODE_AIX_NODE_CACHE:-${HOME}/.cache/vscodium-aix/node}"
NODE_TGZ="node-v${NODE_VERSION}-aix-ppc64.tar.gz"
NODE_DIR="${NODE_CACHE}/node-v${NODE_VERSION}-aix-ppc64"
if [[ ! -f "${NODE_DIR}/include/node/node.exp" ]]; then
  mkdir -p "${NODE_CACHE}"
  pushd "${NODE_CACHE}"
  [[ -f "${NODE_TGZ}" ]] || curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TGZ}"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" | grep " ${NODE_TGZ}\$" > "${NODE_TGZ}.sha256"
  sha256sum -c "${NODE_TGZ}.sha256"
  tar -xzf "${NODE_TGZ}"
  popd
fi
[[ -f "${NODE_DIR}/include/node/node.exp" ]] || { echo "node.exp missing in ${NODE_DIR}" >&2; exit 1; }

# remote/: install without scripts, apply the AIX fixes, then build the addons against the
# target Node runtime tree, as build/npm/postinstall.ts would (minus the AIX fixes).
pushd remote
npm ci --ignore-scripts
popd
if [[ -z "${VSCODE_AIX_RIPGREP:-}" ]]; then
  # build rg from the tag ripgrep-universal was built from (cached per tag + rustc)
  VSCODE_AIX_RIPGREP="$( ../build/aix/ripgrep.sh . )"
  export VSCODE_AIX_RIPGREP
fi
../build/aix/fix-node-modules.sh remote
pushd remote
export npm_config_nodedir="${NODE_DIR}"
export npm_config_target="${NODE_VERSION}"
export npm_config_disturl='https://nodejs.org/dist'
export npm_config_runtime='node'
export npm_config_build_from_source='true'
# the target runtime's own npm/node-gyp: node-gyp reads node.exp relative to process.execPath
TARGET_NPM="${NODE_DIR}/bin/npm"
# kerberos: do not dlopen libgssapi_krb5 by soname at runtime (the Toolbox ships no .so.2 file);
# link it directly (fix-node-modules.sh puts `krb5-config --libs gssapi` into its gyp block).
# node-pty links portlibforaix's libutil from lib/native-libs (fix-node-modules.sh wrote the -L flag);
# that -L is the only global LDFLAGS: anything else here leaks into every addon's link.
PTY_LDFLAGS="$( cat node_modules/node-pty/.aix-ldflags 2>/dev/null || true )"
export npm_config_kerberos_use_rtld=false
LDFLAGS="${PTY_LDFLAGS}" "${TARGET_NPM}" rebuild --ignore-scripts=false --foreground-scripts
unset npm_config_kerberos_use_rtld
unset npm_config_nodedir npm_config_target npm_config_disturl npm_config_runtime npm_config_build_from_source
popd

# Every other directory from build/npm/dirs.ts (extensions, remote/web, test/*): JS only.
node -e "import('./build/npm/dirs.ts').then(m => console.log(m.dirs.join('\n')))" | while read -r dir; do
  case "${dir}" in ''|build|remote) continue;; esac
  if [[ -f "${dir}/package.json" ]]; then
    ( cd "${dir}" && npm ci )
  fi
done

node build/azure-pipelines/distro/mixin-npm.ts

if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
  echo "Building REH"
  npm run gulp "vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min"

  pushd "../vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}"

  ../build/aix/verify_reh.sh .

  echo "Archiving REH"
  tar czf "../assets/${APP_NAME_LC}-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .

  popd
fi

if [[ "${SHOULD_BUILD_REH_WEB}" == "yes" ]]; then
  echo "Building REH-web"
  npm run gulp "vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min"

  pushd "../vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}"

  echo "Archiving REH-web"
  tar czf "../assets/${APP_NAME_LC}-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .

  popd
fi

cd ..

cd assets

for FILE in *; do
  if [[ -f "${FILE}" ]]; then
    echo "Calculating checksum for ${FILE}"
    sha256sum "${FILE}" > "${FILE}".sha256
    sha1sum "${FILE}" > "${FILE}".sha1
  fi
done

cd ..
