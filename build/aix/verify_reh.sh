#!/usr/bin/env bash
#
# Verify a packaged aix-ppc64 REH tree before it is archived: every native addon is a 64-bit
# XCOFF object that loads under the bundled node, the AIX shim and the polling watcher work,
# node-pty spawns a shell, ripgrep runs, the server boots to "Extension host agent listening"
# and answers GET /version, and nothing touched AHAFS.
# Usage: build/aix/verify_reh.sh <reh-dir> [timeout-seconds]

set -e

REH="$( cd "${1:?usage: verify_reh.sh <reh-dir> [timeout]}" && pwd )"
TIMEOUT="${2:-${VSCODE_AIX_SMOKE_TIMEOUT:-180}}"
NODE="${REH}/node"
rc=0

[[ -x "${NODE}" ]] || { echo "verify_reh: ${NODE} missing or not executable" >&2; exit 1; }
# the launchers set LIBPATH the same way
# shellcheck disable=SC2034  # ROOT is read by bin/aix-env.sh
ROOT="${REH}"
. "${REH}/bin/aix-env.sh"

echo "verify_reh: node $("${NODE}" --version) ($("${NODE}" -p 'process.platform + "-" + process.arch'))"

# 1. native addons: present, XCOFF, loadable
REQUIRED=(
  node_modules/@vscode/native-watchdog/build/Release/watchdog.node
  node_modules/@vscode/spdlog/build/Release/spdlog.node
  node_modules/node-pty/build/Release/pty.node
  node_modules/@parcel/watcher/build/Release/watcher.node
  node_modules/@vscode/sqlite3/build/Release/vscode-sqlite3.node
  node_modules/kerberos/build/Release/kerberos.node
)
for f in "${REQUIRED[@]}"; do
  [[ -f "${REH}/${f}" ]] || { echo "verify_reh: required addon missing: ${f}" >&2; rc=1; }
done
while read -r f; do
  case "${f}" in *windows*.node|*/prebuilds/*) continue;; esac
  if ! file "${f}" | grep -q '64-bit XCOFF'; then
    echo "verify_reh: not a 64-bit XCOFF object: ${f} ($(file "${f}" | cut -d: -f2-))" >&2; rc=1; continue
  fi
  if ! "${NODE}" -e "require(process.argv[1])" "${f}" > /dev/null 2> /tmp/verify_reh.$$; then
    echo "verify_reh: addon failed to load: ${f}" >&2; head -5 /tmp/verify_reh.$$ >&2; rc=1
  fi
done < <(find "${REH}/node_modules" -name '*.node' -type f)
rm -f /tmp/verify_reh.$$
[[ ${rc} -eq 0 ]] || { echo "verify_reh: addon checks failed" >&2; exit 1; }
echo "verify_reh: addons OK"

# 1b. the AIX shim must be active in server processes: fs.watch replaced by stat polling (libuv's
# AIX fs.watch uses AHAFS, whose monitor pool can wedge a host), process.platform spoofed for the
# server, real platform for ripgrep. Exercise the shim's argv gating with the launcher's shape.
SHIMDIR="$( mktemp -d "${TMPDIR:-/tmp}/verify_reh_shim.XXXXXX" )"
cat > "${SHIMDIR}/server-main.js" <<'JS'
const fsw = String(require('fs').watch);
const spoofed = (function serverMainProbe() { return process.platform; })();
process.stdout.write((fsw.includes('PollingFSWatcher') ? 'shimmed' : 'native') + ' ' + spoofed + '\n');
JS
SHIM_OUT="$( cd "${SHIMDIR}" && "${NODE}" -r "${REH}/aix-platform-override.cjs" "${SHIMDIR}/server-main.js" 2>&1 || true )"
rm -rf "${SHIMDIR}"
case "${SHIM_OUT}" in
  "shimmed linux") echo "verify_reh: shim OK (fs.watch polling, platform spoofed as linux for the server)";;
  *) echo "verify_reh: AIX shim not active in a server-main process (got '${SHIM_OUT}'); the server would use AHAFS" >&2; exit 1;;
esac

# 1c. @parcel/watcher must deliver events through subscribe() (upstream's brute-force backend
# throws and takes the File Watcher process down with SIGABRT; the polling patch fixes that).
WDIR="$( mktemp -d "${TMPDIR:-/tmp}/verify_reh_watch.XXXXXX" )"
cat > "${WDIR}/probe.js" <<'JS'
const w = require(process.argv[2]); const fs = require('fs'); const dir = process.argv[3];
const t = setTimeout(() => { console.log('TIMEOUT'); process.exit(3); }, 15000);
w.subscribe(dir, (err, events) => {
  if (err) { console.log('ERROR ' + err.message); process.exit(2); }
  if (events.some(e => e.path.endsWith('/probe.txt'))) { console.log('EVENT'); clearTimeout(t); process.exit(0); }
}).then(() => fs.writeFileSync(dir + '/probe.txt', 'x'))
  .catch(e => { console.log('REJECTED ' + e.message); process.exit(2); });
JS
WATCH_OUT="$( PARCEL_WATCHER_POLL_INTERVAL_MS=500 "${NODE}" "${WDIR}/probe.js" "${REH}/node_modules/@parcel/watcher" "${WDIR}" 2>&1 | tail -1 || true )"
rm -rf "${WDIR}"
if [[ "${WATCH_OUT}" == "EVENT" ]]; then
  echo "verify_reh: @parcel/watcher subscribe delivers events"
else
  echo "verify_reh: @parcel/watcher subscribe failed: ${WATCH_OUT}" >&2; exit 1
fi

# 1d. node-pty must spawn a shell and deliver its output (openpty/forkpty come from the shipped
# libutil; LIBPATH from aix-env.sh). This is what the terminal and tasks depend on.
PDIR="$( mktemp -d "${TMPDIR:-/tmp}/verify_reh_pty.XXXXXX" )"
cat > "${PDIR}/probe.js" <<'JS'
const pty = require(process.argv[2]);
const t = setTimeout(() => { console.log('TIMEOUT'); process.exit(3); }, 20000);
let out = '';
const p = pty.spawn('/bin/sh', ['-c', 'echo pty-probe-$((40+2))'], { name: 'xterm', cols: 80, rows: 24, cwd: '/tmp', env: process.env });
p.onData(d => { out += d; });
p.onExit(() => { clearTimeout(t); console.log(out.includes('pty-probe-42') ? 'PTY_OK' : 'NO_OUTPUT ' + JSON.stringify(out)); process.exit(out.includes('pty-probe-42') ? 0 : 2); });
JS
PTY_OUT="$( "${NODE}" "${PDIR}/probe.js" "${REH}/node_modules/node-pty" 2>&1 | tail -1 || true )"
rm -rf "${PDIR}"
if [[ "${PTY_OUT}" == "PTY_OK" ]]; then
  echo "verify_reh: node-pty spawns a shell and delivers output"
else
  echo "verify_reh: node-pty spawn failed: ${PTY_OUT}" >&2; exit 1
fi

# 2. ripgrep
RG="${REH}/node_modules/@vscode/ripgrep-universal/bin/aix-ppc64/rg"
[[ -x "${RG}" ]] || { echo "verify_reh: ${RG} missing" >&2; exit 1; }
"${RG}" --version | head -1
echo 'needle' | "${RG}" -q needle || { echo "verify_reh: rg does not search" >&2; exit 1; }

# 3. the server boots
SERVER_APP="$( sed -n 's/.*"serverApplicationName": *"\([^"]*\)".*/\1/p' "${REH}/product.json" | head -1 )"
LAUNCHER="${REH}/bin/${SERVER_APP}"
[[ -x "${LAUNCHER}" ]] || { echo "verify_reh: launcher missing: ${LAUNCHER}" >&2; exit 1; }
DATA="$( mktemp -d "${TMPDIR:-/tmp}/verify_reh.XXXXXX" )"
LOG="${DATA}/server.log"
# job control gives the server its own process group so the extension host / pty host / file
# watcher children die with it
set -m
( cd "${REH}" && exec "${LAUNCHER}" --accept-server-license-terms --host 127.0.0.1 --port 0 \
    --without-connection-token --server-data-dir "${DATA}/data" --extensions-dir "${DATA}/ext" \
    --telemetry-level off ) > "${LOG}" 2>&1 &
PID=$!
set +m
ok=no
for (( i = 0; i < TIMEOUT; i++ )); do
  if grep -q 'Extension host agent listening' "${LOG}" 2> /dev/null; then ok=yes; break; fi
  kill -0 "${PID}" 2> /dev/null || break
  sleep 1
done
fail=""
if [[ "${ok}" != "yes" ]]; then
  fail="server did not reach 'Extension host agent listening' within ${TIMEOUT}s"
else
  PORT="$( sed -n 's/.*Extension host agent listening on \([0-9][0-9]*\).*/\1/p' "${LOG}" | head -1 )"
  COMMIT="$( sed -n 's/.*"commit": *"\([0-9a-f]*\)".*/\1/p' "${REH}/product.json" | head -1 )"
  if [[ -n "${PORT}" ]] && command -v curl > /dev/null; then
    if curl -fsS -m 15 "http://127.0.0.1:${PORT}/version" 2> /dev/null | grep -q "${COMMIT}"; then
      echo "verify_reh: GET /version answers with commit ${COMMIT}"
    else
      fail="server listens on ${PORT} but GET /version does not return its commit"
    fi
  fi
  # the server and its children must not have touched AHAFS: a directory watch creates
  # /aha/fs/modDir.monFactory<dir>.mon, a single-file watch /aha/fs/modFile.monFactory<file>.mon
  # (VS Code's non-recursive watcher watches files such as extensions.json directly). Monitor
  # files persist after the watcher closes, so anything under our private data dir is ours.
  if [[ -z "${fail}" && -d /aha/fs ]]; then
    MON="$( find "/aha/fs/modDir.monFactory${DATA}" "/aha/fs/modFile.monFactory${DATA}" -name '*.mon' 2> /dev/null | head -3 || true )"
    [[ -z "${MON}" ]] || fail="server created AHAFS monitors (fs.watch shim inactive in a child?): ${MON}"
  fi
fi
# stop the server and every descendant (extension host, pty host, file watcher): the process group
# kill is not always enough on AIX, so also walk the ps tree
descendants() { # pid -> all descendant pids
  local parent=$1 child
  for child in $( ps -eo pid,ppid | awk -v p="${parent}" '$2 == p { print $1 }' ); do
    echo "${child}"; descendants "${child}"
  done
}
VICTIMS="${PID} $( descendants "${PID}" )"
kill -TERM -- "-${PID}" 2> /dev/null || true
# shellcheck disable=SC2086
kill -TERM ${VICTIMS} 2> /dev/null || true
sleep 2
kill -KILL -- "-${PID}" 2> /dev/null || true
# shellcheck disable=SC2086
kill -KILL ${VICTIMS} 2> /dev/null || true
wait "${PID}" 2> /dev/null || true
LEFT="$( ps -eo pid,args | grep -F "${REH}/" | grep -E 'server-main|bootstrap-fork' | grep -v grep | awk '{print $1}' )"
[[ -z "${LEFT}" ]] || { echo "verify_reh: server processes still alive after kill: ${LEFT}" >&2; fail="${fail:+${fail}; }server processes survived (stuck in the kernel?)"; }
if [[ -n "${fail}" ]]; then
  echo "verify_reh: ${fail}; log:" >&2
  tail -60 "${LOG}" >&2 || true
  rm -rf "${DATA}"
  exit 1
fi
if grep -qiE 'error|cannot find module|not supported' "${LOG}"; then
  echo "verify_reh: server log has error lines (review):"
  grep -iE 'error|cannot find module|not supported' "${LOG}" | head -10
fi
echo "verify_reh: server boots (extension host listening)"

# 4. remote CLI
CLI="$( ls "${REH}"/bin/remote-cli/* 2> /dev/null | head -1 )"
if [[ -n "${CLI}" ]]; then
  "${CLI}" --version > /dev/null 2>&1 && echo "verify_reh: remote-cli OK" || echo "verify_reh: remote-cli --version failed (non-fatal)"
fi
rm -rf "${DATA}"
echo "verify_reh: PASS"
