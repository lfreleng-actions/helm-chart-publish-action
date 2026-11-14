#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

# Regression tests for how the 'Publish Helm Charts' step reads the
# chart digest that helm push reports.
#
# The step's own script is taken from action.yaml with yq (mikefarah
# v4) and run, as GitHub runs it, against a stub helm that reproduces
# each major version's report stream (v3 writes Pushed: and Digest:
# to stderr, v4 to stdout) and plants sha256-shaped decoys on the
# other stream and around the report.
#
# Set HELM_TEST_REGISTRY to a plain-HTTP registry (for example
# localhost:5000 from 'docker run -p 5000:5000 registry:2') to also
# push a real chart through the installed helm, with decoys added by
# a wrapper, and compare the published digest with the one the
# registry reports for the manifest.
#
# Usage: bash tests/publish-digest.sh

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

step="$work/publish-step.sh"
yq -e '.runs.steps[] | select(.id == "publish") | .run' \
  "$repo_root/action.yaml" > "$step"

real="sha256:$(printf 'real' | sha256sum | cut -d' ' -f1)"
decoy="sha256:$(printf 'decoy' | sha256sum | cut -d' ' -f1)"
failures=0

mkdir -p "$work/stub" "$work/charts"
: > "$work/charts/demo-0.1.0.tgz"
cat > "$work/stub/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  version) printf '%s\n' "$STUB_VERSION" ;;
  show) printf 'name: demo\nversion: 0.1.0\n' ;;
  push)
    printf '%b' "${STUB_STDERR:-}" >&2
    printf '%b' "${STUB_STDOUT:-}"
    exit "${STUB_STATUS:-0}"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$work/stub/helm"

# run_step <helm-dir> <registry> <charts-path> <permit_fail>
run_step() {
  : > "$work/output"
  : > "$work/summary"
  set +e
  env PATH="$1:$PATH" \
    INPUTS_REGISTRY="$2" \
    INPUTS_ORGANISATION='org' \
    INPUTS_CHARTS_PATH="$3" \
    INPUTS_PERMIT_FAIL="$4" \
    GITHUB_OUTPUT="$work/output" \
    GITHUB_STEP_SUMMARY="$work/summary" \
    RUNNER_TEMP="$work" \
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

# expect_published <name> <ref>
expect_published() {
  run_step "$work/stub" 'registry.test' "$work/charts" false
  check "$1: exit status" "$status" 0
  check "$1: published_refs" "$(output published_refs)" "$2"
  check "$1: publication_count" "$(output publication_count)" 1
  check "$1: failed_count" "$(output failed_count)" 0
}

# expect_failed <name>: a push without a valid report is a failed
# publication, so permit_fail alone decides whether the step fails.
expect_failed() {
  local permit expected_status
  for permit in true false; do
    expected_status=0
    [ "$permit" = 'true' ] || expected_status=1
    run_step "$work/stub" 'registry.test' "$work/charts" "$permit"
    check "$1 (permit_fail=$permit): exit status" "$status" \
      "$expected_status"
    check "$1 (permit_fail=$permit): published_refs" \
      "$(output published_refs)" ''
    check "$1 (permit_fail=$permit): publication_count" \
      "$(output publication_count)" 0
    check "$1 (permit_fail=$permit): failed_count" \
      "$(output failed_count)" 1
  done
}

pushed='Pushed: registry.test/org/demo:0.1.0'
ref="registry.test/org/demo@$real"
upper="sha256:$(printf '%s' "${real#sha256:}" | tr 'a-f' 'A-F')"

export STUB_VERSION STUB_STDOUT STUB_STDERR STUB_STATUS=0

STUB_VERSION='v3.19.0'
STUB_STDOUT="Digest: $decoy\nnote: $decoy\n"
STUB_STDERR="debug: resolved $decoy\n$pushed\nDigest: $real\n"
expect_published 'helm v3 reads stderr, ignores decoys' "$ref"

STUB_VERSION='v4.3.1'
STUB_STDERR="Digest: $decoy\ndebug: resolved $decoy\n"
STUB_STDOUT="$pushed\nDigest: $real\n"
expect_published 'helm v4 reads stdout, ignores decoys' "$ref"

STUB_STDERR=''
STUB_STDOUT="Pushed: localhost:5000/org/demo:0.1.0\nDigest: $real\n"
expect_published 'registry port survives tag removal' \
  "localhost:5000/org/demo@$real"

STUB_STDOUT="$pushed\nnote: $real\n"
STUB_STDERR="Digest: $real\n"
expect_failed 'helm v4 with Digest: only on stderr'

STUB_VERSION='v3.19.0'
STUB_STDOUT="$pushed\nDigest: $real\n"
STUB_STDERR="debug: resolved $real\n"
expect_failed 'helm v3 with the report only on stdout'

STUB_VERSION='v4.3.1'
STUB_STDERR=''
STUB_STDOUT="$pushed\nDigest: $upper\n"
expect_failed 'upper-case digest'

STUB_STDOUT="$pushed\nDigest: ${real%?}\n"
expect_failed 'truncated digest'

STUB_STDOUT="$pushed\nDigest: $real-suffix\n"
expect_failed 'digest with trailing text'

STUB_STDOUT="Digest: $real\n"
expect_failed 'missing Pushed: line'

STUB_STDOUT="$pushed\nDigest: $real\n"
STUB_STATUS=1
expect_failed 'helm push exit status 1'
STUB_STATUS=0

if [ -n "${HELM_TEST_REGISTRY:-}" ]; then
  real_helm=$(command -v helm)
  helm_major=$("$real_helm" version --template '{{.Version}}' | \
    sed -nE 's/^v([0-9]+)\..*/\1/p')
  # A forged Digest: line goes on the stream helm does not report on;
  # free-text decoys go on both, ahead of helm's own output.
  if [ "$helm_major" = '3' ]; then
    forged_stream='stdout'
  else
    forged_stream='stderr'
  fi
  mkdir -p "$work/wrap" "$work/real-charts"
  cat > "$work/wrap/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = 'push' ]; then
  printf 'debug: resolved %s\n' "$DECOY" >&2
  printf 'note: %s\n' "$DECOY"
  if [ "$FORGED_STREAM" = 'stderr' ]; then
    printf 'Digest: %s\n' "$DECOY" >&2
  else
    printf 'Digest: %s\n' "$DECOY"
  fi
  exec "$REAL_HELM" "$@" --plain-http
fi
exec "$REAL_HELM" "$@"
EOF
  chmod +x "$work/wrap/helm"
  chart="digest-test-$$"
  "$real_helm" create "$work/$chart" > /dev/null
  "$real_helm" package "$work/$chart" -d "$work/real-charts" > /dev/null

  export REAL_HELM="$real_helm" DECOY="$decoy" FORGED_STREAM="$forged_stream"
  run_step "$work/wrap" "$HELM_TEST_REGISTRY" "$work/real-charts" false
  check "real helm v$helm_major push: exit status" "$status" 0
  registry_digest=$(curl -fsSI \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    "http://$HELM_TEST_REGISTRY/v2/org/$chart/manifests/0.1.0" | \
    tr -d '\r' | \
    awk -F': ' 'tolower($1) == "docker-content-digest" {print $2}')
  check "real helm v$helm_major push: registry reports a digest" \
    "${registry_digest:+set}" 'set'
  check "real helm v$helm_major push: published_refs" \
    "$(output published_refs)" \
    "$HELM_TEST_REGISTRY/org/$chart@$registry_digest"
else
  echo 'skip: real registry push (HELM_TEST_REGISTRY not set)'
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed ❌"
  exit 1
fi
echo 'All checks passed ✅'
