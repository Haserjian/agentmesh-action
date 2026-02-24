#!/usr/bin/env bash
set -euo pipefail

# check-provenance.sh -- parse git trailers, compute lineage coverage
# Inputs: GITHUB_BASE_SHA, GITHUB_HEAD_SHA, REQUIRE_TRAILERS
# Outputs: writes to GITHUB_STEP_SUMMARY + GITHUB_OUTPUT

MARKER="<!-- agentmesh-provenance -->"
TRAILER_KEY="AgentMesh-Episode"

# --- Gather commits ---
commits=()
while IFS= read -r sha; do
  [[ -n "$sha" ]] && commits+=("$sha")
done < <(git log --format='%H' "${GITHUB_BASE_SHA}..${GITHUB_HEAD_SHA}" 2>/dev/null)

commits_total=${#commits[@]}

# --- Edge case: empty PR ---
if [[ $commits_total -eq 0 ]]; then
  echo "No commits in range ${GITHUB_BASE_SHA:0:7}..${GITHUB_HEAD_SHA:0:7}"

  # Write outputs
  {
    echo "commits-total=0"
    echo "commits-traced=0"
    echo "coverage-pct=0"
    echo "unique-episodes=0"
    echo "files-changed=0"
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
episodes_file=$(mktemp)
detail_rows=""

for sha in "${commits[@]}"; do
  short_sha="${sha:0:7}"
  msg=$(git log -1 --format='%s' "$sha")
  # Truncate long messages
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
done

unique_episodes=$(sort -u "$episodes_file" | grep -c . || true)
rm -f "$episodes_file"
files_changed=$(git diff --name-only "${GITHUB_BASE_SHA}..${GITHUB_HEAD_SHA}" | wc -l | tr -d '[:space:]')
coverage_pct=$((commits_traced * 100 / commits_total))

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
if [[ "$REQUIRE_TRAILERS" == "true" && $coverage_pct -lt 100 ]]; then
  result="FAIL"
else
  result="PASS"
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

| Metric | Value |
|--------|-------|
| Commits in PR | ${commits_total} |
| With episode trailer | ${commits_traced} |
| Coverage | ${coverage_pct}% |
| Unique episodes | ${unique_episodes} |
| Files changed | ${files_changed} |

<details>
<summary>Commit Details</summary>

| SHA | Message | Episode |
|-----|---------|---------|
${detail_rows}
</details>

> Checked by [agentmesh-action](https://github.com/Haserjian/agentmesh-action) | [What is lineage coverage?](https://github.com/Haserjian/agentmesh-action#what-is-lineage-coverage)
EOF
fi

# --- Write outputs ---
{
  echo "commits-total=${commits_total}"
  echo "commits-traced=${commits_traced}"
  echo "coverage-pct=${coverage_pct}"
  echo "unique-episodes=${unique_episodes}"
  echo "files-changed=${files_changed}"
  echo "result=${result}"
  echo "badge-url=${badge_url}"
  echo "comment-body-file=${comment_file}"
} >> "${GITHUB_OUTPUT:-/dev/null}"

# --- Step summary ---
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$comment_file" >> "$GITHUB_STEP_SUMMARY"

# --- Console output ---
echo "Lineage: ${commits_traced}/${commits_total} (${coverage_pct}%) | episodes: ${unique_episodes} | files: ${files_changed} | ${result}"

# --- Exit code ---
if [[ "$result" == "FAIL" ]]; then
  echo "::error::Lineage coverage ${coverage_pct}% < 100%. Set require-trailers: false for advisory mode."
  exit 1
fi
