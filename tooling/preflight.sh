#!/bin/sh
# ObiLabs preflight: run this before starting work in any ObiLabs clone.
#
#   sh tooling/preflight.sh [--dir PATH] [--no-fetch] [--quiet]
#
# It checks the four things that have actually gone wrong here:
#   1. the ObiLabs git hooks are active in this repository (core.hooksPath);
#   2. the commit identity is the GitHub noreply address, not personal webmail;
#   3. the checkout is NOT sitting on main/master, where work must never start;
#   4. remote main carries no commits that look unreviewed since the last tag
#      (or the merge-base with this branch).
#
# Exit codes:
#   0  safe to work here
#   1  something is wrong - the message says what to fix
#   2  preflight could not run (not a git repository, git missing)
#
# WHAT THIS IS: advice a person or an agent must choose to run. It cannot block
# anything by itself - the local hooks (tooling/git-hooks) do that, and only on
# machines where they are installed. Wiring this into a SessionStart hook is
# what makes it reliable; see docs/GOVERNANCE.md.
#
# It is deliberately fast, because a slow check gets skipped and a skipped check
# guards nothing: about a second on Linux/macOS and 2-3 seconds on Windows Git
# Bash, measured. The only network call is one `git fetch` of the default
# branch, capped at 5 seconds where `timeout` exists; --no-fetch skips it and
# the remote check then runs against whatever refs are already local.
#
# Canonical source: obilabs/.github, tooling/preflight.sh.
set -eu

NOREPLY_SUFFIX='@users.noreply.github.com'
HOOKS_DIRNAME='obilabs/git-hooks'
DIR=.
FETCH=1
QUIET=0

while [ $# -gt 0 ]; do
  case $1 in
    --dir) DIR=${2:?--dir needs a value}; shift 2 ;;
    --no-fetch) FETCH=0; shift ;;
    --quiet) QUIET=1; shift ;;
    -h | --help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "preflight: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v git >/dev/null 2>&1 || { echo "preflight: git is not installed" >&2; exit 2; }

# Resolve the script's own directory BEFORE changing directory, or --dir breaks
# the lookup of the shared library below.
SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SELF_DIR=''

cd "$DIR" 2>/dev/null || { echo "preflight: no such directory: $DIR" >&2; exit 2; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "preflight: $(pwd) is not a git work tree" >&2
  exit 2
}

# Shared with org-drift.sh: one definition of the "names a PR" heuristic.
_lib=${SELF_DIR:-.}/lib/pr-subject.sh
if [ -r "$_lib" ]; then
  # shellcheck source=tooling/lib/pr-subject.sh
  . "$_lib"
else
  # Running from a copy that was installed without the lib (for example a hook
  # directory). Say so rather than silently using a different rule.
  subject_names_pr() { printf '%s' "$1" | grep -Eq '\(#[0-9]+\)|^Merge pull request #[0-9]+'; }
fi

FAILS=''
fail() { FAILS="$FAILS  FAIL  $1
"; }
ok() { [ "$QUIET" -eq 1 ] || echo "  ok    $1"; }
note() { [ "$QUIET" -eq 1 ] || echo "  note  $1"; }

[ "$QUIET" -eq 1 ] || echo "preflight: $(git rev-parse --show-toplevel)"

# ------------------------------------------------------------- 1. hooks ----
# The installer stores a ~-relative path, so accept both spellings; a LOCAL
# core.hooksPath (husky and friends) overrides the global one and silences the
# org hooks, which is a failure, not a warning.
local_hp=$(git config --local --get core.hooksPath || true)
global_hp=$(git config --global --get core.hooksPath || true)
hooks_dir=''
case $global_hp in
  *"$HOOKS_DIRNAME") hooks_dir=$global_hp ;;
esac

if [ -n "$local_hp" ]; then
  case $local_hp in
    *"$HOOKS_DIRNAME")
      ok "hooks: this repo points at the ObiLabs hooks ($local_hp)"
      ;;
    *)
      fail "this repository sets core.hooksPath=$local_hp, which overrides the
        ObiLabs hooks - they will NOT run here. Chain them in:
          sh tooling/git-hooks/install.sh ."
      ;;
  esac
elif [ -n "$hooks_dir" ]; then
  expanded=$(printf '%s' "$hooks_dir" | sed "s|^~|$HOME|")
  if [ -x "$expanded/pre-push" ]; then
    ok "hooks: core.hooksPath = $hooks_dir (pre-push present)"
  else
    fail "core.hooksPath is $hooks_dir but $expanded/pre-push is missing or not
        executable. Reinstall:
          curl -fsSL https://raw.githubusercontent.com/obilabs/.github/main/tooling/bootstrap.sh | sh"
  fi
else
  fail "the ObiLabs git hooks are not installed on this machine
        (core.hooksPath = ${global_hp:-unset}). Nothing local will stop a push
        to main. Install them:
          curl -fsSL https://raw.githubusercontent.com/obilabs/.github/main/tooling/bootstrap.sh | sh"
fi

# ---------------------------------------------------------- 2. identity ----
email=$(git config --get user.email || true)
name=$(git config --get user.name || true)
case $email in
  *"$NOREPLY_SUFFIX")
    ok "identity: $name <$email>"
    ;;
  '')
    fail "no commit identity is configured here. Set it:
          git config user.name 'Michael Agu'
          git config user.email '<id>+<user>$NOREPLY_SUFFIX'"
    ;;
  *)
    fail "commit email is '$email', not a GitHub noreply address. A push
        carrying a personal address is rejected by GitHub push protection
        (GH007), and the address is permanent in any history it reaches. Fix:
          git config user.email '<id>+<user>$NOREPLY_SUFFIX'"
    ;;
esac

# ------------------------------------------------------------ 3. branch ----
# symbolic-ref, not rev-parse: it still answers on a branch with no commits yet,
# which is exactly when somebody is about to make the first commit on main.
branch=$(git symbolic-ref --short -q HEAD 2>/dev/null || echo 'HEAD')
case $branch in
  main | master)
    fail "you are on '$branch'. Work never starts here: this harness syncs local
        main to origin, so a commit on main can reach GitHub with no review.
        Start a branch first:
          git switch -c <type>/<short-description>"
    ;;
  HEAD)
    note "detached HEAD - no branch to check. Create one before committing."
    ;;
  '')
    note "could not determine the current branch (new repository with no commits?)"
    ;;
  *)
    ok "branch: $branch"
    ;;
esac

# ------------------------------------------- 4. unreviewed commits on main --
remote_main=''
for candidate in origin/main origin/master; do
  if git rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
    remote_main=$candidate
    break
  fi
done

if [ -z "$remote_main" ]; then
  note "no origin/main or origin/master ref here - skipping the remote check"
else
  if [ "$FETCH" -eq 1 ]; then
    rb=${remote_main#origin/}
    if command -v timeout >/dev/null 2>&1; then
      timeout 5 git fetch --quiet --no-tags origin "$rb" 2>/dev/null ||
        note "could not refresh $remote_main (offline or slow); checking the local copy"
    else
      git fetch --quiet --no-tags origin "$rb" 2>/dev/null ||
        note "could not refresh $remote_main (offline?); checking the local copy"
    fi
  else
    note "--no-fetch: checking the local copy of $remote_main, which may be stale"
  fi

  # Window: since the last tag on the remote branch, falling back to the
  # merge-base with this branch when the repo has no tags. The tag is preferred
  # deliberately - a branch cut FROM a drifted main has a merge-base after the
  # bad commit, so the merge-base alone would report nothing at all. Reviewed
  # commits name their PR, so widening the window costs no noise.
  base=$(git merge-base HEAD "$remote_main" 2>/dev/null || echo '')
  tag=$(git describe --tags --abbrev=0 "$remote_main" 2>/dev/null || echo '')
  if [ -n "$tag" ]; then
    start=$tag
    window="tag $tag"
  else
    start=$base
    window="the merge-base with this branch"
  fi

  if [ -z "$start" ]; then
    note "no merge-base or tag to measure from - skipping the remote check"
  else
    suspects=''
    n=0
    # --no-merges + subject only, one commit per line.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      subj=${line#* }
      if ! subject_names_pr "$subj"; then
        n=$((n + 1))
        [ "$n" -le 20 ] && suspects="$suspects
          $line"
      fi
    done <<EOF
$(git log --no-merges --format='%h %s' "$start".."$remote_main" 2>/dev/null || true)
EOF
    if [ -n "$suspects" ]; then
      [ "$n" -gt 20 ] && suspects="$suspects
          ... and $((n - 20)) more"
      fail "$remote_main carries $n commit(s) whose subject does not name a pull
        request, measured since $window:$suspects

        This is a HEURISTIC, not proof - a rewritten history loses the real
        association. Confirm before acting on it:
          sh tooling/org-drift.sh --repo <name> --commit <sha>"
    else
      ok "$remote_main: no unreviewed-looking commits since $(git rev-parse --short "$start" 2>/dev/null || echo "$start")"
    fi
  fi
fi

# ------------------------------------------------------------- verdict ----
if [ -n "$FAILS" ]; then
  echo ""
  echo "preflight FAILED:"
  printf '%s' "$FAILS"
  cat <<'EOF'

STOP. Do not commit or push from this checkout until the items above are fixed.
If you are an agent: report this to the user and wait - do not work around it,
and do not use OBILABS_HYGIENE_SKIP or --no-verify.
EOF
  exit 1
fi

[ "$QUIET" -eq 1 ] || echo "preflight: OK - safe to work here."
exit 0
