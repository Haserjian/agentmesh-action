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

test_proof_artifact_generated() {
  local tmp
  tmp="$(mktemp -d)"
  local repo="${tmp}/repo"
  local proof_dir="${tmp}/proof"
  mkdir -p "$proof_dir"
  _mkrepo "$repo"

  local base
  base="$(git -C "$repo" rev-parse HEAD)"
  printf "d\n" > "${repo}/d.txt"
  git -C "$repo" add d.txt
  git -C "$repo" commit -q -m $'proof test\n\nAgentMesh-Episode: ep_proof'
  local head
  head="$(git -C "$repo" rev-parse HEAD)"

  local out="${tmp}/out.txt"
  local outputs="${tmp}/outputs.txt"
  local summary="${tmp}/summary.md"

  (
    cd "$repo"
    GITHUB_BASE_SHA="$base" \
      GITHUB_HEAD_SHA="$head" \
      REQUIRE_TRAILERS=false \
      VERIFY_WITNESS=false \
      REQUIRE_WITNESS=false \
      GITHUB_OUTPUT="$outputs" \
      GITHUB_STEP_SUMMARY="$summary" \
      RUNNER_TEMP="$proof_dir" \
      bash "$CHECK_SCRIPT" >"$out" 2>&1
  )

  _assert_contains "$outputs" "proof-artifact-path="
  local artifact="${proof_dir}/agentmesh-proof.json"
  [[ -f "$artifact" ]] || { echo "proof artifact not generated at ${artifact}"; exit 1; }

  # Validate JSON structure
  local sv
  sv=$(jq -r '.schema_version' "$artifact")
  [[ "$sv" == "1" ]] || { echo "unexpected schema_version: ${sv}"; exit 1; }
  local res
  res=$(jq -r '.result' "$artifact")
  [[ "$res" == "PASS" ]] || { echo "unexpected result: ${res}"; exit 1; }
  local ct
  ct=$(jq '.metrics.commits_total' "$artifact")
  [[ "$ct" == "1" ]] || { echo "unexpected commits_total: ${ct}"; exit 1; }
  local fp
  fp=$(jq -r '.evidence_fingerprint' "$artifact")
  [[ "$fp" != "null" && "$fp" != "" && "$fp" != "unavailable" ]] || { echo "missing fingerprint: ${fp}"; exit 1; }

  rm -rf "$tmp"
}

test_proof_artifact_fingerprint_stable() {
  local tmp
  tmp="$(mktemp -d)"
  local repo="${tmp}/repo"
  _mkrepo "$repo"

  local base
  base="$(git -C "$repo" rev-parse HEAD)"
  printf "e\n" > "${repo}/e.txt"
  git -C "$repo" add e.txt
  git -C "$repo" commit -q -m $'fp test\n\nAgentMesh-Episode: ep_fp'
  local head
  head="$(git -C "$repo" rev-parse HEAD)"

  local proof1="${tmp}/proof1"
  local proof2="${tmp}/proof2"
  mkdir -p "$proof1" "$proof2"

  for dir in "$proof1" "$proof2"; do
    (
      cd "$repo"
      GITHUB_BASE_SHA="$base" \
        GITHUB_HEAD_SHA="$head" \
        REQUIRE_TRAILERS=false \
        VERIFY_WITNESS=false \
        REQUIRE_WITNESS=false \
        GITHUB_OUTPUT="${tmp}/outputs_tmp" \
        GITHUB_STEP_SUMMARY="${tmp}/summary_tmp" \
        RUNNER_TEMP="$dir" \
        bash "$CHECK_SCRIPT" >/dev/null 2>&1
    )
  done

  local fp1 fp2
  fp1=$(jq -r '.evidence_fingerprint' "${proof1}/agentmesh-proof.json")
  fp2=$(jq -r '.evidence_fingerprint' "${proof2}/agentmesh-proof.json")
  [[ "$fp1" == "$fp2" ]] || { echo "fingerprints differ: ${fp1} vs ${fp2}"; exit 1; }

  rm -rf "$tmp"
}

test_profile_strict_sets_flags() {
  local tmp
  tmp="$(mktemp -d)"
  local repo="${tmp}/repo"
  local bindir="${tmp}/bin"
  _mkrepo "$repo"
  _write_stub_agentmesh "$bindir"

  local base
  base="$(git -C "$repo" rev-parse HEAD)"
  printf "f\n" > "${repo}/f.txt"
  git -C "$repo" add f.txt
  git -C "$repo" commit -q -m $'strict test\n\nAgentMesh-Episode: ep_strict\nAgentMesh-Witness: sha256:deadbeef\nAgentMesh-Sig: fake_sig'
  local head
  head="$(git -C "$repo" rev-parse HEAD)"

  local out="${tmp}/out.txt"
  local outputs="${tmp}/outputs.txt"
  local summary="${tmp}/summary.md"
  local proof_dir="${tmp}/proof"
  mkdir -p "$proof_dir"

  (
    cd "$repo"
    PATH="${bindir}:${PATH}" \
      AGENTMESH_STUB_MODE=verified \
      GITHUB_BASE_SHA="$base" \
      GITHUB_HEAD_SHA="$head" \
      POLICY_PROFILE=strict \
      GITHUB_OUTPUT="$outputs" \
      GITHUB_STEP_SUMMARY="$summary" \
      RUNNER_TEMP="$proof_dir" \
      bash "$CHECK_SCRIPT" >"$out" 2>&1
  )

  # strict profile sets require-trailers=true, verify-witness=true, require-witness=false
  _assert_contains "$outputs" "result=PASS"
  _assert_contains "$outputs" "witness-verified=1"
  # proof artifact should record profile
  local profile
  profile=$(jq -r '.policy.profile' "${proof_dir}/agentmesh-proof.json")
  [[ "$profile" == "strict" ]] || { echo "unexpected profile: ${profile}"; exit 1; }
  local req_t
  req_t=$(jq '.policy.require_trailers' "${proof_dir}/agentmesh-proof.json")
  [[ "$req_t" == "true" ]] || { echo "strict profile did not set require_trailers: ${req_t}"; exit 1; }

  rm -rf "$tmp"
}

test_explicit_flag_overrides_profile() {
  local tmp
  tmp="$(mktemp -d)"
  local repo="${tmp}/repo"
  _mkrepo "$repo"

  local base
  base="$(git -C "$repo" rev-parse HEAD)"
  printf "g\n" > "${repo}/g.txt"
  git -C "$repo" add g.txt
  git -C "$repo" commit -q -m $'override test\n\nAgentMesh-Episode: ep_override'
  local head
  head="$(git -C "$repo" rev-parse HEAD)"

  local out="${tmp}/out.txt"
  local outputs="${tmp}/outputs.txt"
  local summary="${tmp}/summary.md"
  local proof_dir="${tmp}/proof"
  mkdir -p "$proof_dir"

  # strict profile would set REQUIRE_TRAILERS=true, but explicit env vars override it
  (
    cd "$repo"
    GITHUB_BASE_SHA="$base" \
      GITHUB_HEAD_SHA="$head" \
      POLICY_PROFILE=strict \
      REQUIRE_TRAILERS=false \
      VERIFY_WITNESS=false \
      REQUIRE_WITNESS=false \
      GITHUB_OUTPUT="$outputs" \
      GITHUB_STEP_SUMMARY="$summary" \
      RUNNER_TEMP="$proof_dir" \
      bash "$CHECK_SCRIPT" >"$out" 2>&1
  )

  # Even though profile is strict, explicit flags turned off the gates -> PASS
  _assert_contains "$outputs" "result=PASS"
  # proof artifact should still show strict profile but overridden flags
  local req_t
  req_t=$(jq '.policy.require_trailers' "${proof_dir}/agentmesh-proof.json")
  [[ "$req_t" == "false" ]] || { echo "override did not take effect: require_trailers=${req_t}"; exit 1; }

  rm -rf "$tmp"
}

test_partial_trailers_fail_strict
test_missing_witness_does_not_count_verified
test_verified_witness_passes_strict
test_proof_artifact_generated
test_proof_artifact_fingerprint_stable
test_profile_strict_sets_flags
test_explicit_flag_overrides_profile

echo "ok: check-provenance regression tests passed (7/7)"
