#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression tests for how the 'Publish Helm Charts' step handles an
# archive whose chart metadata cannot be read, and for the outputs it
# writes when the batch stops part-way.
#
# The step's own script is taken from action.yaml with yq (mikefarah
# v4) and run, as GitHub runs it, against a stub helm. The stub fails
# 'helm show chart', or reports no chart name, for the Nth archive the
# step reads, so the failing archive's position in the batch does not
# depend on the order find lists the files in.
#
# Usage: bash tests/publish-metadata.sh

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

step="$work/publish-step.sh"
yq -e '.runs.steps[] | select(.id == "publish") | .run' \
  "$repo_root/action.yaml" > "$step"

failures=0

mkdir -p "$work/stub" "$work/charts"
for chart in alpha beta gamma; do
  : > "$work/charts/$chart-0.1.0.tgz"
done

# 'helm show chart' logs each archive it is asked about, in order, and
# names the chart after the archive. STUB_SHOW_FAIL and STUB_SHOW_EMPTY
# pick the call (1-based) that exits non-zero or omits the name.
cat > "$work/stub/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  version) printf 'v4.3.1\n' ;;
  show)
    file=$3
    printf '%s\n' "$file" >> "$STUB_CALLS"
    call=$(wc -l < "$STUB_CALLS")
    if [ "$call" = "${STUB_SHOW_FAIL:-}" ]; then
      echo 'Error: file does not appear to be a gzipped archive' >&2
      exit 1
    fi
    if [ "$call" = "${STUB_SHOW_EMPTY:-}" ]; then
      printf 'version: 0.1.0\n'
      exit 0
    fi
    name=${file##*/}
    printf 'name: %s\nversion: 0.1.0\n' "${name%-0.1.0.tgz}"
    ;;
  push)
    name=${2##*/}
    name=${name%-0.1.0.tgz}
    digest=$(printf '%s' "$name" | sha256sum | cut -d' ' -f1)
    printf 'Pushed: %s/%s:0.1.0\n' "${3#oci://}" "$name"
    printf 'Digest: sha256:%s\n' "$digest"
    ;;
  *) exit 1 ;;
esac
EOF

# basename fails on its STUB_BASENAME_FAIL-th call from the step, to
# stand in for an unexpected error part-way through a batch.
cat > "$work/stub/basename" <<'EOF'
#!/usr/bin/env bash
printf 'x\n' >> "$STUB_BASENAME_CALLS"
call=$(wc -l < "$STUB_BASENAME_CALLS")
if [ "$call" = "${STUB_BASENAME_FAIL:-}" ]; then
  exit 1
fi
exec "$REAL_BASENAME" "$@"
EOF
# rm fails with status 7 when STUB_RM_FAIL is set, so the cleanup in
# the step's exit handler fails.
cat > "$work/stub/rm" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_RM_FAIL:-}" ]; then
  echo 'rm: cannot remove: Permission denied' >&2
  exit 7
fi
exec "$REAL_RM" "$@"
EOF
chmod +x "$work/stub/helm" "$work/stub/basename" "$work/stub/rm"

export STUB_CALLS="$work/calls" STUB_BASENAME_CALLS="$work/basename-calls"
REAL_BASENAME=$(command -v basename)
REAL_RM=$(command -v rm)
export REAL_BASENAME REAL_RM

# run_step <permit_fail> [VAR=value ...]
run_step() {
  local permit=$1
  shift
  : > "$work/output"
  : > "$work/summary"
  : > "$STUB_CALLS"
  : > "$STUB_BASENAME_CALLS"
  set +e
  env PATH="$work/stub:$PATH" \
    INPUTS_REGISTRY='registry.test' \
    INPUTS_ORGANISATION='org' \
    INPUTS_CHARTS_PATH="$work/charts" \
    INPUTS_PERMIT_FAIL="$permit" \
    GITHUB_OUTPUT="$work/output" \
    GITHUB_STEP_SUMMARY="$work/summary" \
    RUNNER_TEMP="$work" \
    "$@" \
    bash --noprofile --norc -eo pipefail "$step" > "$work/log" 2>&1
  status=$?
  set -e
}

output() {
  sed -n "s/^$1=//p" "$work/output"
}

check() {
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: expected '$3', got '$2'"
    sed 's/^/    /' "$work/log"
    failures=$((failures + 1))
  fi
}

# Charts named by the stub's show log, in the order the step read
# them; arguments are the 1-based calls to pick.
charts_at() {
  local n file name list=''
  for n in "$@"; do
    file=$(sed -n "${n}p" "$STUB_CALLS")
    name=$("$REAL_BASENAME" "$file")
    list="${list:+$list,}$name"
  done
  printf '%s' "$list"
}

refs_at() {
  local n file name digest list=''
  for n in "$@"; do
    file=$(sed -n "${n}p" "$STUB_CALLS")
    name=$("$REAL_BASENAME" "$file" .tgz)
    name=${name%-0.1.0}
    digest=$(printf '%s' "$name" | sha256sum | cut -d' ' -f1)
    list="${list:+$list,}registry.test/org/$name@sha256:$digest"
  done
  printf '%s' "$list"
}

# expect_one_failed <name> <failing call> <passing call> <passing call>
#   [VAR=value ...]
expect_one_failed() {
  local name=$1 bad=$2 good1=$3 good2=$4 permit expected_status
  shift 4
  for permit in true false; do
    expected_status=0
    [ "$permit" = 'true' ] || expected_status=1
    run_step "$permit" "$@"
    local label="$name (permit_fail=$permit)"
    check "$label: exit status" "$status" "$expected_status"
    check "$label: all archives read" "$(wc -l < "$STUB_CALLS")" 3
    check "$label: publication_count" "$(output publication_count)" 2
    check "$label: failed_count" "$(output failed_count)" 1
    check "$label: published_files" "$(output published_files)" \
      "$(charts_at "$good1" "$good2")"
    check "$label: published_refs" "$(output published_refs)" \
      "$(refs_at "$good1" "$good2")"
    check "$label: failed_files" "$(output failed_files)" \
      "$(charts_at "$bad")"
    check "$label: summary written" \
      "$(grep -c '^- \*\*Failed uploads:\*\* 1$' "$work/summary")" 1
  done
}

expect_one_failed 'unreadable archive first' 1 2 3 STUB_SHOW_FAIL=1
expect_one_failed 'unreadable archive between' 2 1 3 STUB_SHOW_FAIL=2
expect_one_failed 'unreadable archive last' 3 1 2 STUB_SHOW_FAIL=3
expect_one_failed 'empty chart name' 2 1 3 STUB_SHOW_EMPTY=2

run_step false
check 'all charts valid: exit status' "$status" 0
check 'all charts valid: publication_count' \
  "$(output publication_count)" 3
check 'all charts valid: failed_count' "$(output failed_count)" 0

# The third archive's metadata cannot be read, and recording it as
# failed hits an unexpected error: the two charts already pushed must
# still be reported, and the step must fail even with permit_fail.
for permit in true false; do
  label="unexpected error after two pushes (permit_fail=$permit)"
  run_step "$permit" STUB_SHOW_FAIL=3 STUB_BASENAME_FAIL=3
  check "$label: exit status" "$status" 1
  check "$label: publication_count" "$(output publication_count)" 2
  check "$label: published_files" "$(output published_files)" \
    "$(charts_at 1 2)"
  check "$label: published_refs" "$(output published_refs)" \
    "$(refs_at 1 2)"
  check "$label: failed_count" "$(output failed_count)" 0
  check "$label: failed_files" "$(output failed_files)" ''
  check "$label: summary reports the stop" \
    "$(grep -c 'stopped by an unexpected error' "$work/summary")" 1
done

# A cleanup failure in the exit handler must neither stop it before
# it reports nor replace the step's own exit status.
run_step false STUB_RM_FAIL=1
check 'cleanup fails after a clean batch: exit status' "$status" 0
check 'cleanup fails after a clean batch: publication_count' \
  "$(output publication_count)" 3

label='cleanup fails after an unexpected error'
run_step true STUB_SHOW_FAIL=3 STUB_BASENAME_FAIL=3 STUB_RM_FAIL=1
check "$label: exit status" "$status" 1
check "$label: publication_count" "$(output publication_count)" 2
check "$label: published_refs" "$(output published_refs)" \
  "$(refs_at 1 2)"
check "$label: summary reports the stop" \
  "$(grep -c 'stopped by an unexpected error' "$work/summary")" 1

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed ❌"
  exit 1
fi
echo 'All checks passed ✅'
