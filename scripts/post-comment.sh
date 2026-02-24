#!/usr/bin/env bash
set -euo pipefail

# post-comment.sh -- create or update sticky PR comment
# Inputs: GITHUB_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, COMMENT_BODY_FILE

MARKER="<!-- agentmesh-provenance -->"
API_BASE="https://api.github.com/repos/${GITHUB_REPOSITORY}"

if [[ -z "${COMMENT_BODY_FILE:-}" || ! -f "${COMMENT_BODY_FILE:-}" ]]; then
  echo "No comment body file found, skipping PR comment."
  exit 0
fi

comment_body=$(cat "$COMMENT_BODY_FILE")

# --- Find existing comment with marker ---
existing_id=$(
  curl -sf \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${API_BASE}/issues/${PR_NUMBER}/comments?per_page=100" \
  | jq -r --arg marker "$MARKER" \
    '[.[] | select(.body | contains($marker))][0].id // empty'
) || true

# --- JSON-encode the body ---
payload=$(jq -n --arg body "$comment_body" '{"body": $body}')

if [[ -n "$existing_id" ]]; then
  echo "Updating existing comment ${existing_id}"
  curl -sf \
    -X PATCH \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -d "$payload" \
    "${API_BASE}/issues/comments/${existing_id}" > /dev/null
else
  echo "Creating new comment on PR #${PR_NUMBER}"
  curl -sf \
    -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -d "$payload" \
    "${API_BASE}/issues/${PR_NUMBER}/comments" > /dev/null
fi

echo "PR comment posted."
