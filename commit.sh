#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# commit.sh
#
# Stages all changes, commits using the message in commit.msg, pushes to
# the remote, and then clears commit.msg so it is ready for the next use.
#
# Usage:
#   ./commit.sh
#
# The commit message is read from commit.msg in the same directory as this
# script. The file must contain at minimum a non-empty subject line.
# Lines beginning with # are treated as comments and ignored.
#
# Clearing behaviour:
#   After a successful push, the body of commit.msg is wiped and replaced
#   with the comment block only. This means the file is always present (so
#   git does not track a deletion) but contains no stale message. If the
#   commit or push fails, the file is left untouched so you do not lose
#   your message.
# ─────────────────────────────────────────────────────────────────────────────

# Allow git to work across filesystem mount boundaries (e.g. /mnt/md0/)
export GIT_DISCOVERY_ACROSS_FILESYSTEM=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MSG_FILE="${SCRIPT_DIR}/commit.msg"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Verify commit.msg exists
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -f "$MSG_FILE" ]]; then
  echo "ERROR: commit.msg not found at ${MSG_FILE}"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Strip comments and check the message is not empty
# Git itself honours # comments in commit messages, but we validate here
# to give a clearer error than git would.
# ─────────────────────────────────────────────────────────────────────────────
STRIPPED=$(grep -v '^\s*#' "$MSG_FILE" | sed '/^[[:space:]]*$/d')

if [[ -z "$STRIPPED" ]]; then
  echo "ERROR: commit.msg contains no message. Add a subject line and try again."
  echo "       Lines beginning with # are treated as comments and ignored."
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Validate subject line length
# The first non-comment line is the subject. Git recommends 50 chars max.
# We warn but do not block, since this is a soft convention.
# ─────────────────────────────────────────────────────────────────────────────
SUBJECT=$(echo "$STRIPPED" | head -n1)
SUBJECT_LEN=${#SUBJECT}

if [[ $SUBJECT_LEN -gt 50 ]]; then
  echo "WARNING: Subject line is ${SUBJECT_LEN} characters. Recommended maximum is 50."
  echo "         Continuing anyway..."
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Check there is something to commit
# ─────────────────────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

if git diff --quiet && git diff --cached --quiet; then
  # Check for untracked files too
  if [[ -z "$(git ls-files --others --exclude-standard)" ]]; then
    echo "Nothing to commit — working tree is clean."
    exit 0
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Stage all changes
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Staging all changes..."
git add .

echo "    Files staged:"
git diff --cached --name-only | sed 's/^/      /'

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Commit using commit.msg
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Committing..."
git commit --file="$MSG_FILE" --cleanup=strip

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 — Push to remote
# Load the commit token from config.env, embed it in the remote URL for the
# push, then strip it immediately after so it is never left in .git/config.
# ─────────────────────────────────────────────────────────────────────────────
CONFIG_FILE="${SCRIPT_DIR}/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: config.env not found at ${CONFIG_FILE}"
  exit 1
fi

# Extract GITHUB_COMMIT_TOKEN and repo details from config.env
GITHUB_COMMIT_TOKEN=$(grep '^GITHUB_COMMIT_TOKEN=' "$CONFIG_FILE" | \
  sed 's/^GITHUB_COMMIT_TOKEN=//;s/^"//;s/"$//')
GITHUB_USERNAME=$(grep '^GITHUB_USERNAME=' "$CONFIG_FILE" | \
  sed 's/^GITHUB_USERNAME=//;s/^"//;s/"$//')
GITHUB_REPO=$(grep '^GITHUB_REPO=' "$CONFIG_FILE" | \
  sed 's/^GITHUB_REPO=//;s/^"//;s/"$//')

if [[ -z "$GITHUB_COMMIT_TOKEN" ]]; then
  echo "ERROR: GITHUB_COMMIT_TOKEN is not set in config.env"
  exit 1
fi

echo "==> Pushing to remote..."
# Temporarily embed token in remote URL
git remote set-url origin "https://${GITHUB_COMMIT_TOKEN}@github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"
git push
# Strip token from remote URL immediately after push
git remote set-url origin "https://github.com/${GITHUB_USERNAME}/${GITHUB_REPO}.git"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 — Clear commit.msg
# Only reached if commit and push both succeeded. Replaces the file contents
# with the comment block only, leaving the file present and ready for reuse.
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Clearing commit.msg..."
cat > "$MSG_FILE" <<'EOF'
# Commit message file — used by commit.sh
#
# Format rules:
#   Line 1:  Short summary, 50 characters or less
#   Line 2:  Blank
#   Line 3+: Detail explaining what changed and why.
#             Wrap at 72 characters. Can be multiple paragraphs
#             separated by blank lines.
#
# Lines starting with # are ignored.
# This file is cleared automatically after a successful commit and push.
#
# Example:
#   Fix Radicale auth config path
#
#   The htpasswd path was set relative to the working directory rather
#   than the absolute container path. This caused auth to fail on first
#   run when the container started from a different directory.

EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Done! Changes committed and pushed."
echo "  commit.msg has been cleared and is ready for the next use."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
