#!/usr/bin/env bash
# test-ai-crew.sh — self-contained fixture suite for ai-crew.sh.
# Builds throwaway git repos / installed json / stub `claude` under mktemp.
# NEVER invokes the real `claude` and never reads or writes the real ~/.claude:
# $HOME and $CLAUDE_CONFIG_DIR are re-pointed into the temp dir before the first
# fixture is built, so even a forgotten AI_CREW_* override lands in the sandbox.
# shellcheck disable=SC2016  # jq filters / inner-bash scripts are single-quoted on purpose
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/ai-crew.sh"
TMP=$(mktemp -d)
export STUB_PIDS="$TMP/bg.pids"
trap '[ -f "$STUB_PIDS" ] && xargs kill <"$STUB_PIDS" 2>/dev/null; rm -rf "$TMP"' EXIT
# Belt and braces: no default path in ai-crew.sh can now reach the real home.
mkdir -p "$TMP/cfg/.claude"
export HOME="$TMP/cfg"
export CLAUDE_CONFIG_DIR="$TMP/cfg/.claude"
PASS=0; FAIL=0; N=0

G() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }

# mkcache <dir> <version>: an installed payload with its own manifest.
mkcache() { mkdir -p "$1/.claude-plugin"; echo "{\"version\":\"$2\"}" >"$1/.claude-plugin/plugin.json"; }

# mkfix: fresh fixture. Plugins: alpha (passing suite), beta (no suite).
mkfix() {
  N=$((N + 1)); F="$TMP/f$N"; mkdir -p "$F"
  local repo="$F/repo"
  mkdir -p "$repo/.claude-plugin" "$repo/alpha/.claude-plugin" "$repo/alpha/tests" "$repo/beta/.claude-plugin"
  cat >"$repo/.claude-plugin/marketplace.json" <<'EOF'
{"name":"cjs-plugins","plugins":[{"name":"alpha","source":"./alpha"},{"name":"beta","source":"./beta"}]}
EOF
  echo '{"name":"alpha","version":"1.0.0"}' >"$repo/alpha/.claude-plugin/plugin.json"
  echo '{"name":"beta","version":"2.0.0"}' >"$repo/beta/.claude-plugin/plugin.json"
  printf '#!/usr/bin/env bash\necho "1 passed, 0 failed, 0 skipped"\n' >"$repo/alpha/tests/run.sh"
  chmod +x "$repo/alpha/tests/run.sh"
  G -C "$repo" init -q -b main && G -C "$repo" add -A && G -C "$repo" commit -qm init
  G clone -q "$repo" "$F/clone"
  mkdir -p "$F/vendor/plugins/codex/.claude-plugin"
  echo '{"name":"codex","version":"1.0.6"}' >"$F/vendor/plugins/codex/.claude-plugin/plugin.json"
  G -C "$F/vendor" init -q -b main && G -C "$F/vendor" add -A && G -C "$F/vendor" commit -qm v
  CSHA=$(git -C "$F/clone" rev-parse HEAD); VSHA=$(git -C "$F/vendor" rev-parse HEAD)
  mkcache "$F/cache/cjs-plugins/alpha/1.0.0" 1.0.0
  mkcache "$F/cache/cjs-plugins/beta/2.0.0" 2.0.0
  mkcache "$F/cache/openai-codex/codex/1.0.6" 1.0.6
  write_installed 1.0.0 "$F/cache/cjs-plugins/alpha/1.0.0" "$CSHA"
  cat >"$F/claude" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
if [ -n "${STUB_ADVANCE_CLONE:-}" ]; then
  git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    -C "$AI_CREW_CLONE" commit -q --allow-empty -m moved
fi
[ -n "${STUB_DIRTY_CLONE:-}" ] && touch "$AI_CREW_CLONE/stray-from-stub"
# A lingering descendant holding every inherited fd (except stdio, so the
# harness's output capture is not held open).
if [ -n "${STUB_BG:-}" ]; then sleep 60 </dev/null >/dev/null 2>&1 & echo $! >>"$STUB_PIDS"; fi
# A DIFFERENT owner takes over the lock pathname while this update holds the
# lock: the directory is replaced wholesale, token and all. Fires once — the
# marker it leaves is also what stops the next stub call from redoing it.
if [ -n "${STUB_HIJACK_LOCK:-}" ] && [ ! -f "$STUB_HIJACK_LOCK/marker" ]; then
  rm -rf "$STUB_HIJACK_LOCK"
  mkdir -p "$STUB_HIJACK_LOCK"
  echo "not-your-token" >"$STUB_HIJACK_LOCK/token"
  echo $$ >"$STUB_HIJACK_LOCK/pid"
  echo live >"$STUB_HIJACK_LOCK/marker"
fi
[ -n "${STUB_FAIL_KEY:-}" ] && [[ " $* " == *" $STUB_FAIL_KEY "* ]] && { echo "stub: failing $STUB_FAIL_KEY" >&2; exit 1; }
exit 0
EOF
  chmod +x "$F/claude"
  mkdir -p "$F/cfg/.claude"
  export AI_CREW_REPO="$repo" AI_CREW_CLONE="$F/clone" AI_CREW_INSTALLED="$F/installed.json" \
    AI_CREW_CACHE="$F/cache" AI_CREW_VENDOR_CLONE="$F/vendor" \
    AI_CREW_VENDOR_MANIFEST="$F/vendor/plugins/codex/.claude-plugin/plugin.json" \
    AI_CREW_SNAPSHOT="$F/snap/pre.json" AI_CREW_RECEIPT="$F/snap/receipt.json" \
    AI_CREW_SETTINGS="$F/cfg/.claude/settings.json" \
    AI_CREW_CLAUDE_MD="$F/cfg/.claude/CLAUDE.md" \
    AI_CREW_CREW_CONFIG="$F/cfg/.claude/plugins/data/crew/config.json" \
    AI_CREW_KNOWN="$F/cfg/.claude/plugins/known_marketplaces.json" \
    CLAUDE_BIN="$F/claude" STUB_LOG="$F/stub.log"
  # $HOME/.claude/hooks is outside $F and therefore SHARED by every fixture:
  # a provenance-bearing copy left there would silently prove a later fixture's
  # hook. Each fixture starts with that directory empty.
  rm -rf "$HOME/.claude/hooks"
  unset STUB_FAIL_KEY STUB_ADVANCE_CLONE STUB_DIRTY_CLONE STUB_BG STUB_HIJACK_LOCK AI_CREW_MARKETPLACES
  : >"$F/stub.log"
}

# write_installed <alpha-version> <alpha-installPath> <alpha-sha>
write_installed() {
  jq -n --arg av "$1" --arg ap "$2" --arg as "$3" --arg c "$F/cache" --arg cs "$CSHA" --arg vs "$VSHA" '{version:2, plugins:{
    "alpha@cjs-plugins":[{scope:"user",version:$av,installPath:$ap,gitCommitSha:$as}],
    "beta@cjs-plugins":[{scope:"user",version:"2.0.0",installPath:"\($c)/cjs-plugins/beta/2.0.0",gitCommitSha:$cs}],
    "codex@openai-codex":[{scope:"user",version:"1.0.6",installPath:"\($c)/openai-codex/codex/1.0.6",gitCommitSha:$vs}]}}' \
    >"$F/installed.json"
}

# mkmkt2 <name> <plugin> <version>: a SECOND marketplace repo + clone + cache +
# installed entry, and point AI_CREW_MARKETPLACES at both. The clone path is the
# one ai-crew.sh derives: <dirname of AI_CREW_CLONE>/<name>.
mkmkt2() {
  local name=$1 plug=$2 ver=$3 repo="$F/repo-$1"
  mkdir -p "$repo/.claude-plugin" "$repo/$plug/.claude-plugin" "$repo/$plug/tests"
  jq -n --arg n "$name" --arg p "$plug" '{name:$n, plugins:[{name:$p, source:"./\($p)"}]}' \
    >"$repo/.claude-plugin/marketplace.json"
  jq -n --arg p "$plug" --arg v "$ver" '{name:$p, version:$v}' >"$repo/$plug/.claude-plugin/plugin.json"
  printf '#!/usr/bin/env bash\necho "1 passed, 0 failed, 0 skipped"\n' >"$repo/$plug/tests/run.sh"
  chmod +x "$repo/$plug/tests/run.sh"
  G -C "$repo" init -q -b main && G -C "$repo" add -A && G -C "$repo" commit -qm init
  G clone -q "$repo" "$F/$name"
  C2SHA=$(git -C "$F/$name" rev-parse HEAD)
  mkcache "$F/cache/$name/$plug/$ver" "$ver"
  jqi "$AI_CREW_INSTALLED" '.plugins["\($p)@\($n)"] = [{scope:"user", version:$v, installPath:$ip, gitCommitSha:$s}]' \
    --arg p "$plug" --arg n "$name" --arg v "$ver" --arg ip "$F/cache/$name/$plug/$ver" --arg s "$C2SHA"
  export AI_CREW_MARKETPLACES="cjs-plugins=$AI_CREW_REPO;$name=$repo"
}

# mkscrub <exit-code>: a scrub-check.sh in the fixture repo that logs how it was
# invoked and exits with the given code. Committed, because the gate refuses to
# write a receipt from a dirty tree.
mkscrub() {
  mkdir -p "$AI_CREW_REPO/scripts"
  { echo '#!/usr/bin/env bash'
    echo "echo \"args: \$*\" >>\"$F/scrub.log\""
    echo "echo \"denylist: \${SCRUB_DENYLIST:-<unset>}\" >>\"$F/scrub.log\""
    echo "exit $1"
  } >"$AI_CREW_REPO/scripts/scrub-check.sh"
  chmod +x "$AI_CREW_REPO/scripts/scrub-check.sh"
  G -C "$AI_CREW_REPO" add -A && G -C "$AI_CREW_REPO" commit -qm scrub
  G -C "$AI_CREW_CLONE" pull -q origin main
  : >"$F/scrub.log"
}

# mkhooks <installPath> <script>: a plugin that registers its own hook through
# hooks/hooks.json (the harness resolves ${CLAUDE_PLUGIN_ROOT}).
mkhooks() {
  mkdir -p "$1/hooks"
  cat >"$1/hooks/hooks.json" <<EOF
{"hooks":{"PreToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"\${CLAUDE_PLUGIN_ROOT}/hooks/$2"}]}]}}
EOF
  printf '#!/usr/bin/env python3\n' >"$1/hooks/$2"
}

# mkuserhook <path> <installPath> <basename>: a byte-identical copy of the
# plugin's shipped hook at <path>. That copy is what gives a registration
# OUTSIDE the plugin's own directory its provenance — same bytes, so the
# duplicate registration provably runs the same code.
mkuserhook() { mkdir -p "$(dirname "$1")"; cp "$2/hooks/$3" "$1"; }

# mkownhook <path>: a file with the same BASENAME as a plugin hook but content
# of its own — a user's hook that merely collides, which must never be removed.
mkownhook() { mkdir -p "$(dirname "$1")"; printf '#!/usr/bin/env python3\n# a gate of my own\n' >"$1"; }

# ALPHA_PATH: the installPath of the fixture's alpha plugin.
ALPHA_PATH() { echo "$F/cache/cjs-plugins/alpha/1.0.0"; }

# mkenvfrag <installPath> <key> <value>
mkenvfrag() { jq -n --arg k "$2" --arg v "$3" '{env: {($k): $v}}' >"$1/settings.fragment.json"; }

# mkmdfrag <installPath> <plugin> <body>
mkmdfrag() { printf '<!-- %s:start -->\n%s\n<!-- %s:end -->\n' "$2" "$3" "$2" >"$1/claude-md.fragment.md"; }

# mksettings: write $AI_CREW_SETTINGS from stdin.
mksettings() { mkdir -p "$(dirname "$AI_CREW_SETTINGS")"; cat >"$AI_CREW_SETTINGS"; }

# jqi <file> <filter> [jq args...]: in-place jq edit.
jqi() { local f=$1 q=$2; shift 2; jq "$@" "$q" "$f" >"$f.x" && mv "$f.x" "$f"; }

# bound: record _bound as a real `update` would (current clone/vendor HEADs).
bound() {
  jqi "$AI_CREW_SNAPSHOT" '._bound = {boundHead: $h, vendorHead: $v}' \
    --arg h "$(git -C "$AI_CREW_CLONE" rev-parse HEAD)" --arg v "$VSHA"
}

# t <name> <want-rc> <grep-pattern or ""> -- cmd...
t() {
  local name=$1 want=$2 pat=$3 out rc; shift 4
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ] && { [ -z "$pat" ] || grep -qE -- "$pat" <<<"$out"; }; then
    PASS=$((PASS + 1)); echo "ok   $name"
  else
    FAIL=$((FAIL + 1)); echo "FAIL $name (rc=$rc want=$want pat='$pat')"
    # shellcheck disable=SC2001  # per-line prefix of multi-line output
    sed 's/^/     | /' <<<"$out"
  fi
}
S() { "$SCRIPT" "$@"; }

# ---- usage
mkfix
t "usage: no subcommand -> 2" 2 "usage" -- S
t "usage: unknown subcommand -> 2" 2 "usage" -- S bogus
t "usage: reconcile bad flag -> 2" 2 "usage" -- S reconcile --nope

# ---- gate
mkfix
t "gate happy (1 pass, 1 UNGATED)" 0 "gate: plugins=2 suites_run=1 ungated=1 failed=0" -- S gate
t "gate prints NO TEST SUITE for beta" 0 "beta: NO TEST SUITE — installs UNGATED" -- S gate
t "gate receipt contents" 0 "" -- jq -e --arg h "$CSHA" --arg m "$(sha256sum "$AI_CREW_REPO/.claude-plugin/marketplace.json" | cut -d' ' -f1)" \
  '.repoHead == $h and .marketplaceSha256 == $m and .targets == ["alpha","beta"] and .suitesRun == 1 and .ungated == 1 and (.ts | type == "string")' "$AI_CREW_RECEIPT"
printf '#!/usr/bin/env bash\nexit 1\n' >"$AI_CREW_REPO/alpha/tests/run.sh"
t "gate failure after success -> nonzero" 1 "failed=1" -- S gate
t "gate failure removed old receipt" 0 "" -- test ! -e "$AI_CREW_RECEIPT"

mkfix; S gate >/dev/null; echo '{}' >"$AI_CREW_REPO/.claude-plugin/marketplace.json"
t "gate dying early also removes receipt" 1 "non-empty array" -- S gate
t "gate dying early: receipt gone" 0 "" -- test ! -e "$AI_CREW_RECEIPT"

mkfix; printf '#!/usr/bin/env bash\ngit -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null -C "$AI_CREW_REPO" commit -q --allow-empty -m mid\n' \
  >"$AI_CREW_REPO/alpha/tests/run.sh"
G -C "$AI_CREW_REPO" commit -qam "suite that commits"
t "gate HEAD moved during the run" 1 "gate: FAIL — HEAD moved during the run" -- S gate
t "gate HEAD moved: receipt absent" 0 "" -- test ! -e "$AI_CREW_RECEIPT"

mkfix; touch "$AI_CREW_REPO/stray"
t "gate dirty repo -> no receipt" 1 "dirty; tested code != HEAD" -- S gate
t "gate dirty repo: receipt absent" 0 "" -- test ! -e "$AI_CREW_RECEIPT"

mkfix; rm "$AI_CREW_REPO/.claude-plugin/marketplace.json"
t "gate missing marketplace.json" 1 "marketplace file not found" -- S gate

mkfix; echo '{"plugins":[]}' >"$AI_CREW_REPO/.claude-plugin/marketplace.json"
t "gate empty plugins array" 1 "non-empty array" -- S gate

mkfix; echo '{"plugins":{}}' >"$AI_CREW_REPO/.claude-plugin/marketplace.json"
t "gate plugins not an array" 1 "non-empty array" -- S gate

mkfix; echo 'not json' >"$AI_CREW_REPO/.claude-plugin/marketplace.json"
t "gate unparseable marketplace.json" 1 "unparseable" -- S gate

for bad in '"../x"' '"./a b"' '{"source":"github","repo":"x/y"}' '"./.."' '"alpha"'; do
  mkfix
  echo "{\"plugins\":[{\"name\":\"alpha\",\"source\":$bad}]}" >"$AI_CREW_REPO/.claude-plugin/marketplace.json"
  t "gate invalid source $bad" 1 "invalid source" -- S gate
done

mkfix; echo '{"plugins":[{"name":"alpha","source":""}]}' >"$AI_CREW_REPO/.claude-plugin/marketplace.json"
t "gate empty-string source" 1 "plugin 'alpha' has invalid source '<empty source>'" -- S gate

mkfix; echo '{"plugins":[{"name":"a b","source":"./alpha"}]}' >"$AI_CREW_REPO/.claude-plugin/marketplace.json"
t "gate invalid name" 1 "invalid plugin name" -- S gate

mkfix; echo '{"plugins":[{"name":"","source":"./alpha"}]}' >"$AI_CREW_REPO/.claude-plugin/marketplace.json"
t "gate empty-string name -> accurate error" 1 "invalid plugin name '<empty name>'" -- S gate

mkfix; chmod -x "$AI_CREW_REPO/alpha/tests/run.sh"
t "gate run.sh not executable" 1 "not a regular executable" -- S gate

mkfix; rm "$AI_CREW_REPO/alpha/tests/run.sh"; mkdir "$AI_CREW_REPO/alpha/tests/run.sh"
t "gate run.sh is a directory" 1 "not a regular executable" -- S gate

mkfix; printf '#!/usr/bin/env bash\necho "0 passed, 1 failed"; exit 1\n' >"$AI_CREW_REPO/alpha/tests/run.sh"
t "gate failing suite" 1 "failed=1" -- S gate

mkfix; rm -rf "$AI_CREW_REPO/beta"
t "gate plugin directory missing" 1 "does not exist" -- S gate

mkfix; export AI_CREW_REPO="$F/nope"
t "gate cd target missing" 1 "cannot cd" -- S gate

# ---- gate: secret scrub
mkfix
t "scrub: absent is announced" 0 "has no scripts/scrub-check.sh \(skipped\)" -- S gate
t "scrub: absent is recorded in the receipt" 0 "" -- jq -e '.scrub == "absent"' "$AI_CREW_RECEIPT"

mkfix; mkscrub 0
t "scrub: a clean scrub passes the gate" 0 "^scrub: PASS" -- S gate
t "scrub: pass is recorded in the receipt" 0 "" -- jq -e '.scrub == "pass"' "$AI_CREW_RECEIPT"
t "scrub: invoked with --require-private and the repo" 0 "" -- grep -q -- "args: --require-private $AI_CREW_REPO" "$F/scrub.log"
t "scrub: no --allow when the allow file is absent" 1 "" -- grep -q -- "--allow" "$F/scrub.log"

mkfix; mkscrub 0; echo 'some-token' >"$AI_CREW_REPO/scripts/scrub-allow.txt"
G -C "$AI_CREW_REPO" add -A; G -C "$AI_CREW_REPO" commit -qm allow; G -C "$AI_CREW_CLONE" pull -q origin main
: >"$F/scrub.log"
t "scrub: runs with the allow file when present" 0 "^scrub: PASS" -- S gate
t "scrub: --allow points at the repo's allow file" 0 "" -- grep -q -- "--allow $AI_CREW_REPO/scripts/scrub-allow.txt" "$F/scrub.log"
: >"$F/scrub.log"
t "scrub: SCRUB_DENYLIST is passed through" 0 "" -- env SCRUB_DENYLIST=/tmp/dl.txt "$SCRIPT" gate
t "scrub: the child saw SCRUB_DENYLIST" 0 "" -- grep -qx "denylist: /tmp/dl.txt" "$F/scrub.log"

mkfix; mkscrub 1
t "scrub: exit 1 fails the gate" 1 "^scrub: FAIL — .* exited 1" -- S gate
t "scrub: a failing scrub writes no receipt" 0 "" -- test ! -e "$AI_CREW_RECEIPT"

mkfix; mkscrub 2
t "scrub: exit 2 fails the gate" 1 "^scrub: FAIL — .* exited 2" -- S gate
t "scrub: exit 2 writes no receipt" 0 "" -- test ! -e "$AI_CREW_RECEIPT"

mkfix; mkscrub 4
t "scrub: exit 4 is a warning, not a failure" 0 "^scrub: WARNING \(exit 4\)" -- S gate
t "scrub: warn is recorded in the receipt" 0 "" -- jq -e '.scrub == "warn"' "$AI_CREW_RECEIPT"

# An unknown exit code must fail closed, not read as success.
mkfix; mkscrub 7
t "scrub: an unknown exit code fails the gate" 1 "^scrub: FAIL — .* exited 7" -- S gate
t "scrub: unknown exit code writes no receipt" 0 "" -- test ! -e "$AI_CREW_RECEIPT"

# ---- bind
mkfix
t "bind clean + identical" 0 "^bind: PASS" -- S bind

mkfix; touch "$AI_CREW_CLONE/stray"
t "bind dirty clone (untracked)" 1 "clean .*/clone: FAIL" -- S bind

mkfix; touch "$AI_CREW_REPO/stray"
t "bind dirty repo (untracked)" 1 "clean .*/repo: FAIL" -- S bind

mkfix; echo ' ' >>"$AI_CREW_CLONE/.claude-plugin/marketplace.json"
t "bind differing marketplace.json, same HEAD" 1 "marketplace.json identical: FAIL" -- S bind

mkfix; echo x >"$AI_CREW_REPO/new"; G -C "$AI_CREW_REPO" add -A; G -C "$AI_CREW_REPO" commit -qm two
t "bind HEAD mismatch" 1 "HEAD equal: FAIL" -- S bind

mkfix; rm -rf "$AI_CREW_CLONE/.git"
t "bind clone not a git repo" 1 "FAIL" -- S bind

# ---- status
mkfix
t "status happy" 0 "alpha  installed=1.0.0  available=1.0.0" -- S status
t "status vendor row" 0 "vendor codex@openai-codex  installed=1.0.6  available=1.0.6" -- S status
t "status marketplace header" 0 "^== marketplace cjs-plugins " -- S status
t "status reconcile clean with no fragments" 0 "^reconcile: clean" -- S status

mkfix; jqi "$AI_CREW_INSTALLED" 'del(.plugins["beta@cjs-plugins"])'
t "status missing key -> NOT INSTALLED" 0 "beta  installed=NOT INSTALLED  available=2.0.0" -- S status
t "status counts the skipped catalogue entry" 0 "^status: 3 catalogued, 2 installed, 1 not installed" -- S status

mkfix; jqi "$AI_CREW_INSTALLED" '.plugins["ghost@other-mkt"] = [{scope:"user",version:"1.0.0",installPath:"/nowhere",gitCommitSha:"x"}]'
t "status lists an installed but unconfigured marketplace" 0 "^unconfigured marketplace: other-mkt" -- S status

mkfix; echo '{corrupt' >"$AI_CREW_INSTALLED"
t "status corrupt installed json" 1 "unparseable" -- S status

mkfix; rm "$AI_CREW_INSTALLED"
t "status installed json missing" 1 "not found" -- S status

mkfix; jqi "$AI_CREW_INSTALLED" '.plugins["beta@cjs-plugins"] = {"version":"2.0.0"}'
t "status entry not an array" 1 "not a non-empty array" -- S status

mkfix; rm "$AI_CREW_CLONE/beta/.claude-plugin/plugin.json"
t "status missing manifest" 1 "manifest not found" -- S status

mkfix; rm "$AI_CREW_VENDOR_MANIFEST"
t "status missing vendor manifest" 1 "manifest not found" -- S status

# CLAUDE_CONFIG_DIR must govern EVERY default path, not half of them: reading
# installed_plugins.json from one tree while writing settings.json into another
# is a split brain that looks like success. Nothing but CLAUDE_CONFIG_DIR is set
# here — no AI_CREW_* override, and $HOME still points at the suite's sandbox.
mkfix
CFG="$F/cfgroot"; mkdir -p "$CFG/plugins/marketplaces" "$CFG/plugins/data/ai-crew-update"
cp -R "$AI_CREW_CLONE" "$CFG/plugins/marketplaces/cjs-plugins"
cp -R "$AI_CREW_VENDOR_CLONE" "$CFG/plugins/marketplaces/openai-codex"
cp -R "$F/cache" "$CFG/plugins/cache"
jq --arg c "$CFG/plugins/cache" '.plugins |= with_entries(.value[0].installPath |= sub("^.*/cache"; $c))' \
  "$AI_CREW_INSTALLED" >"$CFG/plugins/installed_plugins.json"
# A subshell would swallow the PASS/FAIL counters, so the overrides are cleared
# per invocation with `env -u` instead.
CLEAN=(env -u AI_CREW_CLONE -u AI_CREW_INSTALLED -u AI_CREW_CACHE -u AI_CREW_VENDOR_CLONE
       -u AI_CREW_VENDOR_MANIFEST -u AI_CREW_SNAPSHOT -u AI_CREW_RECEIPT -u AI_CREW_SETTINGS
       -u AI_CREW_CLAUDE_MD -u AI_CREW_CREW_CONFIG -u AI_CREW_KNOWN -u AI_CREW_MARKETPLACES
       -u AI_CREW_DATA_DIR -u AI_CREW_AMBIGUOUS_ACK
       "CLAUDE_CONFIG_DIR=$CFG" "AI_CREW_REPO=$F/repo" "$SCRIPT")
t "config dir: status resolves every default under CLAUDE_CONFIG_DIR" 0 "alpha  installed=1.0.0  available=1.0.0" -- "${CLEAN[@]}" status
t "config dir: the vendor row resolves too" 0 "vendor codex@openai-codex  installed=1.0.6" -- "${CLEAN[@]}" status
t "config dir: nothing was read from the sandbox HOME" 0 "" -- test ! -e "$HOME/.claude/plugins/installed_plugins.json"
"${CLEAN[@]}" snapshot >/dev/null
t "config dir: the snapshot landed under CLAUDE_CONFIG_DIR" 0 "" -- test -f "$CFG/plugins/data/ai-crew-update/pre-update.json"
t "config dir: no snapshot landed under HOME" 0 "" -- test ! -e "$HOME/.claude/plugins/data/ai-crew-update/pre-update.json"

# $HOME is unwritable: every path ai-crew.sh touches must come from an explicit
# override, never from a $HOME default. If any default leaked, this would fail.
mkfix; mkdir -p "$F/nohome"; chmod 500 "$F/nohome"
t "no path falls back to the real HOME" 0 "^reconcile: clean" -- env HOME="$F/nohome" CLAUDE_CONFIG_DIR="$F/nohome/.claude" "$SCRIPT" status
chmod 700 "$F/nohome"

# ---- snapshot
mkfix; jqi "$AI_CREW_INSTALLED" 'del(.plugins["beta@cjs-plugins"])'
t "snapshot writes file" 0 "snapshot written" -- S snapshot
t "snapshot skips the not-installed plugin" 0 "^skip: beta@cjs-plugins not installed" -- S snapshot
t "snapshot entry values (absent / version / sha / installPath)" 0 "" -- jq -e \
  --arg cs "$CSHA" --arg vs "$VSHA" --arg ap "$F/cache/cjs-plugins/alpha/1.0.0" --arg vp "$F/cache/openai-codex/codex/1.0.6" \
  '(has("beta@cjs-plugins") | not)
   and .["alpha@cjs-plugins"] == {version:"1.0.0", gitCommitSha:$cs, installPath:$ap}
   and .["codex@openai-codex"] == {version:"1.0.6", gitCommitSha:$vs, installPath:$vp}' "$AI_CREW_SNAPSHOT"

mkfix; echo '{corrupt' >"$AI_CREW_INSTALLED"
t "snapshot corrupt installed json" 1 "unparseable" -- S snapshot

mkfix; jqi "$AI_CREW_INSTALLED" 'del(.plugins["alpha@cjs-plugins"][0].gitCommitSha)'
t "snapshot refuses entry without gitCommitSha" 1 "snapshot not written" -- S snapshot
t "snapshot refused: no file written" 0 "" -- test ! -e "$AI_CREW_SNAPSHOT"

# ---- update
mkfix; S gate >/dev/null
t "update without snapshot" 1 "run 'ai-crew.sh snapshot' first" -- S update
t "update without snapshot calls no claude" 0 "" -- test ! -s "$STUB_LOG"

mkfix; S snapshot >/dev/null
t "update without receipt" 1 "no gate receipt .* run 'ai-crew.sh gate' first" -- S update
t "update without receipt calls no claude" 0 "" -- test ! -s "$STUB_LOG"

mkfix; S gate >/dev/null; S snapshot >/dev/null; jqi "$AI_CREW_RECEIPT" '.repoHead = "0000000000000000000000000000000000000000"'
t "update receipt stale repoHead" 1 "did not test this commit" -- S update
t "update stale receipt calls no claude" 0 "" -- test ! -s "$STUB_LOG"

mkfix; S gate >/dev/null; S snapshot >/dev/null; jqi "$AI_CREW_RECEIPT" '.marketplaceSha256 = "abc"'
t "update receipt different marketplace sha" 1 "marketplaceSha256 != clone marketplace.json" -- S update
t "update bad-sha receipt calls no claude" 0 "" -- test ! -s "$STUB_LOG"

mkfix; S gate >/dev/null; S snapshot >/dev/null
t "update happy" 0 "all 3 update commands succeeded" -- S update
t "update happy called all 3 keys" 0 "" -- bash -c '[ "$(wc -l <"$1")" -eq 3 ]' _ "$STUB_LOG"
t "update recorded _bound" 0 "" -- jq -e --arg h "$CSHA" --arg v "$VSHA" '._bound == {boundHead:$h, vendorHead:$v}' "$AI_CREW_SNAPSHOT"
t "end-to-end: verify after update (all no-op)" 0 "verify: PASS \(3 entries\)" -- S verify

mkfix; S gate >/dev/null; S snapshot >/dev/null; export STUB_FAIL_KEY="alpha@cjs-plugins"
t "update one failure names key" 1 "FAILED for: alpha@cjs-plugins" -- S update
t "update continued past failure (beta)" 0 "" -- grep -qx "plugin update beta@cjs-plugins" "$STUB_LOG"
t "update continued past failure (vendor)" 0 "" -- grep -qx "plugin update codex@openai-codex" "$STUB_LOG"

mkfix; S gate >/dev/null; S snapshot >/dev/null; touch "$AI_CREW_CLONE/stray"
t "update aborts when bind fails" 1 "refusing to update" -- S update
t "update after bind fail calls no claude" 0 "" -- test ! -s "$STUB_LOG"

mkfix; S gate >/dev/null; S snapshot >/dev/null; export STUB_ADVANCE_CLONE=1
t "update aborts when clone advances after bind" 1 "ABORT — clone moved after bind" -- S update
t "update drift: stopped after first update" 0 "" -- bash -c '[ "$(wc -l <"$1")" -eq 1 ]' _ "$STUB_LOG"
t "verify after drift fails" 1 "clone moved after bind; gate proved nothing" -- S verify

mkfix; S gate >/dev/null; S snapshot >/dev/null; export STUB_DIRTY_CLONE=1
t "update aborts when clone tree dirtied after first key" 1 "clone modified after bind.*" -- S update
# Fresh fixture: re-running on the one above would fail in bind (already dirty),
# which prints the filename too and would mask a missing drift check.
mkfix; S gate >/dev/null; S snapshot >/dev/null; export STUB_DIRTY_CLONE=1
t "update dirty abort names the file" 1 "^    \?\? stray-from-stub" -- S update
t "update dirty: stopped after first update" 0 "" -- bash -c '[ "$(wc -l <"$1")" -eq 1 ]' _ "$STUB_LOG"

mkfix; S gate >/dev/null; S snapshot >/dev/null
t "update refuses while lock held" 1 "another update in progress" -- flock "$F/snap/update.lock" "$SCRIPT" update
t "locked update calls no claude" 0 "" -- test ! -s "$STUB_LOG"

# The lock fd must not leak to children: a lingering descendant of the stub
# (sleep 60) would otherwise keep the lock after the first update exits.
mkfix; S gate >/dev/null; S snapshot >/dev/null; export STUB_BG=1
t "update with lingering stub children" 0 "all 3 update commands succeeded" -- S update
unset STUB_BG
t "next update not blocked by lingering children" 0 "all 3 update commands succeeded" -- S update

# flock missing (stock macOS): PATH holds every external command the script
# uses, except flock; the mkdir lock takes over.
mkfix; S gate >/dev/null; S snapshot >/dev/null
NOFLOCK="$F/noflock-bin"; mkdir -p "$NOFLOCK"
for c in bash env git jq sha256sum shasum cmp sed date mkdir rmdir rm mv cat dirname basename tail grep awk sort tr cut ls wc mktemp chmod find sleep readlink; do
  [ -x "$(command -v "$c" 2>/dev/null)" ] && ln -sf "$(command -v "$c")" "$NOFLOCK/$c"
done
t "noflock PATH really lacks flock" 1 "" -- env PATH="$NOFLOCK" bash -c 'command -v flock'
t "update without flock uses the mkdir lock" 0 "all 3 update commands succeeded" -- env PATH="$NOFLOCK" "$SCRIPT" update
t "mkdir lock released on exit" 0 "" -- test ! -d "$F/snap/update.lock.d"
t "mkdir lock left no ownership token behind" 0 "" -- bash -c '[ -z "$(find "$1" -name token 2>/dev/null)" ]' _ "$F/snap"
# A LIVE holder must never have its lock stolen.
mkdir -p "$F/snap/update.lock.d"; echo $$ >"$F/snap/update.lock.d/pid"; : >"$STUB_LOG"
t "update refuses while a LIVE mkdir lock is held" 1 "another update in progress" -- env PATH="$NOFLOCK" "$SCRIPT" update
t "live mkdir lock calls no claude" 0 "" -- test ! -s "$STUB_LOG"
t "live mkdir lock was not stolen" 0 "" -- test -d "$F/snap/update.lock.d"
# A dead holder (hard-killed update) must be recovered, once.
DEADPID=$(bash -c 'echo $$'); echo "$DEADPID" >"$F/snap/update.lock.d/pid"; : >"$STUB_LOG"
t "update recovers a stale mkdir lock (dead pid)" 0 "lock: recovered stale lock \(pid $DEADPID\)" -- env PATH="$NOFLOCK" "$SCRIPT" update
t "recovered lock released on exit" 0 "" -- test ! -d "$F/snap/update.lock.d"
# A lock directory with no pid file yet is the normal look of a lock taken a
# moment ago — the winner writes its pid just after mkdir. Waiting for it is the
# difference between "contention" and "stale".
mkdir -p "$F/snap/update.lock.d"; : >"$STUB_LOG"
( sleep 0.5; echo $$ >"$F/snap/update.lock.d/pid" ) &
SLOWPID=$!
t "update waits for a late pid file, then refuses a live holder" 1 "another update in progress" -- env PATH="$NOFLOCK" "$SCRIPT" update
wait "$SLOWPID" 2>/dev/null
t "waiting for a late pid file called no claude" 0 "" -- test ! -s "$STUB_LOG"
t "the late-pid lock was not stolen" 0 "" -- test -d "$F/snap/update.lock.d"

# A LIVE holder is never displaced, however old the lock is.
echo $$ >"$F/snap/update.lock.d/pid"
python3 -c 'import os,sys,time; t=time.time()-3600; os.utime(sys.argv[1],(t,t))' "$F/snap/update.lock.d"
: >"$STUB_LOG"
t "an aged lock with a LIVE pid is still refused" 1 "another update in progress" -- env PATH="$NOFLOCK" "$SCRIPT" update
t "aged live lock calls no claude" 0 "" -- test ! -s "$STUB_LOG"
t "aged live lock was not stolen" 0 "" -- test -d "$F/snap/update.lock.d"

# Aged AND no pid file: nothing can prove a holder, so it is reclaimed.
rm -f "$F/snap/update.lock.d/pid"
python3 -c 'import os,sys,time; t=time.time()-3600; os.utime(sys.argv[1],(t,t))' "$F/snap/update.lock.d"
t "an aged lock dir with no pid file is reclaimed" 0 "lock: recovered stale lock \(pid unknown\)" -- env PATH="$NOFLOCK" "$SCRIPT" update
rm -rf "$F/snap/update.lock.d"

# A young lock dir with no pid file at all: still contention after the backoff.
mkdir -p "$F/snap/update.lock.d"; : >"$STUB_LOG"
t "a young lock dir with no pid file is NOT reclaimed" 1 "another update in progress" -- env PATH="$NOFLOCK" "$SCRIPT" update
t "young pid-less lock calls no claude" 0 "" -- test ! -s "$STUB_LOG"
rm -rf "$F/snap/update.lock.d"

# Two contenders that both read the same dead pid must not both reclaim: the
# loser would be deleting the WINNER's live lock. Reclaim is therefore a rename,
# which only one of them can win.
#
# This is NOT tested by racing two real processes. That was tried: the losing
# window is microseconds wide, a polling barrier resumes the two sides tens of
# milliseconds apart, and the resulting test passed against the BUGGY `rm -rf`
# build while flipping 1/0/1 across consecutive runs of the real suite. A test
# that is both flaky and unable to detect the bug it names is worse than none.
#
# Instead the losing side is driven directly: a shimmed `mv` fails the
# reclaim-rename exactly as it would for the contender that arrived second, and
# the assertion is the invariant that matters — it must refuse WITHOUT having
# removed the directory, which is precisely what the old `rm -rf` did do. This
# version does fail against that old build.
mkfix; S gate >/dev/null; S snapshot >/dev/null
MVSHIM="$F/mv-bin"; mkdir -p "$MVSHIM"
for c in bash env git jq sha256sum shasum cmp sed date mkdir rmdir rm cat dirname basename tail grep awk sort tr cut ls wc mktemp chmod find sleep readlink; do
  [ -x "$(command -v "$c" 2>/dev/null)" ] && ln -sf "$(command -v "$c")" "$MVSHIM/$c"
done
cat >"$MVSHIM/mv" <<EOF
#!/usr/bin/env bash
# Lose every reclaim-rename, as a contender that was beaten to it would.
case "\$*" in *update.lock.d*) exit 1 ;; esac
exec $(command -v mv) "\$@"
EOF
chmod +x "$MVSHIM/mv"
mkdir -p "$F/snap/update.lock.d"; echo "$(bash -c 'echo $$')" >"$F/snap/update.lock.d/pid"
echo marker >"$F/snap/update.lock.d/marker"; : >"$STUB_LOG"
t "lock reclaim: losing the rename refuses" 1 "another update in progress" -- env PATH="$MVSHIM" "$SCRIPT" update
t "lock reclaim: losing the rename deleted nothing" 0 "" -- test -f "$F/snap/update.lock.d/marker"
t "lock reclaim: losing the rename ran no claude" 0 "" -- test ! -s "$STUB_LOG"
rm -rf "$F/snap/update.lock.d"
t "lock race: no stale graveyard dir was left behind" 0 "" -- bash -c '[ -z "$(ls -d "$1"/update.lock.d.stale.* 2>/dev/null)" ]' _ "$F/snap"
t "lock race: the lock was released at the end" 0 "" -- test ! -d "$F/snap/update.lock.d"

# The ABA case a rename alone does NOT close, and which the old comment claimed
# was impossible. Staleness is judged at `kill -0`, not at the rename: if the
# other contender reclaims in between, it recreates the SAME pathname, so the
# late contender's mv succeeds — on a LIVE lock — and the old code deleted it.
#
# Driven through the same `mv` seam rather than by racing two processes, for the
# reasons above: the shim performs the first reclaimer's entire sequence (delete,
# recreate, write a live pid) and only then runs the real rename. That is exactly
# the interleaving, deterministically, every run.
mkfix; S gate >/dev/null; S snapshot >/dev/null
ABASHIM="$F/aba-bin"; mkdir -p "$ABASHIM"
for c in bash env git jq sha256sum shasum cmp sed date mkdir rmdir rm cat dirname basename tail grep awk sort tr cut ls wc mktemp chmod find sleep readlink; do
  [ -x "$(command -v "$c" 2>/dev/null)" ] && ln -sf "$(command -v "$c")" "$ABASHIM/$c"
done
cat >"$ABASHIM/mv" <<EOF
#!/usr/bin/env bash
# Once, on the reclaim-rename: be the contender that got there first and is
# already holding the recreated lock. \$\$ below is this test harness's pid,
# which is live — the late contender must treat it as somebody else's lock.
if [ ! -e "$F/aba.done" ] && [[ "\$*" == *update.lock.d* ]]; then
  : >"$F/aba.done"
  rm -rf "$F/snap/update.lock.d"
  mkdir "$F/snap/update.lock.d"
  echo "$$" >"$F/snap/update.lock.d/pid"
  echo live >"$F/snap/update.lock.d/marker"
fi
exec $(command -v mv) "\$@"
EOF
chmod +x "$ABASHIM/mv"
mkdir -p "$F/snap/update.lock.d"; echo "$(bash -c 'echo $$')" >"$F/snap/update.lock.d/pid"; : >"$STUB_LOG"
t "lock ABA: the late contender refuses" 1 "another update in progress" -- env PATH="$ABASHIM" "$SCRIPT" update
t "lock ABA: the shim actually fired" 0 "" -- test -e "$F/aba.done"
t "lock ABA: the live lock was put back, not deleted" 0 "" -- test -f "$F/snap/update.lock.d/marker"
t "lock ABA: the live holder's pid survived" 0 "" -- bash -c '[ "$(cat "$1/pid")" = "$2" ]' _ "$F/snap/update.lock.d" "$$"
t "lock ABA: the late contender ran no claude" 0 "" -- test ! -s "$STUB_LOG"
t "lock ABA: no graveyard dir was left behind" 0 "" -- bash -c '[ -z "$(ls -d "$1"/update.lock.d.stale.* 2>/dev/null)" ]' _ "$F/snap"
rm -rf "$F/snap/update.lock.d"

# The same ABA in the pid-LESS branch, which has no pid to compare: staleness
# there is judged purely by age, and "no pid file" is also exactly what another
# reclaimer's brand-new lock looks like in the instant between its `mkdir` and
# its `echo $$ >pid`. Only the age of the captured directory separates the two.
mkfix; S gate >/dev/null; S snapshot >/dev/null
ABASHIM2="$F/aba2-bin"; mkdir -p "$ABASHIM2"
for c in bash env git jq sha256sum shasum cmp sed date mkdir rmdir rm cat dirname basename tail grep awk sort tr cut ls wc mktemp chmod find sleep readlink; do
  [ -x "$(command -v "$c" 2>/dev/null)" ] && ln -sf "$(command -v "$c")" "$ABASHIM2/$c"
done
cat >"$ABASHIM2/mv" <<EOF
#!/usr/bin/env bash
# The first reclaimer, caught mid-reclaim: its lock exists and its pid file does
# not exist YET. Deleting this is deleting a live lock.
if [ ! -e "$F/aba2.done" ] && [[ "\$*" == *update.lock.d* ]]; then
  : >"$F/aba2.done"
  rm -rf "$F/snap/update.lock.d"
  mkdir "$F/snap/update.lock.d"
  echo live >"$F/snap/update.lock.d/marker"
fi
exec $(command -v mv) "\$@"
EOF
chmod +x "$ABASHIM2/mv"
mkdir -p "$F/snap/update.lock.d"
python3 -c 'import os,sys,time; t=time.time()-3600; os.utime(sys.argv[1],(t,t))' "$F/snap/update.lock.d"
: >"$STUB_LOG"
t "lock ABA (no pid): the late contender refuses" 1 "another update in progress" -- env PATH="$ABASHIM2" "$SCRIPT" update
t "lock ABA (no pid): the shim actually fired" 0 "" -- test -e "$F/aba2.done"
t "lock ABA (no pid): the fresh lock was put back, not deleted" 0 "" -- test -f "$F/snap/update.lock.d/marker"
t "lock ABA (no pid): the late contender ran no claude" 0 "" -- test ! -s "$STUB_LOG"
t "lock ABA (no pid): no graveyard dir was left behind" 0 "" -- bash -c '[ -z "$(ls -d "$1"/update.lock.d.stale.* 2>/dev/null)" ]' _ "$F/snap"
rm -rf "$F/snap/update.lock.d"

# The release side of the same problem, which the rename closes nothing of. A
# lock is identified by a PATHNAME, and a pathname can change hands: a displaced
# contender renames our live lock away, fails to restore it, and a third process
# finds the name free and creates its OWN lock there. `rm -rf "$LOCKDIR"` at
# release then deletes a live lock belonging to a process that never heard of
# us. So every claim writes an unforgeable ownership token and release removes
# the directory only while that token is still the one on disk.
#
# Driven through a seam, not through timing: the stub `claude` runs while the
# update holds the lock, and there it swaps the whole directory for another
# owner's. Deterministic, every run.
#
# Path 1: the EXIT trap, which is how `update` releases.
mkfix; S gate >/dev/null; S snapshot >/dev/null
HIJACK="$F/hijack-bin"; mkdir -p "$HIJACK"
for c in bash env git jq sha256sum shasum cmp sed date mkdir rmdir rm mv cat dirname basename tail grep awk sort tr cut ls wc mktemp chmod find sleep readlink realpath; do
  [ -x "$(command -v "$c" 2>/dev/null)" ] && ln -sf "$(command -v "$c")" "$HIJACK/$c"
done
export STUB_HIJACK_LOCK="$F/snap/update.lock.d"
t "lock handover: the update still succeeds" 0 "all 3 update commands succeeded" -- env PATH="$HIJACK" "$SCRIPT" update
t "lock handover: the hijack actually fired" 0 "" -- test -f "$F/snap/update.lock.d/marker"
t "lock handover: the other owner's token survived release" 0 "" -- bash -c '[ "$(cat "$1/token")" = "not-your-token" ]' _ "$F/snap/update.lock.d"
t "lock handover: release said what it refused to do" 0 "no longer carries this process's ownership token" -- bash -c 'rm -rf "$3/update.lock.d"; PATH="$2" STUB_HIJACK_LOCK="$3/update.lock.d" "$1" update 2>&1' _ "$SCRIPT" "$HIJACK" "$F/snap"
unset STUB_HIJACK_LOCK
rm -rf "$F/snap/update.lock.d"

# Path 2: release_lock itself, which is how `reconcile` releases when it took
# the lock on its own. The seam here is a shimmed `mv` — reconcile's first `mv`
# happens while the lock is held — and it hands the pathname to another owner
# exactly as the interleaving above would.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
HJ2="$F/hijack2-bin"; mkdir -p "$HJ2"
for c in bash env git jq sha256sum shasum cmp sed date mkdir rmdir rm cat dirname basename tail grep awk sort tr cut ls wc mktemp chmod find sleep readlink realpath; do
  [ -x "$(command -v "$c" 2>/dev/null)" ] && ln -sf "$(command -v "$c")" "$HJ2/$c"
done
cat >"$HJ2/mv" <<EOF
#!/usr/bin/env bash
if [ -d "$F/snap/update.lock.d" ] && [ ! -f "$F/snap/update.lock.d/marker" ]; then
  rm -rf "$F/snap/update.lock.d"
  mkdir "$F/snap/update.lock.d"
  echo "not-your-token" >"$F/snap/update.lock.d/token"
  echo "\$\$" >"$F/snap/update.lock.d/pid"
  echo live >"$F/snap/update.lock.d/marker"
fi
exec $(command -v mv) "\$@"
EOF
chmod +x "$HJ2/mv"
# One run, kept in a file: reconcile is idempotent, so a second run writes
# nothing, calls no `mv`, and could not fire the seam again.
t "lock handover (release_lock): reconcile still succeeds" 0 "^reconcile: ok" -- bash -c 'PATH="$2" "$1" reconcile >"$3" 2>&1; rc=$?; cat "$3"; exit $rc' _ "$SCRIPT" "$HJ2" "$F/recon.out"
t "lock handover (release_lock): the shim actually fired" 0 "" -- test -f "$F/snap/update.lock.d/marker"
t "lock handover (release_lock): the other owner's lock was not deleted" 0 "" -- bash -c '[ "$(cat "$1/token")" = "not-your-token" ]' _ "$F/snap/update.lock.d"
t "lock handover (release_lock): the refusal was reported" 0 "no longer carries this process's ownership token" -- cat "$F/recon.out"
rm -rf "$F/snap/update.lock.d"

# ---- verify
mkfix; S snapshot >/dev/null; bound
t "verify unchanged -> no-op PASS" 0 "alpha@cjs-plugins: PASS 1.0.0 — no-op \(version unchanged\)" -- S verify
t "verify prints the reload/restart reminder" 0 "run /reload-plugins .* or open a NEW session" -- S verify

mkfix
t "verify without snapshot" 1 "run 'ai-crew.sh snapshot' first" -- S verify

mkfix; S snapshot >/dev/null
t "verify with no _bound" 1 "no _bound: update was never run for this snapshot" -- S verify

mkfix; S snapshot >/dev/null; bound; G -C "$AI_CREW_CLONE" commit -q --allow-empty -m later
t "verify clone moved after bind" 1 "clone moved after bind; gate proved nothing about the installed code" -- S verify

mkfix; S snapshot >/dev/null; bound; touch "$AI_CREW_CLONE/stray"
t "verify dirty clone" 1 "verify: FAIL — clone modified after bind" -- S verify

for bad in '{}' '"oops"' '{"version":"1.0.0","installPath":"/x"}'; do
  mkfix; S snapshot >/dev/null; bound; jqi "$AI_CREW_SNAPSHOT" ".[\"alpha@cjs-plugins\"] = $bad"
  t "verify malformed snapshot entry $bad" 1 "^ai-crew: ERROR: .*invalid snapshot" -- S verify
done
mkfix; S snapshot >/dev/null; jqi "$AI_CREW_SNAPSHOT" '._bound = "x"'
t "verify malformed _bound" 1 "^ai-crew: ERROR: .*invalid snapshot" -- S verify

mkfix; S snapshot >/dev/null; bound; write_installed 0.9.0 "$F/cache/cjs-plugins/alpha/0.9.0" "$CSHA"; mkcache "$F/cache/cjs-plugins/alpha/0.9.0" 0.9.0
t "verify version mismatch" 1 "installed version '0.9.0' != manifest version '1.0.0'" -- S verify

mkfix; S snapshot >/dev/null; bound; write_installed 1.0.0 "$F/elsewhere/alpha/1.0.0" "$CSHA"
t "verify wrong installPath" 1 "installPath .* != " -- S verify

mkfix; S snapshot >/dev/null; bound; rm -rf "$F/cache/cjs-plugins/alpha/1.0.0"
t "verify installPath dir missing" 1 "does not exist" -- S verify

mkfix; S snapshot >/dev/null; bound; rm "$F/cache/cjs-plugins/alpha/1.0.0/.claude-plugin/plugin.json"
t "verify empty payload dir" 1 "payload manifest .* missing" -- S verify

mkfix; S snapshot >/dev/null; bound; mkcache "$F/cache/cjs-plugins/alpha/1.0.0" 0.0.1
t "verify payload manifest version mismatch" 1 "payload manifest version '0.0.1' != '1.0.0'" -- S verify

mkfix; S snapshot >/dev/null; bound; jqi "$AI_CREW_INSTALLED" 'del(.plugins["alpha@cjs-plugins"][0].gitCommitSha)'
t "verify missing gitCommitSha" 1 "alpha@cjs-plugins: FAIL — installed entry has no gitCommitSha" -- S verify

mkfix; S snapshot >/dev/null; bound; write_installed 1.0.0 "$F/cache/cjs-plugins/alpha/1.0.0" deadbeef
t "verify no-op with sha changed" 1 "sha changed without a version change" -- S verify

mkfix; write_installed 0.9.0 "$F/cache/cjs-plugins/alpha/0.9.0" "$CSHA"; S snapshot >/dev/null; bound
write_installed 1.0.0 "$F/cache/cjs-plugins/alpha/1.0.0" deadbeef
t "verify version changed + SHA mismatch" 1 "version changed 0.9.0 -> 1.0.0 but gitCommitSha 'deadbeef'" -- S verify

mkfix; write_installed 0.9.0 "$F/cache/cjs-plugins/alpha/0.9.0" "$CSHA"; S snapshot >/dev/null; bound
write_installed 1.0.0 "$F/cache/cjs-plugins/alpha/1.0.0" "$CSHA"
t "verify version changed + SHA match" 0 "alpha@cjs-plugins: PASS 0.9.0 -> 1.0.0" -- S verify

# Repo has an extra (unpushed) commit: the SHA rule must use the CLONE HEAD.
mkfix; write_installed 0.9.0 "$F/cache/cjs-plugins/alpha/0.9.0" "$CSHA"; S snapshot >/dev/null; bound
write_installed 1.0.0 "$F/cache/cjs-plugins/alpha/1.0.0" "$CSHA"
G -C "$AI_CREW_REPO" commit -q --allow-empty -m unpushed
t "verify SHA rule uses clone HEAD, not repo HEAD" 0 "alpha@cjs-plugins: PASS 0.9.0 -> 1.0.0" -- S verify

mkfix; S snapshot >/dev/null; bound; jqi "$AI_CREW_SNAPSHOT" '.["codex@openai-codex"].version = "1.0.5"'
t "verify vendor version changed + sha == vendor clone HEAD" 0 "codex@openai-codex: PASS 1.0.5 -> 1.0.6" -- S verify

mkfix; S snapshot >/dev/null; bound; jqi "$AI_CREW_SNAPSHOT" '.["codex@openai-codex"].version = "1.0.5"'
G -C "$AI_CREW_VENDOR_CLONE" commit -q --allow-empty -m newer
t "verify vendor version changed + sha != vendor clone HEAD" 1 "codex@openai-codex: FAIL — version changed" -- S verify

mkfix; jqi "$AI_CREW_INSTALLED" 'del(.plugins["beta@cjs-plugins"])'; S snapshot >/dev/null; bound
t "verify skips a catalogue plugin that is not installed" 0 "^skip: beta@cjs-plugins not installed" -- S verify
t "verify passes with a not-installed catalogue plugin" 0 "verify: PASS \(2 entries\)" -- S verify

mkfix; S snapshot >/dev/null; bound; jqi "$AI_CREW_SNAPSHOT" 'del(.["beta@cjs-plugins"])'
t "verify key missing from snapshot" 1 "no entry in snapshot" -- S verify

mkfix; S snapshot >/dev/null; bound; echo '{"name":"codex","version":"1.0.7"}' >"$AI_CREW_VENDOR_MANIFEST"
t "verify vendor stale" 1 "codex@openai-codex: FAIL — installed version '1.0.6' != manifest version '1.0.7'" -- S verify

mkfix; S snapshot >/dev/null; bound; echo '{corrupt' >"$AI_CREW_INSTALLED"
t "verify corrupt installed json" 1 "unparseable" -- S verify

# ---- selective install contract
# A marketplace may catalogue more plugins than the user installs. gate/bind
# cover the whole catalogue; snapshot/update/verify cover only what is installed.
mkfix
mkdir -p "$AI_CREW_REPO/gamma/.claude-plugin" "$AI_CREW_REPO/gamma/tests"
echo '{"name":"gamma","version":"3.0.0"}' >"$AI_CREW_REPO/gamma/.claude-plugin/plugin.json"
printf '#!/usr/bin/env bash\necho "1 passed, 0 failed"\n' >"$AI_CREW_REPO/gamma/tests/run.sh"
chmod +x "$AI_CREW_REPO/gamma/tests/run.sh"
jqi "$AI_CREW_REPO/.claude-plugin/marketplace.json" '.plugins += [{name:"gamma", source:"./gamma"}]'
G -C "$AI_CREW_REPO" add -A; G -C "$AI_CREW_REPO" commit -qm gamma
G -C "$AI_CREW_CLONE" pull -q origin main
mkcache "$F/cache/cjs-plugins/gamma/3.0.0" 3.0.0
jqi "$AI_CREW_INSTALLED" 'del(.plugins["beta@cjs-plugins"])'
t "selective: gate covers the whole catalogue (3 plugins)" 0 "gate: plugins=3 suites_run=2 ungated=1 failed=0" -- S gate
t "selective: status shows 2 catalogue plugins not installed" 0 "^status: 4 catalogued, 2 installed, 2 not installed" -- S status
S snapshot >/dev/null
t "selective: update touches only the installed plugins" 0 "all 2 update commands succeeded" -- S update
t "selective: update skipped the two uninstalled" 0 "" -- bash -c '[ "$(wc -l <"$1")" -eq 2 ]' _ "$STUB_LOG"
t "selective: verify passes with 2 installed" 0 "verify: PASS \(2 entries\)" -- S verify
# Installing one of them later is picked up with no config change.
jqi "$AI_CREW_INSTALLED" '.plugins["gamma@cjs-plugins"] = [{scope:"user",version:"3.0.0",installPath:$p,gitCommitSha:$s}]' \
  --arg p "$F/cache/cjs-plugins/gamma/3.0.0" --arg s "$(git -C "$AI_CREW_CLONE" rev-parse HEAD)"
S gate >/dev/null; S snapshot >/dev/null
t "selective: a newly installed plugin joins the update set" 0 "all 3 update commands succeeded" -- S update
t "selective: and verify covers it" 0 "verify: PASS \(3 entries\)" -- S verify

# ---- multi-marketplace
mkfix; mkmkt2 extra gamma 3.0.0
t "multi: status lists both marketplaces" 0 "^== marketplace extra " -- S status
t "multi: gate writes a receipt per marketplace" 0 "gate: receipt written: .*gate-receipt.extra.json" -- S gate
t "multi: default receipt keeps its historical name" 0 "" -- test -f "$AI_CREW_RECEIPT"
t "multi: per-name receipt records its marketplace" 0 "" -- jq -e '.marketplace == "extra" and .targets == ["gamma"]' "$F/snap/gate-receipt.extra.json"
t "multi: bind checks both" 0 "^bind: PASS" -- S bind
S snapshot >/dev/null
t "multi: snapshot writes one file per marketplace" 0 "" -- test -f "$F/snap/pre-update.extra.json"
t "multi: update covers both marketplaces" 0 "all 4 update commands succeeded" -- S update
t "multi: gamma@extra was updated" 0 "" -- grep -qx "plugin update gamma@extra" "$STUB_LOG"
t "multi: _bound recorded in the extra snapshot" 0 "" -- jq -e '._bound.boundHead | type == "string"' "$F/snap/pre-update.extra.json"
t "multi: verify covers both" 0 "verify: PASS \(4 entries\)" -- S verify

mkfix; mkmkt2 extra gamma 3.0.0; G -C "$F/extra" commit -q --allow-empty -m drift
t "multi: bind fails when only the second clone drifts" 1 "HEAD equal: FAIL" -- S bind

mkfix; mkmkt2 extra gamma 3.0.0
mkdir -p "$(dirname "$AI_CREW_KNOWN")"
echo '{"cjs-plugins":{"source":"x"}}' >"$AI_CREW_KNOWN"
t "multi: warns for a marketplace missing from known_marketplaces.json" 0 "WARNING: marketplace extra is configured but absent" -- S status
t "multi: the warning is not fatal" 0 "^bind: PASS" -- S bind

mkfix; export AI_CREW_MARKETPLACES="cjs-plugins=$AI_CREW_REPO;cjs-plugins=$AI_CREW_REPO"
t "multi: duplicate marketplace name is an error" 1 "listed twice" -- S status
mkfix; export AI_CREW_MARKETPLACES="cjs-plugins"
t "multi: malformed AI_CREW_MARKETPLACES entry" 1 "is not name=repo-path" -- S status

# The crew config file is the second source, after the env var.
mkfix; mkdir -p "$(dirname "$AI_CREW_CREW_CONFIG")"
jq -n --arg r "$AI_CREW_REPO" '{marketplaces:[{name:"cjs-plugins", repo:$r}]}' >"$AI_CREW_CREW_CONFIG"
t "config: marketplaces read from the crew config" 0 "^bind: PASS" -- S bind
echo '{"marketplaces":[]}' >"$AI_CREW_CREW_CONFIG"
t "config: empty marketplaces array is an error" 1 "non-empty array" -- S status
echo 'not json' >"$AI_CREW_CREW_CONFIG"
t "config: unparseable crew config is an error" 1 "unparseable" -- S status

# ---- reconcile
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
t "reconcile: fresh settings — env set" 0 "^settings: env CLAUDE_CODE_SUBAGENT_MODEL set" -- S reconcile
t "reconcile: env landed" 0 "" -- jq -e '.env.CLAUDE_CODE_SUBAGENT_MODEL == "sonnet"' "$AI_CREW_SETTINGS"
t "reconcile: no hook entries were written into settings" 0 "" -- jq -e '(.hooks // {}) == {}' "$AI_CREW_SETTINGS"
t "reconcile: second run is a no-op" 0 "^settings: unchanged" -- S reconcile
t "reconcile: second run took no backup" 0 "" -- bash -c '[ "$(ls "$(dirname "$1")" | grep -c "settings.json.bak.")" -eq 0 ]' _ "$AI_CREW_SETTINGS"

# Two registrations of the SAME basename — an absolute path that is a hook of
# the USER'S OWN (nothing proves it is ours) and an interpreter-prefixed ~ path
# that is a byte-identical copy of the shipped hook — plus an unrelated user
# hook. Only the proven one may be removed.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mkuserhook "$HOME/.claude/hooks/read-budget-gate.py" "$(ALPHA_PATH)" read-budget-gate.py
mksettings <<'EOF'
{
  "env": {"OTHER": "keep"},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "/somewhere/.claude/hooks/read-budget-gate.py"}]},
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/read-budget-gate.py"}, {"type": "command", "command": "/opt/hooks/terraform-guard.sh --strict"}]}
    ],
    "PostToolUse": [
      {"matcher": "Write", "hooks": [{"type": "command", "command": "/opt/hooks/sync-notes.sh"}]}
    ]
  }
}
EOF
cp "$AI_CREW_SETTINGS" "$F/settings.before"
t "reconcile: an unproven same-basename hook is KEPT, with the reason" 0 "AMBIGUOUS legacy hook PreToolUse/read-budget-gate.py \(/somewhere/.claude/hooks/read-budget-gate.py\) \(kept; basename matches a plugin hook but provenance is unproven" -- S reconcile
t "reconcile: the unproven entry is still in settings.json" 0 "" -- jq -e '[.. | objects | select(has("command")) | .command | select(. == "/somewhere/.claude/hooks/read-budget-gate.py")] | length == 1' "$AI_CREW_SETTINGS"
t "reconcile: removed the python3 ~ entry, whose content matches the shipped hook" 0 "" -- bash -c 'jq -e "[.. | objects | select(has(\"command\")) | .command | select(test(\"~/.claude/hooks/read-budget-gate\"))] | length == 0" "$1" >/dev/null' _ "$AI_CREW_SETTINGS"
t "reconcile: the group holding the unproven entry was NOT dropped" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "Edit|Write")] | length == 1' "$AI_CREW_SETTINGS"
t "reconcile: the unrelated Bash hook survives byte-for-byte" 0 "" -- bash -c '
  a=$(jq -S "[.hooks.PreToolUse[] | select(.matcher==\"Bash\") | .hooks[] | select(.command | test(\"terraform-guard\"))]" "$1")
  b=$(jq -S "[.hooks.PreToolUse[] | select(.matcher==\"Bash\") | .hooks[] | select(.command | test(\"terraform-guard\"))]" "$2")
  [ "$a" = "$b" ] && [ "$a" != "[]" ]' _ "$F/settings.before" "$AI_CREW_SETTINGS"
t "reconcile: the unrelated PostToolUse event survives" 0 "" -- bash -c '
  a=$(jq -S ".hooks.PostToolUse" "$1"); b=$(jq -S ".hooks.PostToolUse" "$2"); [ "$a" = "$b" ]' _ "$F/settings.before" "$AI_CREW_SETTINGS"
t "reconcile: the user's own env value is kept" 0 "" -- jq -e '.env.OTHER == "keep"' "$AI_CREW_SETTINGS"
t "reconcile: exactly one backup after the first write" 0 "" -- bash -c '[ "$(ls "$(dirname "$1")" | grep -c "settings.json.bak.")" -eq 1 ]' _ "$AI_CREW_SETTINGS"
t "reconcile: backup holds the pre-write bytes" 0 "" -- bash -c 'cmp -s "$1" "$(ls -d "$(dirname "$2")"/settings.json.bak.* | head -1)"' _ "$F/settings.before" "$AI_CREW_SETTINGS"
t "reconcile: idempotent — second run unchanged" 0 "^settings: unchanged" -- S reconcile
t "reconcile: idempotent — still exactly one backup" 0 "" -- bash -c '[ "$(ls "$(dirname "$1")" | grep -c "settings.json.bak.")" -eq 1 ]' _ "$AI_CREW_SETTINGS"

# A user's explicit env value is never overwritten.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mksettings <<'EOF'
{"env": {"CLAUDE_CODE_SUBAGENT_MODEL": "opus"}}
EOF
t "reconcile: keeps a user's existing env value" 0 "^settings: env CLAUDE_CODE_SUBAGENT_MODEL kept" -- S reconcile
t "reconcile: user env value untouched" 0 "" -- jq -e '.env.CLAUDE_CODE_SUBAGENT_MODEL == "opus"' "$AI_CREW_SETTINGS"

# --dry-run writes nothing at all.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mksettings <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "/x/plugins/cache/cjs-plugins/alpha/0.9.0/hooks/read-budget-gate.py"}]}]}}
EOF
cp "$AI_CREW_SETTINGS" "$F/settings.before"
t "reconcile --dry-run reports the write" 0 "^settings: would write" -- S reconcile --dry-run
t "reconcile --dry-run says DRY RUN" 0 "^reconcile: DRY RUN" -- S reconcile --dry-run
t "reconcile --dry-run wrote nothing" 0 "" -- cmp -s "$F/settings.before" "$AI_CREW_SETTINGS"
t "reconcile --dry-run took no backup" 0 "" -- bash -c '[ "$(ls "$(dirname "$1")" | grep -c "settings.json.bak.")" -eq 0 ]' _ "$AI_CREW_SETTINGS"

# Malformed settings.json: refuse, change nothing.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
mksettings <<'EOF'
{"hooks": {oops
EOF
cp "$AI_CREW_SETTINGS" "$F/settings.before"
t "reconcile: malformed settings.json -> nonzero" 1 "not valid JSON" -- S reconcile
t "reconcile: malformed settings.json not rewritten" 0 "" -- cmp -s "$F/settings.before" "$AI_CREW_SETTINGS"
t "reconcile: malformed settings.json took no backup" 0 "" -- bash -c '[ "$(ls "$(dirname "$1")" | grep -c "settings.json.bak.")" -eq 0 ]' _ "$AI_CREW_SETTINGS"

# An unparseable hooks manifest: we cannot know what to remove -> refuse.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; echo 'nope' >"$(ALPHA_PATH)/hooks/hooks.json"
t "reconcile: unparseable hooks.json -> nonzero" 1 "hook manifest does not parse" -- S reconcile
t "reconcile: unparseable hooks.json wrote nothing" 0 "" -- test ! -e "$AI_CREW_SETTINGS"

mkfix
t "reconcile: nothing declares fragments" 0 "no installed plugin declares" -- S reconcile

# Both writes must be staged in the TARGET's own directory and renamed there: a
# mv out of the mktemp work dir is a cross-filesystem copy+unlink, so a crash
# mid-copy would leave a truncated settings.json. A shimmed mktemp records every
# template it is asked for, which is where the staging location is proven.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mkmdfrag "$(ALPHA_PATH)" alpha body
mksettings <<'EOF'
{}
EOF
MKSHIM="$F/mkshim"; mkdir -p "$MKSHIM"
{ echo '#!/usr/bin/env bash'; echo "echo \"\$*\" >>\"$F/mktemp.log\""; echo "exec $(command -v mktemp) \"\$@\""; } >"$MKSHIM/mktemp"
chmod +x "$MKSHIM/mktemp"; : >"$F/mktemp.log"
t "reconcile with a shimmed mktemp still succeeds" 0 "^reconcile: ok" -- env PATH="$MKSHIM:$PATH" "$SCRIPT" reconcile
t "settings.json was staged beside the target, not in TMPDIR" 0 "" -- bash -c \
  '[ "$(grep -c "^$(dirname "$1")/\.ai-crew\.XXXXXX$" "$2")" -eq 2 ]' _ "$AI_CREW_SETTINGS" "$F/mktemp.log"
t "no staging file was left behind" 0 "" -- bash -c '[ -z "$(ls -A "$(dirname "$1")" | grep "^\.ai-crew\.")" ]' _ "$AI_CREW_SETTINGS"
t "the staged settings.json is complete and valid" 0 "" -- jq -e '.env.CLAUDE_CODE_SUBAGENT_MODEL == "sonnet"' "$AI_CREW_SETTINGS"

# ---- hook identity matching (what counts as a reference, and what may be removed)
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
mksettings <<'EOF'
{"hooks": {"PreToolUse": [
  {"matcher": "a", "hooks": [{"type": "command", "command": "python3 /custom/read-budget-gate.py"}]},
  {"matcher": "b", "hooks": [{"type": "command", "command": "echo read-budget-gate.py"}]},
  {"matcher": "c", "hooks": [{"type": "command", "command": "python3", "args": ["~/.claude/hooks/read-budget-gate.py"]}]},
  {"matcher": "d", "hooks": [{"type": "command", "command": "C:\\Users\\u\\.claude\\hooks\\read-budget-gate.py"}]}
]}}
EOF
mkuserhook "$HOME/.claude/hooks/read-budget-gate.py" "$(ALPHA_PATH)" read-budget-gate.py
t "identity: an out-of-tree path is reported AMBIGUOUS" 0 "AMBIGUOUS legacy hook PreToolUse/read-budget-gate.py \(python3 /custom/read-budget-gate.py\) \(kept; basename matches a plugin hook but provenance is unproven" -- S reconcile
t "identity: the ambiguous entry was KEPT" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "a")] | length == 1' "$AI_CREW_SETTINGS"
t "identity: a bare word is not a script reference" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "b")] | length == 1' "$AI_CREW_SETTINGS"
t "identity: exec-form args are scanned and removed" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "c")] | length == 0' "$AI_CREW_SETTINGS"
# A Windows path normalises to the right basename — but no file behind it can be
# read here, so it is reported and KEPT, never removed on the strength of the
# name alone.
t "identity: a Windows path is normalized and reported" 0 "AMBIGUOUS legacy hook PreToolUse/read-budget-gate.py" -- S reconcile
t "identity: the Windows path was kept, unproven" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "d")] | length == 1' "$AI_CREW_SETTINGS"

mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
mksettings <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "b", "hooks": [{"type": "command", "command": "echo read-budget-gate.py"}]}]}}
EOF
cp "$AI_CREW_SETTINGS" "$F/settings.before"
t "identity: a bare word is not even reported" 1 "" -- bash -c '"$1" reconcile | grep -qE "read-budget-gate"' _ "$SCRIPT"
# (jq re-serialises the file, so compare content, not bytes: the point is that
# the bare-word hook itself is not touched.)
t "identity: the bare-word hook is untouched" 0 "" -- bash -c '[ "$(jq -S . "$1")" = "$(jq -S . "$2")" ]' _ "$F/settings.before" "$AI_CREW_SETTINGS"

mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
mksettings <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "a", "hooks": [{"type": "command", "command": "python3 /custom/read-budget-gate.py"}]}]}}
EOF
t "identity: status reports the ambiguous entry" 0 "AMBIGUOUS legacy hook" -- S status
S snapshot >/dev/null; bound
t "identity: an ambiguous entry BLOCKS verify" 1 "verify: FAIL — AMBIGUOUS legacy hook" -- S verify
t "identity: verify names the acknowledgement remedy" 1 "acknowledge with .reconcile --accept-ambiguous 'PreToolUse/read-budget-gate.py=python3 /custom/read-budget-gate.py' --matcher 'a'." -- S verify
t "identity: an ack without the matcher does not cover a matched group" 0 "^ambiguous: acknowledged PreToolUse/read-budget-gate.py" -- S reconcile --accept-ambiguous "PreToolUse/read-budget-gate.py=python3 /custom/read-budget-gate.py"
t "identity: ... and verify still FAILS" 1 "verify: FAIL — AMBIGUOUS legacy hook" -- S verify
rm -f "$F/snap/ambiguous-ack.json"
t "identity: the ack is recorded" 0 "^ambiguous: acknowledged PreToolUse/read-budget-gate.py" -- S reconcile --accept-ambiguous "PreToolUse/read-budget-gate.py=python3 /custom/read-budget-gate.py" --matcher a
t "identity: verify passes once acknowledged" 0 "verify: PASS" -- S verify
t "identity: reconcile labels it acknowledged" 0 "^settings: ambiguous \(acknowledged\) PreToolUse/read-budget-gate.py" -- S reconcile
t "identity: the ack file holds the exact command" 0 "" -- jq -e '.[0].event == "PreToolUse" and .[0].base == "read-budget-gate.py" and .[0].command == "python3 /custom/read-budget-gate.py" and .[0].matcher == "a"' "$F/snap/ambiguous-ack.json"
# Editing the command invalidates the acknowledgement: the ack was for THAT
# command, not for the basename.
jqi "$AI_CREW_SETTINGS" '.hooks.PreToolUse[0].hooks[0].command = "python3 /custom/read-budget-gate.py --now"'
t "identity: a changed command invalidates the ack" 1 "verify: FAIL — AMBIGUOUS legacy hook" -- S verify
t "identity: a duplicate ack is not appended twice" 0 "" -- bash -c '"$1" reconcile --accept-ambiguous "PreToolUse/read-budget-gate.py=python3 /custom/read-budget-gate.py" --matcher a >/dev/null; [ "$(jq length "$2")" -eq 1 ]' _ "$SCRIPT" "$F/snap/ambiguous-ack.json"
t "identity: a malformed ack spec is rejected" 1 "not an acknowledgement" -- S reconcile --accept-ambiguous "no-equals-sign"
t "identity: an ack spec without an event is rejected" 1 "not an acknowledgement key" -- S reconcile --accept-ambiguous "nokey=cmd"

# Sitting in the configured config dir's hooks/ directory proves nothing: that
# is where a user keeps THEIR hooks too. The registration is AMBIGUOUS while the
# file behind it is a hook of the user's own, and removable the moment the file
# itself is shown to be the plugin's.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
PLAINCFG="$F/plaincfg"; mkdir -p "$PLAINCFG/hooks"
mkownhook "$PLAINCFG/hooks/read-budget-gate.py"
jq -n --arg p "$PLAINCFG/hooks/read-budget-gate.py" \
  '{hooks: {PreToolUse: [{matcher: "Edit|Write", hooks: [{type: "command", command: $p}]}]}}' \
  >"$AI_CREW_SETTINGS.tmp"; mkdir -p "$(dirname "$AI_CREW_SETTINGS")"; mv "$AI_CREW_SETTINGS.tmp" "$AI_CREW_SETTINGS"
cp "$AI_CREW_SETTINGS" "$F/settings.before"
t "config dir: a hook of the user's own under the config dir is KEPT" 0 "AMBIGUOUS legacy hook PreToolUse/read-budget-gate.py" -- env CLAUDE_CONFIG_DIR="$PLAINCFG" "$SCRIPT" reconcile
t "config dir: the user's own hook file was not touched" 0 "" -- grep -q "a gate of my own" "$PLAINCFG/hooks/read-budget-gate.py"
t "config dir: its registration survives" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "Edit|Write")] | length == 1' "$AI_CREW_SETTINGS"
mkuserhook "$PLAINCFG/hooks/read-budget-gate.py" "$(ALPHA_PATH)" read-budget-gate.py
t "config dir: the same entry IS removed once the file is the shipped hook" 0 "^settings: removed legacy hook PreToolUse/read-budget-gate.py" -- env CLAUDE_CONFIG_DIR="$PLAINCFG" "$SCRIPT" reconcile
t "config dir: it was actually removed" 0 "" -- jq -e '(.hooks // {}) == {}' "$AI_CREW_SETTINGS"
S snapshot >/dev/null; bound
t "config dir: verify passes after that removal" 0 "verify: PASS" -- env CLAUDE_CONFIG_DIR="$PLAINCFG" "$SCRIPT" verify
# A path that merely looks like the config dir's is AMBIGUOUS as well.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
jq -n --arg p "$F/plaincfg/hooks/read-budget-gate.py" \
  '{hooks: {PreToolUse: [{matcher: "Edit|Write", hooks: [{type: "command", command: $p}]}]}}' \
  >"$F/s.json"; mkdir -p "$(dirname "$AI_CREW_SETTINGS")"; cp "$F/s.json" "$AI_CREW_SETTINGS"
t "config dir: the same path is AMBIGUOUS when it is not the config dir" 0 "AMBIGUOUS legacy hook" -- S reconcile

# ---- provenance: what proves a settings entry registers OUR hook
# A basename collision is not proof. Removal needs one of three, and anything
# else is kept and reported — a user's own gate is not ours to delete.

# (1) the path resolves inside the installed plugin's own directory.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
jq -n --arg a "$(ALPHA_PATH)" '{hooks: {PreToolUse: [{matcher: "root", hooks:
  [{type: "command", command: ("python3 " + $a + "/hooks/read-budget-gate.py")}]}]}}' | mksettings
t "provenance: a path inside the plugin's install dir is removed" 0 "^settings: removed legacy hook PreToolUse/read-budget-gate.py" -- S reconcile
t "provenance: that entry is gone" 0 "" -- jq -e '(.hooks // {}) == {}' "$AI_CREW_SETTINGS"

# THE BUG A LITERAL PREFIX TEST HAS: spelled under the plugin root, but a
# COMPONENT of the path is a symlink pointing out of the plugin at a file the
# user owns. The spelling proves nothing — removing this entry would be removing
# somebody else's hook — so containment is judged after resolution, and only
# after. The genuine, unlinked sibling in the same settings file must still go,
# which is what keeps this from being fixed by disabling proof 1.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
mkownhook "$F/outside/hooks/read-budget-gate.py"
ln -s "$F/outside/hooks" "$(ALPHA_PATH)/linked"
jq -n --arg l "$(ALPHA_PATH)/linked/read-budget-gate.py" --arg r "$(ALPHA_PATH)/hooks/read-budget-gate.py" \
  '{hooks: {PreToolUse: [{matcher: "linked", hooks: [{type: "command", command: ("python3 " + $l)}]},
                         {matcher: "real",   hooks: [{type: "command", command: ("python3 " + $r)}]}]}}' | mksettings
t "provenance: a symlinked-out path under the plugin root is KEPT" 0 "AMBIGUOUS legacy hook PreToolUse/read-budget-gate.py .* \(kept; basename matches a plugin hook but provenance is unproven" -- S reconcile
t "provenance: the symlinked-out registration survives" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "linked")] | length == 1' "$AI_CREW_SETTINGS"
t "provenance: the user's file behind the symlink is untouched" 0 "" -- grep -q "a gate of my own" "$F/outside/hooks/read-budget-gate.py"
t "provenance: the genuine sibling under the plugin root was still removed" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "real")] | length == 0' "$AI_CREW_SETTINGS"

# A path that cannot be canonicalized at all (a component that does not exist)
# earns NO plugin-root proof, however it is spelled — and with no file behind it
# there is no hash either, so it is kept until a migration record says otherwise.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
jq -n --arg p "$(ALPHA_PATH)/no-such-dir/read-budget-gate.py" '{hooks: {PreToolUse: [{matcher: "unresolvable", hooks:
  [{type: "command", command: ("python3 " + $p)}]}]}}' | mksettings
t "provenance: an unresolvable path under the plugin root is KEPT" 0 "AMBIGUOUS legacy hook PreToolUse/read-budget-gate.py .* \(kept; basename matches a plugin hook but provenance is unproven" -- S reconcile
t "provenance: the unresolvable registration survives" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "unresolvable")] | length == 1' "$AI_CREW_SETTINGS"
t "provenance: a migration record is what removes it" 0 "^settings: removed legacy hook PreToolUse/read-budget-gate.py" -- bash -c '"$1" reconcile --record-migrated "$2" >/dev/null; "$1" reconcile' _ "$SCRIPT" "$(ALPHA_PATH)/no-such-dir/read-budget-gate.py"
t "provenance: it really is gone once recorded" 0 "" -- jq -e '(.hooks // {}) == {}' "$AI_CREW_SETTINGS"

# (2) outside it, but byte-identical to the shipped hook — the same code,
# copied or moved, so the duplicate registration provably changes nothing.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
mkuserhook "$F/elsewhere/read-budget-gate.py" "$(ALPHA_PATH)" read-budget-gate.py
jq -n --arg p "$F/elsewhere/read-budget-gate.py" '{hooks: {PreToolUse: [{matcher: "hash", hooks:
  [{type: "command", command: ("python3 " + $p)}]}]}}' | mksettings
t "provenance: a byte-identical copy outside the plugin dir is removed" 0 "^settings: removed legacy hook PreToolUse/read-budget-gate.py" -- S reconcile
t "provenance: that entry is gone too" 0 "" -- jq -e '(.hooks // {}) == {}' "$AI_CREW_SETTINGS"
t "provenance: the copy on disk was not deleted" 0 "" -- test -f "$F/elsewhere/read-budget-gate.py"

# THE BUG THIS CLOSES: same basename, different file. A user's own project gate
# at .claude/hooks/read-budget-gate.py is not a legacy registration of ours.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
mkownhook "$F/project/.claude/hooks/read-budget-gate.py"
jq -n --arg p "$F/project/.claude/hooks/read-budget-gate.py" '{hooks: {PreToolUse: [{matcher: "mine", hooks:
  [{type: "command", command: ("python3 " + $p)}]}]}}' | mksettings
cp "$AI_CREW_SETTINGS" "$F/settings.before"
t "provenance: a same-basename hook with different content is KEPT" 0 "AMBIGUOUS legacy hook PreToolUse/read-budget-gate.py .* \(kept; basename matches a plugin hook but provenance is unproven" -- S reconcile
t "provenance: its registration is untouched" 0 "" -- bash -c '[ "$(jq -S . "$1")" = "$(jq -S . "$2")" ]' _ "$F/settings.before" "$AI_CREW_SETTINGS"
t "provenance: the user's own hook file is untouched" 0 "" -- grep -q "a gate of my own" "$F/project/.claude/hooks/read-budget-gate.py"
S snapshot >/dev/null; bound
t "provenance: verify names the reason AND the remedy" 1 "provenance is unproven.*acknowledge with .reconcile --accept-ambiguous 'PreToolUse/read-budget-gate.py=" -- S verify
# Unproven provenance is the ONE case --record-migrated answers, and until it is
# named the message steers a stale cache path towards being silenced for ever.
t "provenance: the unproven message also names --record-migrated" 1 "record-migrated '$F/project/.claude/hooks/read-budget-gate.py'" -- S verify
t "provenance: acknowledging it clears verify without removing it" 0 "verify: PASS" -- bash -c '"$1" reconcile --accept-ambiguous "PreToolUse/read-budget-gate.py=python3 $2" --matcher mine >/dev/null; "$1" verify' _ "$SCRIPT" "$F/project/.claude/hooks/read-budget-gate.py"

# (3) an explicit migration record: the user states that this exact path was
# registered by this tool and may be removed.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
mkownhook "$F/opt/tools/read-budget-gate.py"
jq -n --arg p "$F/opt/tools/read-budget-gate.py" '{hooks: {PreToolUse: [{matcher: "mine", hooks:
  [{type: "command", command: ("python3 " + $p)}]}]}}' | mksettings
t "migrated: a relative path is refused" 1 "not a path this tool can have registered" -- S reconcile --record-migrated "relative/read-budget-gate.py"
t "migrated: the refusal created no record file at all" 1 "" -- test -f "$F/snap/migrated-hooks.json"
t "migrated: recording the path reports it" 0 "^migrated: recorded $F/opt/tools/read-budget-gate.py" -- S reconcile --record-migrated "$F/opt/tools/read-budget-gate.py"
t "migrated: the record holds that exact path" 0 "" -- jq -e --arg p "$F/opt/tools/read-budget-gate.py" '. == [$p]' "$F/snap/migrated-hooks.json"
t "migrated: reconcile now removes the registration" 0 "^settings: removed legacy hook PreToolUse/read-budget-gate.py" -- S reconcile
t "migrated: the file itself was not deleted" 0 "" -- test -f "$F/opt/tools/read-budget-gate.py"
t "migrated: a duplicate record is not appended twice" 0 "" -- bash -c '"$1" reconcile --record-migrated "$2" >/dev/null; [ "$(jq length "$3")" -eq 1 ]' _ "$SCRIPT" "$F/opt/tools/read-budget-gate.py" "$F/snap/migrated-hooks.json"
t "migrated: a record for a DIFFERENT path proves nothing" 0 "" -- bash -c '
  echo "[\"/some/other/read-budget-gate.py\"]" >"$3"
  jq -n --arg p "$2" "{hooks: {PreToolUse: [{matcher: \"mine\", hooks: [{type: \"command\", command: (\"python3 \" + \$p)}]}]}}" >"$4"
  "$1" reconcile | grep -q "AMBIGUOUS legacy hook PreToolUse/read-budget-gate.py"' \
  _ "$SCRIPT" "$F/opt/tools/read-budget-gate.py" "$F/snap/migrated-hooks.json" "$AI_CREW_SETTINGS"
t "migrated: a malformed record file is refused" 1 "not a JSON array of path strings" -- bash -c 'echo "{}" >"$2"; "$1" reconcile' _ "$SCRIPT" "$F/snap/migrated-hooks.json"
t "migrated: a record of a non-string is refused too" 1 "not a JSON array of path strings" -- bash -c 'echo "[7]" >"$2"; "$1" reconcile' _ "$SCRIPT" "$F/snap/migrated-hooks.json"

# "cannot hash" is NOT proof. An absent file, or one we may not read, leaves the
# entry unproven — and unproven is kept.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
jq -n --arg p "$F/gone/.claude/hooks/read-budget-gate.py" '{hooks: {PreToolUse: [{matcher: "gone", hooks:
  [{type: "command", command: ("python3 " + $p)}]}]}}' | mksettings
t "provenance: a path with no file behind it is kept" 0 "AMBIGUOUS legacy hook PreToolUse/read-budget-gate.py .* \(kept; basename matches a plugin hook but provenance is unproven" -- S reconcile
t "provenance: the absent-file entry survives" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "gone")] | length == 1' "$AI_CREW_SETTINGS"

mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
mkuserhook "$F/unreadable/.claude/hooks/read-budget-gate.py" "$(ALPHA_PATH)" read-budget-gate.py
jq -n --arg p "$F/unreadable/.claude/hooks/read-budget-gate.py" '{hooks: {PreToolUse: [{matcher: "noread", hooks:
  [{type: "command", command: ("python3 " + $p)}]}]}}' | mksettings
chmod 000 "$F/unreadable/.claude/hooks/read-budget-gate.py"
if [ "$(id -u)" -ne 0 ]; then
  # Content that WOULD match, behind a mode that forbids reading it: only the
  # failure to hash keeps this entry, which is the point.
  t "provenance: a file that cannot be read is kept, not removed" 0 "AMBIGUOUS legacy hook PreToolUse/read-budget-gate.py" -- S reconcile
  t "provenance: the unreadable entry survives" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "noread")] | length == 1' "$AI_CREW_SETTINGS"
else
  echo "skip provenance: unreadable-file case (running as root)"
fi
chmod 600 "$F/unreadable/.claude/hooks/read-budget-gate.py"

# Compound and traversing commands are never rewritten: their meaning would
# change, which is not what "remove a duplicate registration" means.
mkfix; mkhooks "$(ALPHA_PATH)" delegation-gate.py
mkuserhook "$HOME/.claude/hooks/delegation-gate.py" "$(ALPHA_PATH)" delegation-gate.py
mksettings <<'EOF'
{"hooks": {"PreToolUse": [
  {"matcher": "a", "hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/delegation-gate.py && /opt/audit.sh"}]},
  {"matcher": "b", "hooks": [{"type": "command", "command": "/opt/plugins/cache/../../custom/delegation-gate.py"}]},
  {"matcher": "c", "hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/delegation-gate.py --strict"}]},
  {"matcher": "d", "hooks": [{"type": "command", "command": "python3", "args": ["~/.claude/hooks/delegation-gate.py", "--strict"]}]},
  {"matcher": "e", "hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/delegation-gate.py; echo done"}]},
  {"matcher": "f", "hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/delegation-gate.py"}]}
]}}
EOF
cp "$AI_CREW_SETTINGS" "$F/settings.before"
t "compound: && keeps the entry" 0 "AMBIGUOUS legacy hook PreToolUse/delegation-gate.py \(python3 ~/.claude/hooks/delegation-gate.py && /opt/audit.sh\)" -- S reconcile
t "compound: the && entry is intact" 0 "" -- bash -c '[ "$(jq -S "[.hooks.PreToolUse[] | select(.matcher==\"a\")]" "$1")" = "$(jq -S "[.hooks.PreToolUse[] | select(.matcher==\"a\")]" "$2")" ]' _ "$F/settings.before" "$AI_CREW_SETTINGS"
t "compound: a /../ traversal is AMBIGUOUS, not a plugin path" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "b")] | length == 1' "$AI_CREW_SETTINGS"
t "compound: an extra flag keeps the entry" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "c")] | length == 1' "$AI_CREW_SETTINGS"
t "compound: exec-form with an extra arg keeps the entry" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "d")] | length == 1' "$AI_CREW_SETTINGS"
t "compound: a ; sequence keeps the entry" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "e")] | length == 1' "$AI_CREW_SETTINGS"
t "compound: the standalone invocation IS removed" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "f")] | length == 0' "$AI_CREW_SETTINGS"

# Shell syntax is never rewritten: a command that can do more than "run this
# script" is not a duplicate registration we can delete.
mkfix; mkhooks "$(ALPHA_PATH)" h.py
mkuserhook "$HOME/.claude/hooks/h.py" "$(ALPHA_PATH)" h.py
python3 - "$AI_CREW_SETTINGS" <<'PY'
import json, os, sys
p = sys.argv[1]
os.makedirs(os.path.dirname(p), exist_ok=True)
groups = [
    {"matcher": "newline", "hooks": [{"type": "command", "command": "bash\n~/.claude/hooks/h.py"}]},
    {"matcher": "cmdsub", "hooks": [{"type": "command", "command": "$(touch${IFS}/tmp/ai-crew-probe)/.claude/hooks/h.py"}]},
    {"matcher": "backtick", "hooks": [{"type": "command", "command": "`id`/.claude/hooks/h.py"}]},
    {"matcher": "midtilde", "hooks": [{"type": "command", "command": "/opt/~x/.claude/hooks/h.py"}]},
    {"matcher": "plain", "hooks": [{"type": "command", "command": "python3 ~/.claude/hooks/h.py"}]},
]
json.dump({"hooks": {"PreToolUse": groups}}, open(p, "w"))
PY
t "shell syntax: a newline keeps the entry" 0 "AMBIGUOUS legacy hook" -- S reconcile
t "shell syntax: the newline entry survived" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "newline")] | length == 1' "$AI_CREW_SETTINGS"
t "shell syntax: command substitution keeps the entry" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "cmdsub")] | length == 1' "$AI_CREW_SETTINGS"
t "shell syntax: a backtick keeps the entry" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "backtick")] | length == 1' "$AI_CREW_SETTINGS"
t "shell syntax: a non-leading ~ keeps the entry" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "midtilde")] | length == 1' "$AI_CREW_SETTINGS"
t "shell syntax: the plain invocation is still removed" 0 "" -- jq -e '[.hooks.PreToolUse[] | select(.matcher == "plain")] | length == 0' "$AI_CREW_SETTINGS"
t "shell syntax: no probe file was created" 0 "" -- test ! -e /tmp/ai-crew-probe

# ---- the acknowledgement list is never created by a read
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
export AI_CREW_DATA_DIR="$F/nodata" AI_CREW_AMBIGUOUS_ACK="$F/nodata/ambiguous-ack.json"
S snapshot >/dev/null; bound
t "ack: verify does not create the ack file" 0 "verify: PASS" -- S verify
t "ack: the data dir was not created by verify" 0 "" -- test ! -e "$F/nodata"
t "ack: --dry-run does not create the ack file" 0 "^reconcile: DRY RUN" -- S reconcile --dry-run
t "ack: the data dir was not created by --dry-run" 0 "" -- test ! -e "$F/nodata"
t "ack: status does not create the ack file" 0 "^reconcile: clean" -- S status
t "ack: the data dir was not created by status" 0 "" -- test ! -e "$F/nodata"

# An unwritable ack location must not break a run that has nothing to acknowledge.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
mkdir -p "$F/rodata"; chmod 500 "$F/rodata"
export AI_CREW_DATA_DIR="$F/rodata" AI_CREW_AMBIGUOUS_ACK="$F/rodata/ambiguous-ack.json"
S snapshot >/dev/null; bound
t "ack: verify succeeds with an unwritable ack location" 0 "verify: PASS" -- S verify
t "ack: reconcile succeeds with an unwritable ack location" 0 "^reconcile: ok" -- S reconcile
t "ack: nothing was written into the unwritable dir" 0 "" -- bash -c '[ -z "$(ls -A "$1")" ]' _ "$F/rodata"
chmod 700 "$F/rodata"
unset AI_CREW_DATA_DIR AI_CREW_AMBIGUOUS_ACK

# Exec-form identity is structural: two entries differing only in their args
# must not share one acknowledgement.
mkfix; mkhooks "$(ALPHA_PATH)" h.py
mksettings <<'EOF'
{"hooks": {"PreToolUse": [
  {"matcher": "one", "hooks": [{"type": "command", "command": "python3", "args": ["/custom/h.py", "--a"]}]},
  {"matcher": "two", "hooks": [{"type": "command", "command": "python3", "args": ["/custom/h.py", "--b"]}]}
]}}
EOF
S snapshot >/dev/null; bound
t "ack: an exec-form ambiguous entry blocks verify" 1 "verify: FAIL — AMBIGUOUS legacy hook" -- S verify
t "ack: the remedy carries the args array" 1 "acknowledge with .reconcile --accept-ambiguous 'PreToolUse/h.py=python3' --args .* --matcher 'one'." -- S verify
# --record-migrated is the remedy for unproven provenance ONLY: this entry is
# kept because it is not a standalone invocation, and recording a migration
# would not make it removable. Naming it here would be false advice.
t "ack: a non-standalone entry does NOT name --record-migrated" 0 "" -- bash -c '! "$1" verify 2>&1 | grep -q -- "--record-migrated"' _ "$SCRIPT"
S reconcile --accept-ambiguous "PreToolUse/h.py=python3" --args '["/custom/h.py","--a"]' --matcher one >/dev/null
t "ack: the --a entry is acknowledged" 0 "" -- jq -e '.[0].args == ["/custom/h.py", "--a"]' "$F/snap/ambiguous-ack.json"
t "ack: the --b entry is NOT covered by it" 1 "AMBIGUOUS legacy hook PreToolUse/h.py \(python3 /custom/h.py --b\)" -- S verify
S reconcile --accept-ambiguous "PreToolUse/h.py=python3" --args '["/custom/h.py","--b"]' --matcher two >/dev/null
t "ack: both acknowledged -> verify passes" 0 "verify: PASS" -- S verify
t "ack: two distinct acknowledgements were stored" 0 "" -- bash -c '[ "$(jq length "$1")" -eq 2 ]' _ "$F/snap/ambiguous-ack.json"
t "ack: --args must be a JSON array" 1 "--args must be a JSON array" -- S reconcile --accept-ambiguous "PreToolUse/h.py=python3" --args 'not-json'
t "ack: --matcher needs a value" 1 "--matcher needs a value" -- S reconcile --accept-ambiguous "PreToolUse/h.py=python3" --matcher

# The matcher is part of the identity too. Two groups under the same event with
# the SAME command and args are two registrations, and the acknowledgement for
# the one that was reviewed must not clear the one that was not.
mkfix; mkhooks "$(ALPHA_PATH)" h.py
mksettings <<'EOF'
{"hooks": {"PreToolUse": [
  {"matcher": "Edit", "hooks": [{"type": "command", "command": "python3 /custom/h.py"}]},
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "python3 /custom/h.py"}]}
]}}
EOF
S snapshot >/dev/null; bound
t "matcher: the remedy names the matcher" 1 "accept-ambiguous 'PreToolUse/h.py=python3 /custom/h.py' --matcher 'Edit'" -- S verify
S reconcile --accept-ambiguous "PreToolUse/h.py=python3 /custom/h.py" --matcher Edit >/dev/null
t "matcher: the Edit group is acknowledged" 0 "" -- jq -e '.[0].matcher == "Edit"' "$F/snap/ambiguous-ack.json"
t "matcher: the Bash group is still AMBIGUOUS" 1 "verify: FAIL — AMBIGUOUS legacy hook" -- S verify
t "matcher: and the remedy left is for Bash" 1 "--matcher 'Bash'" -- S verify
S reconcile --accept-ambiguous "PreToolUse/h.py=python3 /custom/h.py" --matcher Bash >/dev/null
t "matcher: both acknowledged -> verify passes" 0 "verify: PASS" -- S verify
t "matcher: two distinct acknowledgements were stored" 0 "" -- bash -c '[ "$(jq length "$1")" -eq 2 ]' _ "$F/snap/ambiguous-ack.json"

# An acknowledgement written before the matcher joined the identity has no
# `matcher` key at all: its matcher is UNKNOWN, not known-absent, so it matches
# nothing and expires. A matcher-less group is the broadest one there is — it
# fires on every tool call — and a stale ack quietly covering it is the failure
# mode worth avoiding. The remedy is reprinted and re-recording it is one line.
mkfix; mkhooks "$(ALPHA_PATH)" h.py
mksettings <<'EOF'
{"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "python3 /custom/h.py"}]}]}}
EOF
S snapshot >/dev/null; bound
echo '[{"event":"PreToolUse","base":"h.py","command":"python3 /custom/h.py","args":null}]' >"$F/snap/ambiguous-ack.json"
t "matcher: a pre-matcher ack (no matcher key) matches nothing" 1 "verify: FAIL — AMBIGUOUS legacy hook" -- S verify
t "matcher: a matcher-less group prints no --matcher in the remedy" 0 "" -- bash -c '! "$1" verify 2>&1 | grep -q -- "--matcher"' _ "$SCRIPT"
S reconcile --accept-ambiguous "PreToolUse/h.py=python3 /custom/h.py" >/dev/null
t "matcher: re-recording it with a null matcher passes" 0 "verify: PASS" -- S verify
t "matcher: the re-recorded ack carries an explicit null" 0 "" -- jq -e '.[1] | has("matcher") and .matcher == null' "$F/snap/ambiguous-ack.json"

# A matcher of "" is a DIFFERENT identity from no matcher at all.
mkfix; mkhooks "$(ALPHA_PATH)" h.py
mksettings <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "python3 /custom/h.py"}]}]}}
EOF
S snapshot >/dev/null; bound
S reconcile --accept-ambiguous "PreToolUse/h.py=python3 /custom/h.py" >/dev/null
t "matcher: a null ack does not cover an empty-string matcher" 1 "verify: FAIL — AMBIGUOUS legacy hook" -- S verify
S reconcile --accept-ambiguous "PreToolUse/h.py=python3 /custom/h.py" --matcher "" >/dev/null
t "matcher: --matcher '' covers it" 0 "verify: PASS" -- S verify

# ---- the printed remedy is EXECUTED, not just matched
# Asserting the TEXT of the remedy is what let an unquoted spec ship: every
# legacy form this tool matches is `python3 <path>`, which the shell splits, so
# the paste died — and died AFTER recording the first, mangled half. These
# tests paste the line the tool actually printed into a shell and require it to
# work.

# remedyline: the acknowledgement command as PRINTED, lifted from the first
# AMBIGUOUS verify failure — everything between the backticks.
remedyline() {
  "$SCRIPT" verify 2>&1 | sed -n 's/.*acknowledge with `\(reconcile [^`]*\)`.*/\1/p' | head -1
}
# roundtrip: paste every printed remedy back into a shell, one per failing
# entry, then report what verify says. `eval` performs exactly the word
# splitting and quote removal a POSIX shell does for a paste, so a spec that is
# not quoted properly fails here the way it fails for the user.
roundtrip() {
  local line n=0
  while [ "$n" -lt 8 ]; do
    line=$(remedyline)
    [ -n "$line" ] || break
    echo "REMEDY: $line"
    eval "\"\$SCRIPT\" $line" || { echo "PASTE FAILED (rc=$?)"; return 9; }
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { echo "no remedy was printed at all"; return 8; }
  "$SCRIPT" verify
}

# Four shapes in one settings file: a command containing a space (the reported
# bug), an exec-form entry with an --args array, a group with a matcher and one
# with none.
mkfix; mkhooks "$(ALPHA_PATH)" h.py
mksettings <<'EOF'
{"hooks": {"PreToolUse": [
  {"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "python3 /custom/h.py"}]},
  {"matcher": "one", "hooks": [{"type": "command", "command": "python3", "args": ["/custom/h.py", "--flag"]}]},
  {"hooks": [{"type": "command", "command": "python3 /custom/h.py --x"}]}
]}}
EOF
S snapshot >/dev/null; bound
t "roundtrip: verify FAILS before the remedies are pasted" 1 "verify: FAIL — AMBIGUOUS legacy hook" -- S verify
t "roundtrip: pasting every printed remedy clears verify" 0 "verify: PASS" -- roundtrip
t "roundtrip: three acknowledgements were recorded" 0 "" -- bash -c '[ "$(jq length "$1")" -eq 3 ]' _ "$F/snap/ambiguous-ack.json"
# The command was recorded WHOLE. Word-splitting used to store just "python3".
t "roundtrip: the spaced command was recorded intact" 0 "" -- jq -e 'any(.[]; .command == "python3 /custom/h.py" and .matcher == "Edit|Write")' "$F/snap/ambiguous-ack.json"
t "roundtrip: the exec-form args came back intact" 0 "" -- jq -e 'any(.[]; .command == "python3" and .args == ["/custom/h.py", "--flag"] and .matcher == "one")' "$F/snap/ambiguous-ack.json"
t "roundtrip: the matcher-less group recorded a null matcher" 0 "" -- jq -e 'any(.[]; .command == "python3 /custom/h.py --x" and has("matcher") and .matcher == null)' "$F/snap/ambiguous-ack.json"
t "roundtrip: no mangled half-spec was recorded" 1 "" -- jq -e 'any(.[]; .command == "python3" and .args == null)' "$F/snap/ambiguous-ack.json"

# A literal single quote in the command, the path and the matcher — the case
# the `'\''` idiom exists for.
mkfix; mkhooks "$(ALPHA_PATH)" h.py
mksettings <<'EOF'
{"hooks": {"PreToolUse": [
  {"matcher": "it's", "hooks": [{"type": "command", "command": "python3 /custom/o'brien/h.py"}]}
]}}
EOF
S snapshot >/dev/null; bound
t "roundtrip: a quoted value round-trips through the shell" 0 "verify: PASS" -- roundtrip
t "roundtrip: the quote survived verbatim" 0 "" -- jq -e '.[0].command == "python3 /custom/o'"'"'brien/h.py" and .[0].matcher == "it'"'"'s"' "$F/snap/ambiguous-ack.json"

# The --record-migrated remedy is pasteable too, and it REMOVES the entry
# rather than silencing it.
mkfix; mkhooks "$(ALPHA_PATH)" h.py
mkownhook "$F/o'dir/h.py"
jq -n --arg p "$F/o'dir/h.py" '{hooks: {PreToolUse: [{matcher: "mine", hooks:
  [{type: "command", command: ("python3 " + $p)}]}]}}' | mksettings
S snapshot >/dev/null; bound
t "roundtrip: the unproven message names --record-migrated" 1 "record-migrated '" -- S verify
t "roundtrip: pasting --record-migrated removes the registration" 0 "^settings: removed legacy hook PreToolUse/h.py" -- bash -c '
  line=$("$1" verify 2>&1 | sed -n "s/.*run \`\(reconcile --record-migrated [^\`]*\)\`.*/\1/p" | head -1)
  [ -n "$line" ] || { echo "no --record-migrated remedy printed"; exit 8; }
  echo "REMEDY: $line"
  eval "\"\$1\" $line" >/dev/null || { echo "PASTE FAILED"; exit 9; }
  "$1" reconcile' _ "$SCRIPT"
t "roundtrip: and verify passes with the entry gone" 0 "verify: PASS" -- S verify

# ---- an argument list is all-or-nothing
mkfix; mkhooks "$(ALPHA_PATH)" h.py
mksettings <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "a", "hooks": [{"type": "command", "command": "python3 /custom/h.py"}]}]}}
EOF
t "atomic: a bad spec anywhere in the list creates no ack file" 1 "not an acknowledgement" -- S reconcile \
  --accept-ambiguous "PreToolUse/h.py=python3 /custom/h.py" --matcher a "no-equals-sign"
t "atomic: ... and nothing was written" 1 "" -- test -f "$F/snap/ambiguous-ack.json"
S reconcile --accept-ambiguous "PreToolUse/h.py=python3 /custom/h.py" --matcher a >/dev/null
cp "$F/snap/ambiguous-ack.json" "$F/ack.before"
t "atomic: a later bad spec leaves the existing ack file byte-identical" 1 "not an acknowledgement key" -- S reconcile \
  --accept-ambiguous "PreToolUse/h.py=python3 /other/h.py" --matcher b "nokey=cmd"
t "atomic: ... the ack file is unchanged" 0 "" -- cmp -s "$F/ack.before" "$F/snap/ambiguous-ack.json"
t "atomic: ... and the first spec of that call was NOT recorded" 1 "" -- jq -e 'any(.[]; .command == "python3 /other/h.py")' "$F/snap/ambiguous-ack.json"
t "atomic: a whole valid list still records every spec" 0 "^ambiguous: acknowledged PreToolUse/h.py" -- S reconcile \
  --accept-ambiguous "PreToolUse/h.py=python3 /x/h.py" --matcher x \
                     "PreToolUse/h.py=python3 /y/h.py" --matcher y
t "atomic: both of them landed" 0 "" -- bash -c '[ "$(jq length "$1")" -eq 3 ]' _ "$F/snap/ambiguous-ack.json"

mkfix; mkhooks "$(ALPHA_PATH)" h.py
t "atomic: a bad path anywhere in the list creates no record file" 1 "not a path this tool can have registered" -- S reconcile \
  --record-migrated "$F/opt/h.py" "relative/h.py"
t "atomic: ... no migrated-hooks.json exists" 1 "" -- test -f "$F/snap/migrated-hooks.json"
S reconcile --record-migrated "$F/opt/h.py" >/dev/null
cp "$F/snap/migrated-hooks.json" "$F/mig.before"
t "atomic: a later bad path leaves the record byte-identical" 1 "not a path this tool can have registered" -- S reconcile \
  --record-migrated "$F/opt/other.py" "relative/h.py"
t "atomic: ... the record file is unchanged" 0 "" -- cmp -s "$F/mig.before" "$F/snap/migrated-hooks.json"

# ---- symlink chains
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mkdir -p "$(dirname "$AI_CREW_SETTINGS")" "$F/link1" "$F/real"
echo '{"env": {"KEEP": "1"}}' >"$F/real/settings.json"
ln -s "$F/real/settings.json" "$F/link1/settings.json"
ln -s "$F/link1/settings.json" "$AI_CREW_SETTINGS"
t "symlink chain: reconcile follows both hops" 0 "^settings: wrote" -- S reconcile
t "symlink chain: the first link is intact" 0 "" -- test -L "$AI_CREW_SETTINGS"
t "symlink chain: the second link is intact" 0 "" -- test -L "$F/link1/settings.json"
t "symlink chain: the final referent got the content" 0 "" -- jq -e '.env.CLAUDE_CODE_SUBAGENT_MODEL == "sonnet" and .env.KEEP == "1"' "$F/real/settings.json"
t "symlink chain: nothing was staged beside a link" 0 "" -- bash -c '[ -z "$(ls -A "$1" | grep "^\.ai-crew\.")" ]' _ "$F/link1"

mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mkdir -p "$(dirname "$AI_CREW_SETTINGS")"
ln -s "$F/cycle-b" "$F/cycle-a"; ln -s "$F/cycle-a" "$F/cycle-b"
t "symlink cycle: refused" 1 "symlink cycle" -- env AI_CREW_SETTINGS="$F/cycle-a" "$SCRIPT" reconcile
t "symlink cycle: no backup was taken" 0 "" -- bash -c '[ "$(ls "$1" | grep -c "cycle-a.bak.")" -eq 0 ]' _ "$F"

# ---- CLAUDE.md marker ORDER
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkmdfrag "$(ALPHA_PATH)" alpha body
mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mkdir -p "$(dirname "$AI_CREW_CLAUDE_MD")"
printf 'keep me
<!-- alpha:end -->
stuff
<!-- alpha:start -->
tail
' >"$AI_CREW_CLAUDE_MD"
cp "$AI_CREW_CLAUDE_MD" "$F/md.before"
t "markers: end before start is an error" 1 "comes before" -- S reconcile
t "markers: reversed pair left CLAUDE.md byte-identical" 0 "" -- cmp -s "$F/md.before" "$AI_CREW_CLAUDE_MD"
t "markers: reversed pair took no CLAUDE.md backup" 0 "" -- bash -c '[ "$(ls "$(dirname "$1")" | grep -c "CLAUDE.md.bak.")" -eq 0 ]' _ "$AI_CREW_CLAUDE_MD"
t "markers: reversed pair wrote no settings.json either" 0 "" -- test ! -e "$AI_CREW_SETTINGS"

# ---- symlinked targets keep their link
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mkdir -p "$(dirname "$AI_CREW_SETTINGS")" "$F/dotfiles"
echo '{"env": {"KEEP": "1"}}' >"$F/dotfiles/settings.json"
ln -s "$F/dotfiles/settings.json" "$AI_CREW_SETTINGS"
t "symlink: reconcile writes through the link" 0 "^settings: wrote" -- S reconcile
t "symlink: the link is still a link" 0 "" -- test -L "$AI_CREW_SETTINGS"
t "symlink: the referent got the content" 0 "" -- jq -e '.env.CLAUDE_CODE_SUBAGENT_MODEL == "sonnet" and .env.KEEP == "1"' "$F/dotfiles/settings.json"
t "symlink: no stray file replaced the link" 0 "" -- bash -c '[ -z "$(ls -A "$(dirname "$1")" | grep "^\.ai-crew\.")" ]' _ "$F/dotfiles/settings.json"

# ---- reconcile locking and read/write interleaving
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mksettings <<'EOF'
{"env": {"KEEP": "1"}}
EOF
mkdir -p "$F/snap"
t "reconcile refuses while the update lock is held" 1 "in progress" -- flock "$F/snap/update.lock" "$SCRIPT" reconcile
t "reconcile --dry-run does not need the lock" 0 "^reconcile: DRY RUN" -- flock "$F/snap/update.lock" "$SCRIPT" reconcile --dry-run

# A shimmed jq edits settings.json at the very last read step, between the read
# the merge was computed from and the write.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mksettings <<'EOF'
{"env": {"KEEP": "1"}}
EOF
cp "$AI_CREW_SETTINGS" "$F/settings.before"
JQSHIM="$F/jqshim"; mkdir -p "$JQSHIM"
cat >"$JQSHIM/jq" <<EOF
#!/usr/bin/env bash
if [ "\$1" = ".settings" ]; then printf '{"env":{"KEEP":"1","RACED":"yes"}}\n' >"$AI_CREW_SETTINGS"; fi
exec $(command -v jq) "\$@"
EOF
chmod +x "$JQSHIM/jq"
t "reconcile detects an edit made under it" 1 "settings: changed underneath us — rerun" -- env PATH="$JQSHIM:$PATH" "$SCRIPT" reconcile
t "the racing writer's content survived" 0 "" -- jq -e '.env.RACED == "yes"' "$AI_CREW_SETTINGS"
t "the raced run took no backup" 0 "" -- bash -c '[ "$(ls "$(dirname "$1")" | grep -c "settings.json.bak.")" -eq 0 ]' _ "$AI_CREW_SETTINGS"

# The staged write must not change the target's permissions: a settings.json
# the user keeps at 600 must still be 600 afterwards (mktemp makes 0600, so the
# reverse — a 644 file silently narrowed — matters just as much).
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mksettings <<'EOF'
{"env": {"KEEP": "1"}}
EOF
chmod 600 "$AI_CREW_SETTINGS"
t "reconcile rewrites a mode-600 settings.json" 0 "^settings: wrote" -- S reconcile
t "mode 600 is preserved across the staged write" 0 "" -- bash -c '[ "$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null)" = "600" ]' _ "$AI_CREW_SETTINGS"
t "the content was still written" 0 "" -- jq -e '.env.CLAUDE_CODE_SUBAGENT_MODEL == "sonnet" and .env.KEEP == "1"' "$AI_CREW_SETTINGS"

mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mksettings <<'EOF'
{"env": {"KEEP": "1"}}
EOF
chmod 644 "$AI_CREW_SETTINGS"
t "reconcile rewrites a mode-644 settings.json" 0 "^settings: wrote" -- S reconcile
t "mode 644 is not narrowed to mktemp's 600" 0 "" -- bash -c '[ "$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null)" = "644" ]' _ "$AI_CREW_SETTINGS"

mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
t "reconcile creates a new settings.json" 0 "^settings: wrote" -- S reconcile
t "a newly created settings.json is 644, not mktemp's 600" 0 "" -- bash -c '[ "$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null)" = "644" ]' _ "$AI_CREW_SETTINGS"

# macOS has no `stat -c`, so the second branch of the mode read is the one that
# runs there. Exercise it here with a stat that refuses -c and answers -f %Lp,
# the way BSD stat does — otherwise this branch would only ever be tested on a
# machine none of the CI runs use.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mksettings <<'EOF'
{"env": {"KEEP": "1"}}
EOF
chmod 600 "$AI_CREW_SETTINGS"
BSDSHIM="$F/bsdshim"; mkdir -p "$BSDSHIM"
cat >"$BSDSHIM/stat" <<'EOF'
#!/usr/bin/env bash
# BSD stat: no -c, and -f %Lp prints the octal mode. The mode is read with
# python3 rather than the host's `stat -c`, which does not exist on a real BSD
# host — the shim has to work on the platform it is imitating.
[ "$1" = "-c" ] && exit 1
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  exec python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$3"
fi
echo "stat shim: unexpected invocation: $*" >&2
exit 64
EOF
chmod +x "$BSDSHIM/stat"
t "BSD-style stat: reconcile still writes" 0 "^settings: wrote" -- env PATH="$BSDSHIM:$PATH" "$SCRIPT" reconcile
t "BSD-style stat: mode 600 still preserved" 0 "" -- bash -c '[ "$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null)" = "600" ]' _ "$AI_CREW_SETTINGS"

# The per-run work dir must be created once and removed on exit. `d=$(tmpd)`
# would run in a subshell, leaking one directory per call.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mkmdfrag "$(ALPHA_PATH)" alpha body; mkdir -p "$F/tmpdir"
t "reconcile in a private TMPDIR succeeds" 0 "^reconcile: ok" -- env TMPDIR="$F/tmpdir" "$SCRIPT" reconcile
t "reconcile left no work dir behind" 0 "" -- bash -c '[ -z "$(ls -A "$1")" ]' _ "$F/tmpdir"
t "status leaves no work dir behind" 0 "" -- bash -c 'env TMPDIR="$1" "$2" status >/dev/null 2>&1; [ -z "$(ls -A "$1")" ]' _ "$F/tmpdir" "$SCRIPT"

# An unusable TMPDIR is a clean failure, never a partial write.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mksettings <<'EOF'
{"env": {"KEEP": "1"}}
EOF
cp "$AI_CREW_SETTINGS" "$F/settings.before"; mkdir -p "$F/rotmp"; chmod 500 "$F/rotmp"
t "reconcile with an unusable TMPDIR fails closed" 1 "" -- env TMPDIR="$F/rotmp" "$SCRIPT" reconcile
t "unusable TMPDIR left settings.json byte-identical" 0 "" -- cmp -s "$F/settings.before" "$AI_CREW_SETTINGS"
chmod 700 "$F/rotmp"

# The real-world manifest shape: an interpreter prefix with the path QUOTED, and
# a group with no matcher at all (UserPromptSubmit). Both must still resolve to
# the script basename, and an emptied matcher-less group must be dropped.
mkfix
mkdir -p "$(ALPHA_PATH)/hooks"
cat >"$(ALPHA_PATH)/hooks/hooks.json" <<'EOF'
{"hooks":{
  "PreToolUse":[{"matcher":"Agent|Task","hooks":[{"type":"command","command":"python3 \"${CLAUDE_PLUGIN_ROOT}/hooks/lane-model-gate.py\""}]}],
  "UserPromptSubmit":[{"hooks":[{"type":"command","command":"python3 \"${CLAUDE_PLUGIN_ROOT}/hooks/routing-table.py\""}]}]}}
EOF
jq -n --arg a "$(ALPHA_PATH)" '{hooks: {
  PreToolUse: [{matcher: "Agent|Task", hooks: [{type: "command", command: ("python3 \"" + $a + "/hooks/lane-model-gate.py\"")}]}],
  UserPromptSubmit: [{hooks: [{type: "command", command: ("python3 " + $a + "/hooks/routing-table.py")}]}],
  PostToolUse: [{matcher: "Write", hooks: [{type: "command", command: "/opt/hooks/mine.sh"}]}]}}' \
  | mksettings
t "reconcile: quoted interpreter path resolves to the basename" 0 "removed legacy hook PreToolUse/lane-model-gate.py" -- S reconcile
t "reconcile: a matcher-less group is matched too" 0 "" -- bash -c 'jq -e "(.hooks | has(\"UserPromptSubmit\")) | not" "$1" >/dev/null' _ "$AI_CREW_SETTINGS"
t "reconcile: the emptied PreToolUse event was dropped" 0 "" -- bash -c 'jq -e "(.hooks | has(\"PreToolUse\")) | not" "$1" >/dev/null' _ "$AI_CREW_SETTINGS"
t "reconcile: the user's own PostToolUse hook survives" 0 "" -- jq -e '.hooks.PostToolUse[0].hooks[0].command == "/opt/hooks/mine.sh"' "$AI_CREW_SETTINGS"

# ---- reconcile: CLAUDE.md marker block
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
mkmdfrag "$(ALPHA_PATH)" alpha "first body"
mkdir -p "$(dirname "$AI_CREW_CLAUDE_MD")"
printf 'user line one\nuser line two\n' >"$AI_CREW_CLAUDE_MD"
cp "$AI_CREW_CLAUDE_MD" "$F/md.before"
t "claude-md: appends when no markers are present" 0 "^claude-md: block alpha appended" -- S reconcile
t "claude-md: user content preserved byte-for-byte" 0 "" -- bash -c 'head -2 "$1" | cmp -s - "$2"' _ "$AI_CREW_CLAUDE_MD" "$F/md.before"
t "claude-md: blank line then the block" 0 "" -- bash -c '[ "$(sed -n 3p "$1")" = "" ] && [ "$(sed -n 4p "$1")" = "<!-- alpha:start -->" ]' _ "$AI_CREW_CLAUDE_MD"
t "claude-md: idempotent" 0 "^claude-md: block alpha unchanged" -- S reconcile
mkmdfrag "$(ALPHA_PATH)" alpha "second body"
cp "$AI_CREW_CLAUDE_MD" "$F/md.before2"
t "claude-md: replaces between the markers" 0 "^claude-md: block alpha replaced" -- S reconcile
t "claude-md: new body present, old gone" 0 "" -- bash -c 'grep -q "second body" "$1" && ! grep -q "first body" "$1"' _ "$AI_CREW_CLAUDE_MD"
t "claude-md: content before the block still byte-identical" 0 "" -- bash -c 'head -2 "$1" | cmp -s - "$2"' _ "$AI_CREW_CLAUDE_MD" "$F/md.before"
t "claude-md: exactly one marker pair" 0 "" -- bash -c '[ "$(grep -c "alpha:start" "$1")" -eq 1 ]' _ "$AI_CREW_CLAUDE_MD"

mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkmdfrag "$(ALPHA_PATH)" alpha body
t "claude-md: created when absent" 0 "^claude-md: block alpha appended" -- S reconcile
t "claude-md: the created file is the fragment" 0 "" -- cmp -s "$(ALPHA_PATH)/claude-md.fragment.md" "$AI_CREW_CLAUDE_MD"

mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkmdfrag "$(ALPHA_PATH)" alpha body
mkdir -p "$(dirname "$AI_CREW_CLAUDE_MD")"; printf 'x\n<!-- alpha:start -->\ny\n' >"$AI_CREW_CLAUDE_MD"
t "claude-md: an unbalanced marker pair is an error" 1 "expected exactly one" -- S reconcile

mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py
printf 'no markers here\n' >"$(ALPHA_PATH)/claude-md.fragment.md"
t "claude-md: a fragment without markers is an error" 1 "missing marker line" -- S reconcile

# ---- verify <-> reconcile
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mkuserhook "$HOME/.claude/hooks/read-budget-gate.py" "$(ALPHA_PATH)" read-budget-gate.py
mksettings <<'EOF'
{"env": {"CLAUDE_CODE_SUBAGENT_MODEL": "sonnet"},
 "hooks": {"PreToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "~/.claude/hooks/read-budget-gate.py"}]}]}}
EOF
S snapshot >/dev/null; bound
t "verify fails while a legacy hook entry survives" 1 "verify: FAIL — legacy hook entries present" -- S verify
S reconcile >/dev/null
t "verify passes after reconcile" 0 "verify: PASS \(3 entries\)" -- S verify

mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mksettings <<'EOF'
{"env": {"SOMETHING_ELSE": "1"}}
EOF
S snapshot >/dev/null; bound
t "verify fails on an unset fragment env var" 1 "verify: FAIL — env CLAUDE_CODE_SUBAGENT_MODEL is not set" -- S verify

mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; echo 'nope' >"$(ALPHA_PATH)/hooks/hooks.json"
S snapshot >/dev/null; bound
t "verify fails on an unparseable hooks manifest" 1 "verify: FAIL — .*does not parse" -- S verify

mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mkuserhook "$HOME/.claude/hooks/read-budget-gate.py" "$(ALPHA_PATH)" read-budget-gate.py
mksettings <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "~/.claude/hooks/read-budget-gate.py"}]}]}}
EOF
t "status: reports reconcile needed" 0 "^reconcile: needed" -- S status
t "status: names the legacy entry" 0 "legacy hook entries present" -- S status
S reconcile >/dev/null
t "status: reports reconcile clean afterwards" 0 "^reconcile: clean" -- S status

# verify is READ-ONLY: it reports and fails, it never repairs.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkmdfrag "$(ALPHA_PATH)" alpha body
S snapshot >/dev/null; bound
t "verify passes without touching the config" 0 "verify: PASS \(3 entries\)" -- S verify
t "verify wrote no CLAUDE.md" 0 "" -- test ! -e "$AI_CREW_CLAUDE_MD"
t "verify wrote no settings.json" 0 "" -- test ! -e "$AI_CREW_SETTINGS"

mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mkuserhook "$HOME/.claude/hooks/read-budget-gate.py" "$(ALPHA_PATH)" read-budget-gate.py
mksettings <<'EOF'
{"env": {"CLAUDE_CODE_SUBAGENT_MODEL": "sonnet"},
 "hooks": {"PreToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "~/.claude/hooks/read-budget-gate.py"}]}]}}
EOF
cp "$AI_CREW_SETTINGS" "$F/settings.before"; S snapshot >/dev/null; bound
t "failing verify still writes nothing" 1 "legacy hook entries present" -- S verify
t "failing verify left settings.json byte-identical" 0 "" -- cmp -s "$F/settings.before" "$AI_CREW_SETTINGS"
t "failing verify took no backup" 0 "" -- bash -c '[ "$(ls "$(dirname "$1")" | grep -c "settings.json.bak.")" -eq 0 ]' _ "$AI_CREW_SETTINGS"

# update is where the repair happens: verify (install checks) -> reconcile ->
# re-run the reconcile checks once.
mkfix; mkhooks "$(ALPHA_PATH)" read-budget-gate.py; mkenvfrag "$(ALPHA_PATH)" CLAUDE_CODE_SUBAGENT_MODEL sonnet
mkmdfrag "$(ALPHA_PATH)" alpha body
mkuserhook "$HOME/.claude/hooks/read-budget-gate.py" "$(ALPHA_PATH)" read-budget-gate.py
mksettings <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "~/.claude/hooks/read-budget-gate.py"}]}]}}
EOF
S gate >/dev/null; S snapshot >/dev/null
t "update verifies, then reconciles" 0 "^update: reconcile clean" -- S update
t "update removed the legacy entry" 0 "" -- bash -c 'jq -e "[.. | objects | select(has(\"command\")) | .command | select(test(\"read-budget-gate\"))] | length == 0" "$1" >/dev/null' _ "$AI_CREW_SETTINGS"
t "update set the fragment env var" 0 "" -- jq -e '.env.CLAUDE_CODE_SUBAGENT_MODEL == "sonnet"' "$AI_CREW_SETTINGS"
t "update wrote the CLAUDE.md block" 0 "" -- grep -q "alpha:start" "$AI_CREW_CLAUDE_MD"
t "verify passes after update reconciled" 0 "verify: PASS \(3 entries\)" -- S verify

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
