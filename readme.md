# pr-review

Claude Code skill for PR review. Generates and validates structured action data in `comment.rktd`; `send-comment.rkt` is available for explicit interactive sending.

## Install

```bash
git clone <repo-url> ~/.claude/skills/pr-review
```

## Usage

In Claude Code:

```
/pr-review https://github.com/owner/repo/pull/42
```

This will:
1. Fetch PR/commit diff via `fetch-diff.rkt` (GitHub & GitCode API)
2. Analyze changes against configured rules
3. Generate `comment.rktd` (structured review data)
4. Validate the action data without submitting comments or creating/updating remote resources

### Validate or Send

```bash
racket ~/.claude/skills/pr-review/scripts/send-comment.rkt --dry-run --non-interactive --file comment.rktd  # validate/preview
racket ~/.claude/skills/pr-review/scripts/send-comment.rkt --file comment.rktd                              # interactive send
racket ~/.claude/skills/pr-review/scripts/send-comment.rkt --non-interactive --file comment.rktd            # direct send, only when explicitly allowed
```

## Auth

`send-comment.rkt` looks for tokens in this order:

1. Env var (`GITHUB_TOKEN` / `GITCODE_TOKEN`)
2. Project-local `.github.token` / `.gitcode.token`
3. `~/.github.token` / `~/.gitcode.token`
4. Optional `gh auth token` fallback (GitHub only; `gh` unavailable is normal)

## Structure

```
SKILL.md                                # Skill definition
scripts/
  fetch-diff.rkt                        # Fetch PR/commit diff from GitHub/GitCode API
  send-comment.rkt                      # Interactive comment sender
docs/
  gitcode-token.md                      # GitCode token setup guide
references/
  api-reference.md                      # GitHub/GitCode API reference
  rktd-schemas.md                       # comment.rktd schema docs
examples/
  comment-example.rktd                  # PR inline comment example
  commit-comment-example.rktd           # Commit comment example
  config-example.rktd                   # Config file example
  preferences-example.rktd              # Preferences file example
```

Per-project `.skill.pr-review.history/` directory is created on first run (not part of this repo).
