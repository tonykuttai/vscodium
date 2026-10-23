#!/usr/bin/env bash
# shellcheck disable=SC2015
#
# AIX: make the native dependencies under remote/node_modules build and load on aix-ppc64.
# Runs after `npm ci --ignore-scripts` in remote/ and before the addons are rebuilt.
# Everything here is a workaround for a package that has no AIX support upstream yet; each
# block names the upstream fix that would make it unnecessary.
#
# Inputs (environment):
#   VSCODE_AIX_LIBUTIL   path to portlibforaix's libutil.so.2 (openpty/forkpty/login_tty for node-pty)
#   VSCODE_AIX_RIPGREP   path to an aix-ppc64 `rg` binary built from the ripgrep tag that
#                        @vscode/ripgrep-universal ships (see build/aix/ripgrep.sh)
# Usage: build/aix/fix-node-modules.sh <remote-dir>   (default: remote)

set -e

REMOTE_DIR="${1:-remote}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
NM="${REMOTE_DIR}/node_modules"

[[ -d "${NM}" ]] || { echo "fix-node-modules: ${NM} not found (run npm ci --ignore-scripts first)" >&2; exit 1; }

# {{{ node-pty: AIX libc has no openpty/forkpty/login_tty; use portlibforaix's libutil.so.2.
# Upstream fix: implement them for _AIX in src/unix/pty.cc with posix_openpt/grantpt/unlockpt.
if [[ -d "${NM}/node-pty" ]]; then
  pushd "${NM}/node-pty" > /dev/null

  if ! grep -q 'defined(_AIX)' src/unix/pty.cc; then
    echo "node-pty: applying node-pty-aix.patch"
    patch -p1 --forward --batch < "${SCRIPT_DIR}/node-pty-aix.patch"
  fi
  grep -q 'defined(_AIX)' src/unix/pty.cc || { echo "node-pty: AIX patch did not apply" >&2; exit 1; }

  # >= 1.2.0-beta: pty_close_inherited_fds() is only defined under __linux__ but called on
  # every non-Apple platform; its fcntl(FD_CLOEXEC) fallback works on AIX. Widen ONLY that guard:
  # the other __linux__ blocks pull in <sys/syscall.h>/close_range, which AIX lacks.
  if grep -q 'pty_close_inherited_fds' src/unix/pty.cc; then
    python3 - src/unix/pty.cc <<'PYNODEPTY'
import sys
path = sys.argv[1]
src = open(path).read()
old = "#if defined(__linux__)\n\nstatic int\nSetCloseOnExec(int fd) {"
new = "#if defined(__linux__) || defined(_AIX)\n\nstatic int\nSetCloseOnExec(int fd) {"
if new in src:
    print("node-pty: pty_close_inherited_fds already enabled for AIX")
elif old in src:
    open(path, "w").write(src.replace(old, new, 1))
    print("node-pty: enabled pty_close_inherited_fds for AIX")
else:
    sys.exit("node-pty: pty.cc SetCloseOnExec layout changed; update build/aix/fix-node-modules.sh")
PYNODEPTY
  fi

  LIBUTIL="${VSCODE_AIX_LIBUTIL:-${HOME}/local/portlibforaix/lib/libutil.so.2}"
  [[ -f "${LIBUTIL}" ]] || { echo "node-pty: libutil.so.2 not found at ${LIBUTIL} (set VSCODE_AIX_LIBUTIL)" >&2; exit 1; }
  mkdir -p lib/native-libs
  cp -f "${LIBUTIL}" lib/native-libs/libutil.so.2
  chmod 755 lib/native-libs/libutil.so.2
  # binding.gyp links -lutil on every non-Windows OS. portlibforaix's libutil.so.2 is already an
  # AIX archive with a shared member, so expose the same file as libutil.a for the linker; the
  # runtime dependency resolves through LIBPATH, which bin/aix-env.sh points at lib/native-libs.
  ( cd lib/native-libs && rm -f libutil.a && cp -f libutil.so.2 libutil.a )
  # node-gyp honours LDFLAGS (read back by package_reh.sh when rebuilding node-pty)
  echo "-L${PWD}/lib/native-libs" > .aix-ldflags

  rm -rf prebuilds
  popd > /dev/null
fi
# }}}

# {{{ @parcel/watcher: binding.gyp has no AIX branch; dirent has no d_type; and the brute-force
# backend cannot subscribe() (it throws a bare C string, which escapes Backend.cc's std::exception
# handlers and aborts the File Watcher process; VS Code then falls back to fs.watch = AHAFS on AIX).
# parcel-watcher-polling.patch adds polling subscriptions behind BRUTE_FORCE_POLLING.
# No Watchman backend: resolving the "default" backend first asks WatchmanBackend::checkAvailable(),
# which popen()s "watchman get-sockname"; without watchman the probe throws before pclose() and
# leaves a zombie sh in every File Watcher process (VS Code asks for "inotify" because the shim
# reports linux, parcel then falls back to "default"). Brute force is the only backend we want.
# Upstream fix: an OS=="aix" block, the stat() fallback in legacy.cc, and the polling backend.
if [[ -d "${NM}/@parcel/watcher" ]]; then
  pushd "${NM}/@parcel/watcher" > /dev/null

  if ! grep -q 'BRUTE_FORCE_POLLING' src/shared/BruteForceBackend.cc; then
    echo "@parcel/watcher: applying parcel-watcher-polling.patch"
    patch -p1 --forward --batch < "${SCRIPT_DIR}/parcel-watcher-polling.patch"
    grep -q 'BRUTE_FORCE_POLLING' src/shared/BruteForceBackend.cc || { echo "@parcel/watcher: polling patch did not apply" >&2; exit 1; }
  fi

  python3 - binding.gyp <<'PY'
import ast, re, sys
path = sys.argv[1]
text = open(path).read()
if 'OS=="aix"' not in text:
    aix_block = """
        ['OS=="aix"', {
          "sources": [
            "src/shared/BruteForceBackend.cc",
            "src/unix/legacy.cc"
          ],
          "defines": [ "BRUTE_FORCE", "BRUTE_FORCE_POLLING" ],
          'cflags!': [ '-fstack-protector-strong' ],
          'cflags_cc!': [ '-fstack-protector-strong' ],
          'cflags_cc': [ '-std=c++17' ]
        }],"""
    m = re.search(r"""(['"]conditions['"]\s*:\s*\[)""", text)
    if not m:
        sys.exit("@parcel/watcher binding.gyp: no 'conditions' list found")
    text = text[:m.end()] + aix_block + text[m.end():]
    open(path, "w").write(text)
    print("@parcel/watcher: AIX block added to binding.gyp")
data = ast.literal_eval(open(path).read())
assert any('OS=="aix"' in str(t.get("conditions", "")) for t in data.get("targets", [])), "AIX block missing"
PY

  # trees patched by an earlier revision of this script: drop Watchman from the aix block and make
  # sure the polling define is there
  if grep -q 'OS=="aix"' binding.gyp && grep -q '"WATCHMAN", "BRUTE_FORCE"' binding.gyp; then
    python3 - binding.gyp <<'PY2'
import re, sys
path = sys.argv[1]; text = open(path).read()
start = text.index('OS=="aix"'); end = text.index('}]', start)
block = text[start:end]
block = re.sub(r'\s*"src/watchman/(BSER|WatchmanBackend)\.cc",', '', block)
block = block.replace('"defines": [ "WATCHMAN", "BRUTE_FORCE", "BRUTE_FORCE_POLLING" ]', '"defines": [ "BRUTE_FORCE", "BRUTE_FORCE_POLLING" ]')
block = block.replace('"defines": [ "WATCHMAN", "BRUTE_FORCE" ]', '"defines": [ "BRUTE_FORCE", "BRUTE_FORCE_POLLING" ]')
open(path, "w").write(text[:start] + block + text[end:])
print("@parcel/watcher: Watchman removed from the existing aix block")
PY2
    grep -q '"WATCHMAN"' binding.gyp && { echo "@parcel/watcher: WATCHMAN still in binding.gyp" >&2; exit 1; }
  fi

  if grep -q 'bool isDir = ent->d_type == DT_DIR;' src/unix/legacy.cc; then
    echo "@parcel/watcher: legacy.cc d_type -> S_ISDIR"
    sed -i 's/bool isDir = ent->d_type == DT_DIR;/bool isDir = S_ISDIR(attrib.st_mode); \/\/ AIX: dirent has no d_type/' src/unix/legacy.cc
    grep -q 'struct stat attrib;' src/unix/legacy.cc || { echo "@parcel/watcher: legacy.cc layout changed" >&2; exit 1; }
  fi

  rm -rf prebuilds
  popd > /dev/null
fi
# }}}

# {{{ kerberos: src/kerberos_common.h selects the win32 SSPI backend unless __linux__/__APPLE__,
# and binding.gyp only lists the GSSAPI sources/libs for mac/linux. AIX has MIT krb5 (Toolbox krb5-devel).
# Upstream fix (mongodb-js/kerberos): add _AIX / OS=="aix" to those conditions.
if [[ -d "${NM}/kerberos" ]]; then
  pushd "${NM}/kerberos" > /dev/null
  if ! grep -q '_AIX' src/kerberos_common.h; then
    sed -i 's/#if defined(__linux__) || defined(__APPLE__)/#if defined(__linux__) || defined(__APPLE__) || defined(_AIX)/' src/kerberos_common.h
    grep -q '_AIX' src/kerberos_common.h || { echo "kerberos: kerberos_common.h guard not found" >&2; exit 1; }
    echo "kerberos: kerberos_common.h accepts AIX"
  fi
  if ! grep -q 'OS=="aix"' binding.gyp; then
    sed -i 's/OS=="mac" or OS=="linux"/OS=="mac" or OS=="linux" or OS=="aix"/g' binding.gyp
    grep -q 'OS=="aix"' binding.gyp || { echo "kerberos: binding.gyp conditions not found" >&2; exit 1; }
    echo "kerberos: binding.gyp builds the GSSAPI backend on AIX"
  fi
  # Link MIT krb5 the way krb5-config says (64-bit libs live in /opt/freeware/lib64 and AIX ld needs
  # -lcom_err/-lk5crypto spelled out). Keeping this inside kerberos's own gyp block means no global
  # LDFLAGS, which would drag other addons onto the non-threaded libstdc++ in /opt/freeware/lib64.
  if ! grep -q 'krb5-config --libs gssapi' binding.gyp; then
    python3 - binding.gyp <<'PYKRB'
import re, sys
path = sys.argv[1]
src = open(path).read()
new, n = re.subn(r"'libraries':\s*\[\s*'-lkrb5',\s*'-lgssapi_krb5'\s*\]",
                 "'libraries': [ '<!@(krb5-config --libs gssapi)' ]", src, count=1)
if n != 1:
    sys.exit("kerberos: binding.gyp libraries block not found; update build/aix/fix-node-modules.sh")
open(path, "w").write(new)
print("kerberos: binding.gyp links via krb5-config --libs gssapi")
PYKRB
  fi
  rm -rf prebuilds
  popd > /dev/null
fi
# }}}

# {{{ @vscode/deviceid: refuses platforms other than win32/darwin/linux/freebsd.
# Upstream fix: treat 'aix' like 'linux' in dist/index.js and dist/storage.js.
if [[ -d "${NM}/@vscode/deviceid/dist" ]]; then
  pushd "${NM}/@vscode/deviceid/dist" > /dev/null
  if [[ -f index.js ]] && ! grep -q '"aix"' index.js; then
    sed -i 's/process\.platform !== "linux"/process.platform !== "linux" \&\& process.platform !== "aix"/g' index.js
    echo "@vscode/deviceid: index.js accepts aix"
  fi
  if [[ -f storage.js ]] && ! grep -q '"aix"' storage.js; then
    sed -i 's/process\.platform === "linux"/process.platform === "linux" || process.platform === "aix"/g' storage.js
    echo "@vscode/deviceid: storage.js treats aix like linux"
  fi
  popd > /dev/null
fi
# }}}

# {{{ @vscode/ripgrep-universal: ships bin/<platform>-<arch>/rg for a fixed list; add ours.
if [[ -d "${NM}/@vscode/ripgrep-universal/bin" ]]; then
  RG="${VSCODE_AIX_RIPGREP:-}"
  if [[ -z "${RG}" || ! -x "${RG}" ]]; then
    echo "ripgrep-universal: set VSCODE_AIX_RIPGREP to an aix-ppc64 rg binary (build/aix/ripgrep.sh)" >&2
    exit 1
  fi
  mkdir -p "${NM}/@vscode/ripgrep-universal/bin/aix-ppc64"
  cp -f "${RG}" "${NM}/@vscode/ripgrep-universal/bin/aix-ppc64/rg"
  chmod 755 "${NM}/@vscode/ripgrep-universal/bin/aix-ppc64/rg"
  echo "ripgrep-universal: installed bin/aix-ppc64/rg ($("${RG}" --version | head -1))"
fi
# }}}

echo "fix-node-modules: done"
