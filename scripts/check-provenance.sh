#!/usr/bin/env bash
set -euo pipefail

# check-provenance.sh -- parse git trailers, compute lineage coverage, optionally verify witnesses
# Inputs: GITHUB_BASE_SHA, GITHUB_HEAD_SHA, REQUIRE_TRAILERS, VERIFY_WITNESS, REQUIRE_WITNESS
# Outputs: writes to GITHUB_STEP_SUMMARY + GITHUB_OUTPUT

MARKER="<!-- agentmesh-provenance -->"
TRAILER_KEY="AgentMesh-Episode"
REQUIRE_TRAILERS="${REQUIRE_TRAILERS:-false}"
VERIFY_WITNESS="${VERIFY_WITNESS:-false}"
REQUIRE_WITNESS="${REQUIRE_WITNESS:-false}"

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

    if [[ -n "$sig_trailer" || -n "$w_trailer" ]]; then
      witness_present=$((witness_present + 1))
      set +e
      verify_out=$(agentmesh witness verify "$sha" 2>&1)
      verify_rc=$?
      set -e

      if [[ $verify_rc -eq 0 ]]; then
        status="VERIFIED"
        witness_verified=$((witness_verified + 1))
      else
        clean=$(printf "%s\n" "$verify_out" | sed -E 's/\x1B\[[0-9;]*[mK]//g')
        status=$(printf "%s\n" "$clean" | head -1 | awk '{print $1}')
        [[ -z "$status" ]] && status="INVALID"
      fi
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
} >> "${GITHUB_OUTPUT:-/dev/null}"

[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$comment_file" >> "$GITHUB_STEP_SUMMARY"

echo "Lineage: ${commits_traced}/${commits_total} (${coverage_pct}%) | episodes: ${unique_episodes} | files: ${files_changed}"
if [[ "${VERIFY_WITNESS}" == "true" ]]; then
  echo "Witness: ${witness_verified}/${commits_total} (${witness_coverage_pct}%) | present: ${witness_present}"
fi

if [[ "$result" == "FAIL" ]]; then
  echo "::error::${failure_reason}"
  exit 1
fi
