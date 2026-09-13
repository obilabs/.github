#!/bin/sh
# Install the ObiLabs hygiene git hooks for the current user.
#
#   sh tooling/git-hooks/install.sh [repo-dir ...]
#
# Copies the hooks to ~/.config/obilabs/git-hooks/, points the global
# core.hooksPath at them, and creates an empty user-local denylist if absent.
# Any repo-dir arguments (plus the current repo, if any) are checked for a local
# core.hooksPath, which would override the global hooks.
set -eu

src=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
cfg="${OBILABS_CONFIG_DIR:-$HOME/.config/obilabs}"
dest="$cfg/git-hooks"
denylist="$cfg/hygiene-denylist"
hooks="pre-commit commit-msg pre-push"

mkdir -p "$dest"
for f in $hooks hygiene-lib.sh; do
  cp "$src/$f" "$dest/$f"
done
for f in $hooks; do chmod +x "$dest/$f"; done

if [ ! -f "$denylist" ]; then
  cat >"$denylist" <<'EOF'
# ObiLabs hygiene denylist (user-local; never commit this file).
# One entry per line, matched as a case-insensitive fixed string against lines
# added in each commit. Put strings that must never land in a repo here, such
# as your personal email address or your machine's username. Lines starting
# with '#' are ignored.
EOF
  echo "Created denylist: $denylist"
fi

# Store a ~-relative value when installing to the default location so the
# global git config carries no username-bearing absolute path.
if [ -z "${OBILABS_CONFIG_DIR:-}" ]; then
  hooks_path='~/.config/obilabs/git-hooks'
else
  hooks_path=$dest
fi

prev=$(git config --global --get core.hooksPath || true)
if [ -n "$prev" ] && [ "$prev" != "$hooks_path" ]; then
  echo "NOTE: replacing previous global core.hooksPath: $prev"
fi
git config --global core.hooksPath "$hooks_path"

echo "Installed ObiLabs hygiene hooks to: $dest"
echo "Global core.hooksPath = $(git config --global --get core.hooksPath)"
echo "Repo-local hooks in .git/hooks/ keep working: each hook chains to them."

warned=0
check_repo() {
  local_path=$(git -C "$1" config --local --get core.hooksPath 2>/dev/null || true)
  if [ -n "$local_path" ]; then
    warned=1
    echo ""
    echo "WARNING: $1 sets a local core.hooksPath ($local_path)."
    echo "  It overrides the global hooks, so hygiene checks do NOT run there."
    echo "  Chain them from that repo's hooks (e.g. husky's .husky/ files):"
    echo "    pre-commit:  sh \"\$HOME/.config/obilabs/git-hooks/pre-commit\" \"\$@\" || exit 1"
    echo "    commit-msg:  sh \"\$HOME/.config/obilabs/git-hooks/commit-msg\" \"\$@\""
    echo "    pre-push:    (stdin must be forwarded)"
    echo "      input=\$(cat)"
    echo "      printf '%s\\n' \"\$input\" | sh \"\$HOME/.config/obilabs/git-hooks/pre-push\" \"\$@\" || exit 1"
  fi
}
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  check_repo "$(git rev-parse --show-toplevel)"
fi
for repo in "$@"; do check_repo "$repo"; done
[ "$warned" -eq 0 ] && echo "No local core.hooksPath overrides found in the checked repos."

cat <<EOF

Escape hatches:
  per line:     add the marker 'hygiene:allow' on the offending line
  per commit:   OBILABS_HYGIENE_SKIP=1 git commit ...
  main push:    OBILABS_ALLOW_MAIN_PUSH=1 git push ...

Uninstall:
  git config --global --unset core.hooksPath
  rm -rf "$dest"
EOF
