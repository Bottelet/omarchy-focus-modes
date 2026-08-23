#!/usr/bin/env bash
# Offline test suite for bottelet.focus-modes.
#
#   tests/run.sh        run everything
#
# Two halves:
#   1. helpers/focus-modes-hosts — run against a scratch hosts file (a copy of
#      the script is patched to drop the root check and retarget HOSTS; the
#      validation and marker logic under test is byte-identical).
#   2. Model.js — engine logic (mode model, journal, revert planning) via node.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN=$(dirname "$HERE")

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  [[ -n ${2:-} ]] && printf '       %s\n' "$2"
}

check() {
  local name=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then ok "$name"; else no "$name" "expected [$expected] got [$actual]"; fi
}

WORK=$(mktemp -d -t omarchy-focus-modes-tests-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Hermetic: the helper ends with a best-effort `resolvectl flush-caches`,
# which unprivileged would bounce off polkit — record instead of calling.
mkdir -p "$WORK/bin"
printf '#!/bin/bash\necho "$*" >> "%s/resolvectl.log"\n' "$WORK" > "$WORK/bin/resolvectl"
chmod +x "$WORK/bin/resolvectl"
export PATH="$WORK/bin:$PATH"

# ---------------------------------------------------------------- hosts helper

HOSTS="$WORK/hosts"
HELPER="$WORK/focus-modes-hosts"
# Patch: retarget /etc/hosts and neutralize the root gate. chown root fails as
# a user, so it is stubbed to true; everything else runs verbatim.
sed -e "s|^HOSTS=/etc/hosts|HOSTS=$HOSTS|" \
    -e "s|^\[\[ \${EUID} -eq 0 \]\]|true|" \
    -e "s|^chown root:root|true chown|" \
    "$PLUGIN/helpers/focus-modes-hosts" > "$HELPER"
chmod +x "$HELPER"

baseline() {
  cat > "$HOSTS" <<'EOF'
127.0.0.1 localhost
::1 localhost
127.0.1.1 mymachine.localdomain mymachine
EOF
}

run_helper() { "$HELPER" "$@" 2>"$WORK/stderr"; }

echo "== hosts helper: happy path =="
baseline
run_helper --set reddit.com Twitter.com && ok "--set exits 0" || no "--set exits 0" "$(cat "$WORK/stderr")"
grep -qx '0.0.0.0 reddit.com' "$HOSTS" && ok "domain blocked" || no "domain blocked"
grep -qx '0.0.0.0 www.reddit.com' "$HOSTS" && ok "www variant added" || no "www variant added"
grep -qx '0.0.0.0 twitter.com' "$HOSTS" && ok "uppercase lowercased" || no "uppercase lowercased"
check "original first line intact" "127.0.0.1 localhost" "$(head -1 "$HOSTS")"
check "one begin marker" "1" "$(grep -cxF '# >>> bottelet.focus-modes >>>' "$HOSTS")"

echo "== hosts helper: set replaces, clear removes =="
run_helper --set news.ycombinator.com && ok "second --set exits 0" || no "second --set exits 0"
grep -q 'reddit.com' "$HOSTS" && no "old block replaced" || ok "old block replaced"
check "single block after re-set" "1" "$(grep -cxF '# >>> bottelet.focus-modes >>>' "$HOSTS")"
run_helper --clear && ok "--clear exits 0" || no "--clear exits 0"
grep -q 'focus-modes' "$HOSTS" && no "markers gone after clear" || ok "markers gone after clear"
check "file equals baseline after clear" "$(baseline; cat "$HOSTS")" "$(cat "$HOSTS")"
run_helper --clear && ok "--clear idempotent" || no "--clear idempotent"

echo "== hosts helper: www dedupe =="
baseline
run_helper --set www.reddit.com reddit.com
check "no duplicate www entry" "1" "$(grep -cx '0.0.0.0 www.reddit.com' "$HOSTS")"

echo "== hosts helper: rejects =="
must_reject() {
  local name=$1; shift
  baseline
  if run_helper --set "$@"; then
    no "$name" "helper accepted: $*"
  else
    ok "$name"
  fi
  if grep -q 'focus-modes' "$HOSTS"; then no "$name leaves no block" ; else ok "$name leaves no block"; fi
}
must_reject "hosts-format injection" 'example.com 0.0.0.0 evil.marker'
must_reject "newline injection" $'example.com\n0.0.0.0 evil.marker'
must_reject "IPv4 address" '192.168.1.1'
must_reject "IPv6 address" '::1'
must_reject "localhost" 'localhost'
must_reject "sub.localhost" 'evil.localhost'
must_reject "mDNS .local" 'printer.local'
must_reject "own hostname" "$(uname -n | tr '[:upper:]' '[:lower:]')"
must_reject "bare TLD" 'com'
must_reject "leading dash label" '-bad.example.com'
must_reject "underscore" 'bad_host.example.com'
must_reject "comment smuggling" '#comment.example.com'
must_reject "path traversal ish" '../etc/passwd'
must_reject "empty string" ''
must_reject "overlong label" "$(printf 'a%.0s' {1..64}).example.com"

echo "== hosts helper: damaged markers refuse =="
baseline
echo '# >>> bottelet.focus-modes >>>' >> "$HOSTS"
before=$(cat "$HOSTS")
if run_helper --set example.com; then no "unbalanced markers refused"; else ok "unbalanced markers refused"; fi
check "damaged file untouched" "$before" "$(cat "$HOSTS")"

echo "== hosts helper: usage errors =="
baseline
run_helper --set && no "--set with no domains refused" || ok "--set with no domains refused"
run_helper --frobnicate && no "unknown mode refused" || ok "unknown mode refused"
run_helper --clear extra-arg && no "--clear with args refused" || ok "--clear with args refused"

# -------------------------------------------------------------------- Model.js

echo "== Model.js engine =="
if command -v node >/dev/null 2>&1; then
  node "$HERE/model.test.js" "$PLUGIN/Model.js" && MODEL_RC=0 || MODEL_RC=1
  # model.test.js prints its own ok/FAIL lines and exits nonzero on failure.
  if [[ $MODEL_RC -ne 0 ]]; then FAIL=$((FAIL + 1)); fi
else
  echo "  skip node not installed — Model.js tests skipped"
fi

echo
echo "passed $PASS, failed $FAIL"
[[ $FAIL -eq 0 ]]
