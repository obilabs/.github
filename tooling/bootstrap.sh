#!/bin/sh
# One command to put the ObiLabs hygiene hooks on a machine that has never had
# them - a new laptop, a CI box, a fresh agent worktree, a rebuilt VM.
#
#   curl -fsSL https://raw.githubusercontent.com/obilabs/.github/main/tooling/bootstrap.sh | sh
#
# It shallow-clones obilabs/.github into a temp directory, runs the canonical
# installer (tooling/git-hooks/install.sh - this file adds no logic of its own),
# and cleans up. obilabs/.github is public, so no token is needed.
#
# Per-machine configuration is the weak point of the whole hygiene story: on the
# Free plan, a private repo's main is unprotected server-side, so a machine
# without these hooks can push straight to main and nobody finds out until the
# scheduled drift detector runs. Run this FIRST on any new machine.
#
# Canonical source: obilabs/.github, tooling/bootstrap.sh.
set -eu

REPO_URL=${OBILABS_GITHUB_REPO:-https://github.com/obilabs/.github.git}
REF=${OBILABS_GITHUB_REF:-main}

command -v git >/dev/null 2>&1 || { echo "bootstrap: git is not installed" >&2; exit 1; }

tmp=$(mktemp -d 2>/dev/null || mktemp -d -t obilabs) ||
  { echo "bootstrap: cannot create a temp directory" >&2; exit 1; }
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

echo "bootstrap: fetching $REPO_URL ($REF)"
git clone --quiet --depth 1 --branch "$REF" "$REPO_URL" "$tmp/dotgithub" ||
  { echo "bootstrap: clone failed" >&2; exit 1; }

sh "$tmp/dotgithub/tooling/git-hooks/install.sh" "$@"

cat <<'EOF'

bootstrap: verifying
EOF
hp=$(git config --global --get core.hooksPath || true)
if [ -z "$hp" ]; then
  echo "  FAILED: global core.hooksPath is still unset." >&2
  exit 1
fi
echo "  core.hooksPath = $hp"
cfg=${OBILABS_CONFIG_DIR:-$HOME/.config/obilabs}
for h in pre-commit commit-msg pre-push; do
  f="$cfg/git-hooks/$h"
  if [ -f "$f" ]; then
    echo "  present: $h"
  else
    echo "  MISSING: $h" >&2
    exit 1
  fi
done

cat <<'EOF'

Done. On this machine git will now refuse a direct push to main, a personal
webmail commit identity, AI co-author trailers, secrets and user-home paths.

Caveat worth knowing: a repository that sets its OWN core.hooksPath (husky and
friends) overrides this. The installer prints the lines to chain the checks in;
run it with the repo paths to check them:
    sh tooling/git-hooks/install.sh ../repo-a ../repo-b
EOF
