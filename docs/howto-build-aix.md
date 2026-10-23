# Building the Remote Extension Host for IBM AIX (aix-ppc64)

> Proven on AIX 7.3 TL4 (wyvernden6aix73) with VSCodium 1.140.06880, 2026-10-23: the published
> `vscodium-reh-aix-ppc64-1.140.06880.tar.gz` on [tonykuttai/vscodium-aix-server](https://github.com/tonykuttai/vscodium-aix-server/releases)
> is built this way by the runner described there.

AIX has no cross toolchain, container image or GitHub-hosted runner, so the AIX REH is built
**natively on an AIX host** by the scripts in `build/aix/`, using the same `prepare_vscode.sh`,
patches and gulp tasks as every other platform. `patches/aix/` adds the `aix-ppc64` target to
the VS Code build (`build/gulpfile.reh.ts`) and the AIX launcher scripts; nothing in `src/` is
patched.

## Host prerequisites (no root needed)

| What | Why | How (user-local) |
|---|---|---|
| AIX 7.3 TL4+, Toolbox GNU userland first on `PATH` (`/opt/freeware/bin`) | GNU make/sed/tar/grep/find semantics | `dnf` packages are usually present on dev boxes |
| GCC 13 + `libstdc++` runtime, `gmake`, `patch`, `readlink`, `python3`, `git` | node-gyp builds, scripts | Toolbox |
| `krb5-devel` | `kerberos` addon | Toolbox |
| Node.js matching `.nvmrc` (24.22.0) | runs gulp/esbuild/tsgo | `curl -O https://nodejs.org/dist/v24.22.0/node-v24.22.0-aix-ppc64.tar.gz`, extract under `~/local`, put `bin` first on `PATH` |
| `jq` | `prepare_vscode.sh` | build 1.7.1 from source: `--disable-shared --enable-static --with-oniguruma=builtin`, 64-bit (`OBJECT_MODE=64 CC="gcc -maix64" AR="ar -X64"`), and patch `src/jv_alloc.c` so `malloc(0)` is never called (AIX returns NULL) |
| portlibforaix `libutil.so.2` | node-pty (`openpty/forkpty/login_tty` are not in AIX libc) | `git clone https://github.com/tonykuttai/portlibforaix && make` → `~/local/portlibforaix/lib/libutil.so.2` |
| an aix-ppc64 `rg` built from the ripgrep tag that `@vscode/ripgrep-universal` ships | `@vscode/ripgrep-universal` has no AIX binary | `build/aix/ripgrep.sh` builds it (IBM Open SDK for Rust relocated under `~/local/RustSDK/1.86`, `--features pcre2`, cached per tag and rustc; `package_reh.sh` calls it when `VSCODE_AIX_RIPGREP` is unset) |

Never export the runtime `LIBPATH` (what `bin/aix-env.sh` sets) in the shell that compiles:
the Toolbox compiler binaries are 32-bit and will refuse to start with 64-bit runtime
directories first on `LIBPATH`.

## Build

```bash
export APP_NAME=VSCodium ASSETS_REPOSITORY=<owner>/vscodium BINARY_NAME=codium GH_REPO_PATH=<owner>/vscodium ORG_NAME=VSCodium
export OS_NAME=aix VSCODE_QUALITY=stable CI_BUILD=no MAX_OLD_SPACE_SIZE=8192
export RELEASE_VERSION=1.140.06880          # a VSCodium release; MS_COMMIT comes from upstream/stable.json
export VSCODE_AIX_LIBUTIL=$HOME/local/portlibforaix/lib/libutil.so.2
export VSCODE_AIX_RIPGREP=$HOME/local/aix-artifacts/ripgrep-15.0.0/rg

. get_repo.sh                               # shallow checkout of microsoft/vscode at MS_COMMIT into ./vscode
. version.sh
SKIP_NPM_INSTALL=yes . prepare_vscode.sh    # VSCodium patches + patches/aix, product.json; no npm here
./build/aix/package_reh.sh                  # deps, AIX fixes, gulp vscode-reh-aix-ppc64-min, verify, assets/
```

`build/aix/package_reh.sh` does, in order:

1. `npm ci --prefix build`, root `npm ci --ignore-scripts` (client-only natives are not needed).
2. `build/aix/fix-build-tools.sh`: defers `@vscode/l10n-dev`'s tree-sitter wasm initialisation
   (Emscripten glue is little-endian only; the REH build never uses that parser).
3. `remote/`: `npm ci --ignore-scripts`, `build/aix/fix-node-modules.sh` (node-pty AIX patch +
   libutil, @parcel/watcher aix gyp block + `d_type` + polling patch, kerberos `_AIX` + krb5-config libs, deviceid, `rg` into
   `bin/aix-ppc64/`), then `npm rebuild` against the target Node from `remote/.npmrc` with
   `~/.gyp/include.gypi` (`-fPIC -ftls-model=global-dynamic`, no `-fstack-protector-strong`).
4. `npm ci` in every other directory of `build/npm/dirs.ts`.
5. `npm run gulp vscode-reh-aix-ppc64-min` (downloads the official nodejs.org `aix-ppc64` runtime; set
   `GITHUB_TOKEN`, the built-in extensions come from GitHub releases and the anonymous API limit is 60/h).
6. `build/aix/verify_reh.sh`: every addon is 64-bit XCOFF and loads, `rg` runs, the server reaches
   "Extension host agent listening".
7. `assets/vscodium-reh-aix-ppc64-<RELEASE_VERSION>.tar.gz` + `.sha256`/`.sha1`.

## What the package contains that Linux does not

- `bin/aix-env.sh`: puts the GCC runtime, `/opt/freeware/lib64` and node-pty's `lib/native-libs`
  on `LIBPATH`; sourced by `bin/codium-server`, `bin/remote-cli/codium`, `bin/helpers/browser.sh`.
- `aix-platform-override.cjs`: preloaded with `node -r` by the launchers and propagated to every child
  process (extension host, pty host, file watcher) through `NODE_OPTIONS=--require` in `bin/aix-env.sh`.
  It reports `process.platform === 'linux'` to the few server code paths that only know
  linux/darwin/win32 (real platform to everything else, ripgrep-universal in particular) and replaces
  `fs.watch`/`fs.promises.watch` with stat polling: libuv implements AIX `fs.watch` with AHAFS, whose
  shared monitor pool can wedge the whole host. It is inert in processes that are not VS Code's.
- `@parcel/watcher` built with `build/aix/parcel-watcher-polling.patch` (`BRUTE_FORCE_POLLING`): the
  upstream brute-force backend cannot `subscribe()` (it aborts the File Watcher process), the patch adds
  polling subscriptions (`PARCEL_WATCHER_POLL_INTERVAL_MS`, default 2000 ms).
- `node_modules/node-pty/lib/native-libs/libutil.{a,so.2}` from portlibforaix.

## Runtime requirements on the target AIX host

Toolbox `libstdc++` (GCC 12 or newer) and `krb5-libs`; nothing else. Node is bundled.
