#!/usr/bin/env bash
set -euo pipefail

# check-provenance.sh -- parse git trailers, compute lineage coverage, optionally verify witnesses
# Inputs: GITHUB_BASE_SHA, GITHUB_HEAD_SHA, REQUIRE_TRAILERS, VERIFY_WITNESS, REQUIRE_WITNESS
# Outputs: writes to GITHUB_STEP_SUMMARY + GITHUB_OUTPUT

MARKER="<!-- agentmesh-provenance -->"
TRAILER_KEY="AgentMesh-Episode"

# --- Policy profile resolution ---
# Profiles set base defaults. Non-empty env vars override profile defaults.
# action.yml passes '' for unset inputs, so empty means "not provided" and falls
# through to the profile default (or false when no profile is set).
POLICY_PROFILE="${POLICY_PROFILE:-}"

_apply_profile() {
  case "${POLICY_PROFILE}" in
    strict)
      _p_rt="true"; _p_vw="true"; _p_rw="false" ;;
    enterprise)
      _p_rt="true"; _p_vw="true"; _p_rw="true" ;;
    baseline|*)
      _p_rt="false"; _p_vw="false"; _p_rw="false" ;;
  esac
}

_apply_profile
REQUIRE_TRAILERS="${REQUIRE_TRAILERS:-${_p_rt}}"
VERIFY_WITNESS="${VERIFY_WITNESS:-${_p_vw}}"
REQUIRE_WITNESS="${REQUIRE_WITNESS:-${_p_rw}}"

if [[ -n "${POLICY_PROFILE}" && ! "${POLICY_PROFILE}" =~ ^(baseline|strict|enterprise)$ ]]; then
  echo "::warning::Unknown policy-profile '${POLICY_PROFILE}', using baseline defaults"
fi

# Resolved profile label for proof artifact
if [[ -n "${POLICY_PROFILE}" ]]; then
  _resolved_profile="${POLICY_PROFILE}"
elif [[ "${REQUIRE_TRAILERS}" == "false" && "${VERIFY_WITNESS}" == "false" && "${REQUIRE_WITNESS}" == "false" ]]; then
  _resolved_profile="baseline"
else
  _resolved_profile="custom"
fi

if [[ "${REQUIRE_WITNESS}" == "true" && "${VERIFY_WITNESS}" != "true" ]]; then
  echo "::error::require-witness=true requires verify-witness=true"
  exit 1
fi

# --- Gather commits ---
commits=()
while IFS= read -r sha; do
  [[ -n "$sha" ]] && commits+=("$sha")
done < <(git log --format='%H' "${GITHUB_BASE_SHA}..${GITHUB_HEAD_SHA}" 2>/dev/null)

commits_total=${#commits[@]}

# --- Edge case: empty PR ---
if [[ $commits_total -eq 0 ]]; then
  echo "No commits in range ${GITHUB_BASE_SHA:0:7}..${GITHUB_HEAD_SHA:0:7}"

  {
    echo "commits-total=0"
    echo "commits-traced=0"
    echo "coverage-pct=0"
    echo "unique-episodes=0"
    echo "files-changed=0"
    echo "witness-present=0"
    echo "witness-verified=0"
    echo "witness-coverage-pct=0"
    echo "result=PASS"
    echo "badge-url=https://img.shields.io/badge/lineage-none-lightgrey"
  } >> "${GITHUB_OUTPUT:-/dev/null}"

  comment_file=$(mktemp)
  cat > "$comment_file" <<EOF
${MARKER}
### AgentMesh Lineage Check

**Lineage coverage: 0/0 commits (N/A)**

No commits found in PR range.
EOF
  echo "comment-body-file=${comment_file}" >> "${GITHUB_OUTPUT:-/dev/null}"
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$comment_file" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

# --- Extract trailers and build detail rows ---
commits_traced=0
witness_present=0
witness_verified=0
episodes_file=$(mktemp)
detail_rows=""
witness_rows=""

for sha in "${commits[@]}"; do
  short_sha="${sha:0:7}"
  msg=$(git log -1 --format='%s' "$sha")
  msg="${msg//|/\\|}"
  if [[ ${#msg} -gt 60 ]]; then
    msg="${msg:0:57}..."
  fi

  trailer=$(git log -1 --format='%(trailers:key='"$TRAILER_KEY"',valueonly)' "$sha" | head -1 | tr -d '[:space:]')
  if [[ -n "$trailer" ]]; then
    commits_traced=$((commits_traced + 1))
    echo "$trailer" >> "$episodes_file"
    detail_rows="${detail_rows}| \`${short_sha}\` | ${msg} | \`${trailer}\` |
"
  else
    detail_rows="${detail_rows}| \`${short_sha}\` | ${msg} | -- |
"
  fi

  if [[ "${VERIFY_WITNESS}" == "true" ]]; then
    sig_trailer=$(git log -1 --format='%(trailers:key=AgentMesh-Sig,valueonly)' "$sha" | head -1 | tr -d '[:space:]')
    w_trailer=$(git log -1 --format='%(trailers:key=AgentMesh-Witness,valueonly)' "$sha" | head -1 | tr -d '[:space:]')
    status="NO_WITNESS_TRAILER"

    # Presence requires the minimum complete pair (sig + witness hash).
    # Partial states are malformed and must not count as present/verified.
    if [[ -n "$sig_trailer" && -n "$w_trailer" ]]; then
      witness_present=$((witness_present + 1))
      set +e
      verify_out=$(agentmesh witness verify "$sha" 2>&1)
      verify_rc=$?
      set -e

      clean=$(printf "%s\n" "$verify_out" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
      parsed_status=$(printf "%s\n" "$clean" | head -1 | awk '{print $1}')

      if [[ "$parsed_status" == "VERIFIED" ]]; then
        status="VERIFIED"
        witness_verified=$((witness_verified + 1))
      else
        status="${parsed_status:-INVALID}"
        # If parser got nothing and command failed, surface explicit verifier error.
        if [[ -z "$parsed_status" && $verify_rc -ne 0 ]]; then
          status="VERIFY_ERROR"
        fi
      fi
    elif [[ -n "$sig_trailer" || -n "$w_trailer" ]]; then
      status="MALFORMED_WITNESS_TRAILERS"
    fi

    witness_rows="${witness_rows}| \`${short_sha}\` | ${status} |
"
  fi
done

unique_episodes=$(sort -u "$episodes_file" | grep -c . || true)
rm -f "$episodes_file"
files_changed=$(git diff --name-only "${GITHUB_BASE_SHA}..${GITHUB_HEAD_SHA}" | wc -l | tr -d '[:space:]')
coverage_pct=$((commits_traced * 100 / commits_total))

if [[ "${VERIFY_WITNESS}" == "true" ]]; then
  witness_coverage_pct=$((witness_verified * 100 / commits_total))
else
  witness_coverage_pct=0
fi

# --- Badge URL ---
if [[ $coverage_pct -eq 100 ]]; then
  badge_url="https://img.shields.io/badge/lineage-100%25-brightgreen"
elif [[ $coverage_pct -ge 80 ]]; then
  badge_url="https://img.shields.io/badge/lineage-${coverage_pct}%25-yellow"
elif [[ $coverage_pct -gt 0 ]]; then
  badge_url="https://img.shields.io/badge/lineage-${coverage_pct}%25-red"
else
  badge_url="https://img.shields.io/badge/lineage-none-lightgrey"
fi

# --- Result ---
result="PASS"
failure_reason=""

if [[ "$REQUIRE_TRAILERS" == "true" && $coverage_pct -lt 100 ]]; then
  result="FAIL"
  failure_reason="Lineage coverage ${coverage_pct}% < 100%"
fi

if [[ "${VERIFY_WITNESS}" == "true" && "${REQUIRE_WITNESS}" == "true" && $witness_coverage_pct -lt 100 ]]; then
  result="FAIL"
  if [[ -n "$failure_reason" ]]; then
    failure_reason="${failure_reason}; "
  fi
  failure_reason="${failure_reason}Witness coverage ${witness_coverage_pct}% < 100%"
fi

# --- Evidence fingerprint ---
# SHA256 of: sorted commit SHAs + "|" + sorted witness statuses + "|" + policy flags
_fp_shas=""
_fp_statuses=""
for sha in "${commits[@]}"; do
  _fp_shas="${_fp_shas}${sha}\n"
done
if [[ "${VERIFY_WITNESS}" == "true" && -n "$witness_rows" ]]; then
  _fp_statuses=$(printf "%s" "$witness_rows" | sed -n 's/^| `[^`]*` | \(.*\) |$/\1/p' | sort)
fi
_fp_policy="${REQUIRE_TRAILERS}:${VERIFY_WITNESS}:${REQUIRE_WITNESS}"
_fp_input=$(printf "%b" "$_fp_shas" | sort)
_fp_input="${_fp_input}|${_fp_statuses}|${_fp_policy}"

if command -v sha256sum &>/dev/null; then
  evidence_fingerprint=$(printf "%s" "$_fp_input" | sha256sum | awk '{print $1}')
elif command -v shasum &>/dev/null; then
  evidence_fingerprint=$(printf "%s" "$_fp_input" | shasum -a 256 | awk '{print $1}')
else
  evidence_fingerprint="unavailable"
fi

# --- Resolved policy label for comment ---
_policy_str=""
[[ "$REQUIRE_TRAILERS" == "true" ]] && _policy_str="require-trailers"
[[ "$VERIFY_WITNESS" == "true" ]] && _policy_str="${_policy_str:+${_policy_str}, }verify-witness"
[[ "$REQUIRE_WITNESS" == "true" ]] && _policy_str="${_policy_str:+${_policy_str}, }require-witness"
[[ -z "$_policy_str" ]] && _policy_str="none (advisory)"
[[ -n "${POLICY_PROFILE}" ]] && _policy_str="${_policy_str} (profile: ${POLICY_PROFILE})"
_fp_short="${evidence_fingerprint:0:16}"

# --- Build comment markdown ---
comment_file=$(mktemp)

if [[ $commits_traced -eq 0 ]]; then
  cat > "$comment_file" <<EOF
${MARKER}
### AgentMesh Lineage Check

**Lineage coverage: 0/${commits_total} commits (0%)**

No \`${TRAILER_KEY}:\` trailers found.
[Install AgentMesh](https://github.com/Haserjian/agentmesh) to enable commit lineage tracking.
EOF
else
  cat > "$comment_file" <<EOF
${MARKER}
### AgentMesh Lineage Check

**Lineage coverage: ${commits_traced}/${commits_total} commits (${coverage_pct}%)**
EOF

  if [[ "${VERIFY_WITNESS}" == "true" ]]; then
    cat >> "$comment_file" <<EOF
**Witness coverage: ${witness_verified}/${commits_total} commits (${witness_coverage_pct}%)**
EOF
  fi

  cat >> "$comment_file" <<EOF

| Metric | Value |
|--------|-------|
| Commits in PR | ${commits_total} |
| With episode trailer | ${commits_traced} |
| Lineage coverage | ${coverage_pct}% |
| Unique episodes | ${unique_episodes} |
| Files changed | ${files_changed} |
EOF

  if [[ "${VERIFY_WITNESS}" == "true" ]]; then
    cat >> "$comment_file" <<EOF
| Witness trailers present | ${witness_present} |
| Witness signatures verified | ${witness_verified} |
| Witness coverage | ${witness_coverage_pct}% |
EOF
  fi

  cat >> "$comment_file" <<EOF
| Policy | ${_policy_str} |
| Evidence fingerprint | \`${_fp_short}...\` |
EOF

  cat >> "$comment_file" <<EOF

<details>
<summary>Commit Details</summary>

| SHA | Message | Episode |
|-----|---------|---------|
${detail_rows}
</details>
EOF

  if [[ "${VERIFY_WITNESS}" == "true" ]]; then
    cat >> "$comment_file" <<EOF

<details>
<summary>Witness Verification Details</summary>

| SHA | Witness Status |
|-----|----------------|
${witness_rows}
</details>
EOF
  fi

  cat >> "$comment_file" <<EOF

> Checked by [agentmesh-action](https://github.com/Haserjian/agentmesh-action) | [What is lineage coverage?](https://github.com/Haserjian/agentmesh-action#what-is-lineage-coverage)
EOF
fi

# --- Remediation (appended to comment on FAIL) ---
if [[ "$result" == "FAIL" && "$commits_traced" -gt 0 ]]; then
  {
    echo ""
    echo "#### Remediation"
    echo ""
    if [[ $coverage_pct -lt 100 ]]; then
      echo "- **Missing trailers**: Use \`agentmesh commit -m '...'\` instead of \`git commit\` to add episode trailers."
    fi
    if [[ "${VERIFY_WITNESS}" == "true" && $witness_coverage_pct -lt 100 ]]; then
      if [[ $witness_present -lt $commits_total ]]; then
        echo "- **Missing witness**: Run \`agentmesh key generate\` then use \`agentmesh commit -m '...'\` to sign commits."
      fi
      if [[ $witness_verified -lt $witness_present ]]; then
        echo "- **Invalid signature**: Check your key with \`agentmesh key list\` and re-commit affected commits."
      fi
    fi
  } >> "$comment_file"
fi

# --- Proof artifact (agentmesh-proof.json) ---
proof_artifact=""
if ! command -v jq &>/dev/null; then
  echo "::warning::jq not found, skipping proof artifact generation"
else
_proof_dir="${RUNNER_TEMP:-/tmp}"
proof_artifact="${_proof_dir}/agentmesh-proof.json"
_action_version="${ACTION_VERSION:-unknown}"

# Build commits JSON array
_commits_json="[]"
for sha in "${commits[@]}"; do
  _c_msg=$(git log -1 --format='%s' "$sha")
  _c_trailer=$(git log -1 --format='%(trailers:key='"$TRAILER_KEY"',valueonly)' "$sha" | head -1 | tr -d '[:space:]')
  _c_episode="null"
  [[ -n "$_c_trailer" ]] && _c_episode="\"${_c_trailer}\""
  _c_wstatus="null"
  if [[ "${VERIFY_WITNESS}" == "true" ]]; then
    # Extract status for this commit from witness_rows
    _c_wstatus_raw=$(printf "%s" "$witness_rows" | grep "\`${sha:0:7}\`" | sed -n 's/^| `[^`]*` | \(.*\) |$/\1/p' | tr -d '[:space:]')
    [[ -n "$_c_wstatus_raw" ]] && _c_wstatus="\"${_c_wstatus_raw}\""
  fi
  _commits_json=$(printf "%s" "$_commits_json" | jq \
    --arg sha "$sha" \
    --arg msg "$_c_msg" \
    --argjson ep "$_c_episode" \
    --argjson ws "$_c_wstatus" \
    '. + [{"sha": $sha, "message": $msg, "episode_id": $ep, "witness_status": $ws}]')
done

# Build failure_reasons array
_fail_reasons="[]"
if [[ -n "$failure_reason" ]]; then
  IFS=';' read -ra _reasons <<< "$failure_reason"
  for _r in "${_reasons[@]}"; do
    _r_trimmed=$(printf "%s" "$_r" | sed 's/^ *//')
    _fail_reasons=$(printf "%s" "$_fail_reasons" | jq --arg r "$_r_trimmed" '. + [$r]')
  done
fi

jq -n \
  --arg sv "1" \
  --arg av "$_action_version" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg repo "${GITHUB_REPOSITORY:-local}" \
  --arg run_id "${GITHUB_RUN_ID:-0}" \
  --arg pr "${PR_NUMBER:-}" \
  --arg base "${GITHUB_BASE_SHA}" \
  --arg head "${GITHUB_HEAD_SHA}" \
  --argjson req_t "$([ "$REQUIRE_TRAILERS" = "true" ] && echo true || echo false)" \
  --argjson ver_w "$([ "$VERIFY_WITNESS" = "true" ] && echo true || echo false)" \
  --argjson req_w "$([ "$REQUIRE_WITNESS" = "true" ] && echo true || echo false)" \
  --arg profile "$_resolved_profile" \
  --argjson ct "$commits_total" \
  --argjson ctr "$commits_traced" \
  --argjson cpct "$coverage_pct" \
  --argjson ue "$unique_episodes" \
  --argjson fc "$files_changed" \
  --argjson wp "$witness_present" \
  --argjson wv "$witness_verified" \
  --argjson wcpct "$witness_coverage_pct" \
  --argjson commits "$_commits_json" \
  --arg res "$result" \
  --argjson reasons "$_fail_reasons" \
  --arg fp "$evidence_fingerprint" \
  '{
    schema_version: $sv,
    action_version: $av,
    timestamp: $ts,
    repository: $repo,
    workflow_run_id: $run_id,
    workflow_run_url: ("https://github.com/" + $repo + "/actions/runs/" + $run_id),
    pr_number: $pr,
    base_sha: $base,
    head_sha: $head,
    policy: {
      require_trailers: $req_t,
      verify_witness: $ver_w,
      require_witness: $req_w,
      profile: $profile
    },
    metrics: {
      commits_total: $ct,
      commits_traced: $ctr,
      coverage_pct: $cpct,
      unique_episodes: $ue,
      files_changed: $fc,
      witness_present: $wp,
      witness_verified: $wv,
      witness_coverage_pct: $wcpct
    },
    commits: $commits,
    result: $res,
    failure_reasons: $reasons,
    evidence_fingerprint: $fp
  }' > "$proof_artifact" 2>/dev/null || echo "::warning::Failed to generate proof artifact"
fi  # jq available

# --- Outputs ---
{
  echo "commits-total=${commits_total}"
  echo "commits-traced=${commits_traced}"
  echo "coverage-pct=${coverage_pct}"
  echo "unique-episodes=${unique_episodes}"
  echo "files-changed=${files_changed}"
  echo "witness-present=${witness_present}"
  echo "witness-verified=${witness_verified}"
  echo "witness-coverage-pct=${witness_coverage_pct}"
  echo "result=${result}"
  echo "badge-url=${badge_url}"
  echo "comment-body-file=${comment_file}"
  echo "proof-artifact-path=${proof_artifact}"
} >> "${GITHUB_OUTPUT:-/dev/null}"

[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$comment_file" >> "$GITHUB_STEP_SUMMARY"

echo "Lineage: ${commits_traced}/${commits_total} (${coverage_pct}%) | episodes: ${unique_episodes} | files: ${files_changed}"
if [[ "${VERIFY_WITNESS}" == "true" ]]; then
  echo "Witness: ${witness_verified}/${commits_total} (${witness_coverage_pct}%) | present: ${witness_present}"
fi
echo "Evidence fingerprint: ${evidence_fingerprint:0:16}..."

if [[ "$result" == "FAIL" ]]; then
  echo "::error::${failure_reason}"
  exit 1
fi
