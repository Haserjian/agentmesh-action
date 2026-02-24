#!/usr/bin/env bash
set -uo pipefail
# NOTE: no set -e; comment posting is best-effort (fork PRs, token limits)

# post-comment.sh -- create or update sticky PR comment
# Inputs: GITHUB_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, COMMENT_BODY_FILE

# --- P2: preflight check for jq ---
if ! command -v jq &>/dev/null; then
  echo "::warning::jq not found. PR comment skipped. Runs on ubuntu-latest which includes jq."
  exit 0
fi

MARKER="<!-- agentmesh-provenance -->"
API_BASE="https://api.github.com/repos/${GITHUB_REPOSITORY}"

if [[ -z "${COMMENT_BODY_FILE:-}" || ! -f "${COMMENT_BODY_FILE:-}" ]]; then
  echo "No comment body file found, skipping PR comment."
  exit 0
fi

comment_body=$(cat "$COMMENT_BODY_FILE")

# --- P3: paginate comment search to find marker across all pages ---
existing_id=""
page=1
while true; do
  response=$(
    curl -s -w "\n%{http_code}" \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${API_BASE}/issues/${PR_NUMBER}/comments?per_page=100&page=${page}"
  )
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  # P1: if API call fails, warn and bail (fork PRs, bad token, etc.)
  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "::warning::Could not list PR comments (HTTP ${http_code}). Comment skipped."
    exit 0
  fi

  count=$(echo "$body" | jq 'length')
  match=$(echo "$body" | jq -r --arg marker "$MARKER" \
    '[.[] | select(.body | contains($marker))][0].id // empty')

  if [[ -n "$match" ]]; then
    existing_id="$match"
    break
  fi

  # No more pages
  if [[ "$count" -lt 100 ]]; then
    break
  fi
  page=$((page + 1))
done

# --- JSON-encode the body ---
payload=$(jq -n --arg body "$comment_body" '{"body": $body}')

# --- P1: wrap write calls in warn-and-continue ---
if [[ -n "$existing_id" ]]; then
  echo "Updating existing comment ${existing_id}"
  http_code=$(
    curl -s -o /dev/null -w "%{http_code}" \
      -X PATCH \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -d "$payload" \
      "${API_BASE}/issues/comments/${existing_id}"
  )
  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "::warning::Could not update PR comment (HTTP ${http_code}). Comment skipped."
    exit 0
  fi
else
  echo "Creating new comment on PR #${PR_NUMBER}"
  http_code=$(
    curl -s -o /dev/null -w "%{http_code}" \
      -X POST \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -d "$payload" \
      "${API_BASE}/issues/${PR_NUMBER}/comments"
  )
  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "::warning::Could not post PR comment (HTTP ${http_code}). Comment skipped."
    exit 0
  fi
fi

echo "PR comment posted."
