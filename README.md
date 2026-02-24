# agentmesh-action

Check lineage coverage of PR commits via [AgentMesh](https://github.com/Haserjian/agentmesh) episode trailers, with optional cryptographic witness verification.

![lineage](https://img.shields.io/badge/lineage-100%25-brightgreen)

## Usage

```yaml
# .github/workflows/lineage.yml
name: Lineage Check
on: [pull_request]

permissions:
  contents: read
  pull-requests: write

jobs:
  lineage:
    runs-on: ubuntu-latest
    steps:
      - uses: Haserjian/agentmesh-action@v1
```

## Inputs

| Input | Default | Description |
|-------|---------|-------------|
| `require-trailers` | `false` | Exit 1 when lineage coverage < 100% |
| `verify-witness` | `false` | Verify signed witness trailers via `agentmesh witness verify` |
| `require-witness` | `false` | Exit 1 when witness coverage < 100% (requires `verify-witness: true`) |
| `comment-on-pr` | `true` | Post/update sticky PR comment |
| `github-token` | `${{ github.token }}` | Token for API calls |

## Outputs

| Output | Description |
|--------|-------------|
| `commits-total` | Total commits in PR |
| `commits-traced` | Commits with `AgentMesh-Episode:` trailer |
| `coverage-pct` | Lineage coverage percentage (0-100) |
| `unique-episodes` | Distinct episode IDs found |
| `files-changed` | Files changed across PR |
| `witness-present` | Commits with witness trailers present |
| `witness-verified` | Commits whose witness signatures verified |
| `witness-coverage-pct` | Witness verification coverage percentage (0-100) |
| `result` | `PASS` or `FAIL` |
| `badge-url` | shields.io URL for README embedding |

## Strict Mode

Require 100% lineage coverage to pass CI:

```yaml
- uses: Haserjian/agentmesh-action@v1
  with:
    require-trailers: 'true'
```

Require both lineage and witness verification:

```yaml
- uses: Haserjian/agentmesh-action@v1
  with:
    verify-witness: 'true'
    require-trailers: 'true'
    require-witness: 'true'
```

## What is Lineage Coverage?

When you use `agentmesh commit`, each git commit gets an `AgentMesh-Episode:` trailer linking it to the agent session that produced the code. Lineage coverage measures what percentage of commits in a PR carry this trailer.

- **100%** -- every commit traces back to an agent episode
- **75%** -- some commits were made outside AgentMesh
- **0%** -- no trailers found (AgentMesh not installed or not used)

This is **lineage tracking**, not provenance verification. It answers "which commits came from agent sessions?" without validating the full evidence chain.

## Witness Verification Mode

Set `verify-witness: 'true'` to verify cryptographic witness signatures attached by recent `agentmesh commit` flows. This mode installs `agentmesh-core[witness]` in the action runtime and checks each PR commit with:

```bash
agentmesh witness verify <commit_sha>
```

If `require-witness: 'true'`, the action fails when verified witness coverage is below 100%.

## PR Comment Example

The action posts a sticky comment on each PR:

> ### AgentMesh Lineage Check
>
> **Lineage coverage: 3/4 commits (75%)**
>
> | Metric | Value |
> |--------|-------|
> | Commits in PR | 4 |
> | With episode trailer | 3 |
> | Coverage | 75% |
> | Unique episodes | 1 |
> | Files changed | 7 |

The comment updates on each push (no duplicates).

## Permissions

Minimum permissions required:

```yaml
permissions:
  contents: read        # read commit history
  pull-requests: write  # post PR comments
```

## How It Works

Lineage mode is pure bash + git + jq with no AgentMesh install. Witness mode additionally installs `agentmesh-core[witness]` to perform signature verification.

1. `git log base..head` to list PR commits
2. `%(trailers:key=AgentMesh-Episode)` to extract trailers
3. Count traced vs total, compute coverage
4. Post results as PR comment + step summary

## Notes

- **Fork PRs**: Comment posting is best-effort. If the token lacks `pull-requests: write` (common for fork PRs), the action warns and continues -- lineage check results still appear in the step summary.
- **Noisy PRs**: The sticky comment lookup paginates through all comments, so it won't create duplicates even on PRs with 100+ comments.
