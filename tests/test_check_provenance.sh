#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHECK_SCRIPT="${ACTION_ROOT}/scripts/check-provenance.sh"

_mkrepo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t.com
  git -C "$dir" config user.name T
  printf "init\n" > "${dir}/init.txt"
  git -C "$dir" add init.txt
  git -C "$dir" commit -q -m init
}

_write_stub_agentmesh() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "${bindir}/agentmesh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "witness" && "${2:-}" == "verify" ]]; then
  case "${AGENTMESH_STUB_MODE:-verified}" in
    verified)
      echo "VERIFIED  Signed by stub"
      exit 0
      ;;
    missing)
      # Simulates the CLI behavior that can still exit 0.
      echo "WITNESS_MISSING  Witness not found in sidecar"
      exit 0
      ;;
    notrailers)
      echo "NO_TRAILERS  No witness trailers found"
      exit 0
      ;;
    invalid)
      echo "SIGNATURE_INVALID  Ed25519 signature verification failed"
      exit 1
      ;;
    *)
      echo "UNKNOWN  unsupported mode"
      exit 2
      ;;
  esac
fi

echo "unexpected invocation" >&2
exit 2
EOF
  chmod +x "${bindir}/agentmesh"
}

_assert_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "ASSERT CONTAINS FAILED: '$needle' not found in $file"
    cat "$file"
    exit 1
  fi
}

test_partial_trailers_fail_strict() {
  local tmp
  tmp="$(mktemp -d)"
  local repo="${tmp}/repo"
  local bindir="${tmp}/bin"
  _mkrepo "$repo"
  _write_stub_agentmesh "$bindir"

  local base
  base="$(git -C "$repo" rev-parse HEAD)"
  printf "a\n" > "${repo}/a.txt"
  git -C "$repo" add a.txt
  git -C "$repo" commit -q -m $'partial trailers\n\nAgentMesh-Episode: ep_demo\nAgentMesh-Sig: fake_sig_only'
  local head
  head="$(git -C "$repo" rev-parse HEAD)"

  local out="${tmp}/out.txt"
  local outputs="${tmp}/outputs.txt"
  local summary="${tmp}/summary.md"

  set +e
  (
    cd "$repo"
    PATH="${bindir}:${PATH}" \
      AGENTMESH_STUB_MODE=notrailers \
      GITHUB_BASE_SHA="$base" \
      GITHUB_HEAD_SHA="$head" \
      VERIFY_WITNESS=true \
      REQUIRE_WITNESS=true \
      GITHUB_OUTPUT="$outputs" \
      GITHUB_STEP_SUMMARY="$summary" \
      bash "$CHECK_SCRIPT" >"$out" 2>&1
  )
  local rc=$?
  set -e

  [[ $rc -ne 0 ]] || { echo "expected strict failure for partial trailers"; cat "$out"; exit 1; }
  _assert_contains "$outputs" "witness-present=0"
  _assert_contains "$outputs" "witness-verified=0"
  _assert_contains "$outputs" "witness-coverage-pct=0"
  _assert_contains "$summary" "MALFORMED_WITNESS_TRAILERS"

  rm -rf "$tmp"
}

test_missing_witness_does_not_count_verified() {
  local tmp
  tmp="$(mktemp -d)"
  local repo="${tmp}/repo"
  local bindir="${tmp}/bin"
  _mkrepo "$repo"
  _write_stub_agentmesh "$bindir"

  local base
  base="$(git -C "$repo" rev-parse HEAD)"
  printf "b\n" > "${repo}/b.txt"
  git -C "$repo" add b.txt
  git -C "$repo" commit -q -m $'missing witness payload\n\nAgentMesh-Episode: ep_demo\nAgentMesh-Witness: sha256:deadbeef\nAgentMesh-Sig: fake_sig'
  local head
  head="$(git -C "$repo" rev-parse HEAD)"

  local out="${tmp}/out.txt"
  local outputs="${tmp}/outputs.txt"
  local summary="${tmp}/summary.md"

  set +e
  (
    cd "$repo"
    PATH="${bindir}:${PATH}" \
      AGENTMESH_STUB_MODE=missing \
      GITHUB_BASE_SHA="$base" \
      GITHUB_HEAD_SHA="$head" \
      VERIFY_WITNESS=true \
      REQUIRE_WITNESS=true \
      GITHUB_OUTPUT="$outputs" \
      GITHUB_STEP_SUMMARY="$summary" \
      bash "$CHECK_SCRIPT" >"$out" 2>&1
  )
  local rc=$?
  set -e

  [[ $rc -ne 0 ]] || { echo "expected strict failure for WITNESS_MISSING"; cat "$out"; exit 1; }
  _assert_contains "$outputs" "witness-present=1"
  _assert_contains "$outputs" "witness-verified=0"
  _assert_contains "$summary" "WITNESS_MISSING"

  rm -rf "$tmp"
}

test_verified_witness_passes_strict() {
  local tmp
  tmp="$(mktemp -d)"
  local repo="${tmp}/repo"
  local bindir="${tmp}/bin"
  _mkrepo "$repo"
  _write_stub_agentmesh "$bindir"

  local base
  base="$(git -C "$repo" rev-parse HEAD)"
  printf "c\n" > "${repo}/c.txt"
  git -C "$repo" add c.txt
  git -C "$repo" commit -q -m $'verified witness\n\nAgentMesh-Episode: ep_demo\nAgentMesh-Witness: sha256:deadbeef\nAgentMesh-Sig: fake_sig'
  local head
  head="$(git -C "$repo" rev-parse HEAD)"

  local out="${tmp}/out.txt"
  local outputs="${tmp}/outputs.txt"
  local summary="${tmp}/summary.md"

  (
    cd "$repo"
    PATH="${bindir}:${PATH}" \
      AGENTMESH_STUB_MODE=verified \
      GITHUB_BASE_SHA="$base" \
      GITHUB_HEAD_SHA="$head" \
      VERIFY_WITNESS=true \
      REQUIRE_WITNESS=true \
      GITHUB_OUTPUT="$outputs" \
      GITHUB_STEP_SUMMARY="$summary" \
      bash "$CHECK_SCRIPT" >"$out" 2>&1
  )

  _assert_contains "$outputs" "witness-present=1"
  _assert_contains "$outputs" "witness-verified=1"
  _assert_contains "$outputs" "witness-coverage-pct=100"
  _assert_contains "$summary" "VERIFIED"

  rm -rf "$tmp"
}

test_partial_trailers_fail_strict
test_missing_witness_does_not_count_verified
test_verified_witness_passes_strict

echo "ok: check-provenance regression tests passed"
