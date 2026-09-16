#!/bin/sh
# Apply the full ObiLabs protection set to repositories that already exist.
#
#   sh tooling/apply-protection.sh <repo> [<repo>...] [options]
#   sh tooling/apply-protection.sh --all [options]
#
#   --all              every non-archived repository in the organisation
#   --private-only     with --all: only the private repositories
#   --dry-run          print what would be done; change nothing
#   --require-check C  also require status check "C" (repeat for several)
#   --require-check auto
#                      discover the check names already running on the default
#                      branch and require the hygiene one(s). A repo where none
#                      is found is reported, not guessed at.
#   --org NAME         default: obilabs
#
# It does NOT create repositories and it never changes visibility: it calls
# tooling/new-repo.sh --require-existing --no-clone per repo, so protection,
# secret scanning, Dependabot and merge settings have exactly one
# implementation. This script adds the things only a sweep needs: repo
# discovery, an independent read-back of the protection GitHub actually stored,
# and a summary of which repositories the plan still refuses.
#
# THE DAY GITHUB TEAM IS ACTIVE, this is the command to run:
#
#   sh tooling/apply-protection.sh --all --dry-run     # read the plan first
#   sh tooling/apply-protection.sh --all               # then apply it
#
# Before that it is still worth running: it applies everything the Free plan
# allows and tells you precisely what is being refused, per repository.
#
# Exit codes:
#   0  every requested repository ended up protected (or --dry-run)
#   1  at least one repository is NOT protected after the run
#   2  the script could not run (no gh, not authenticated, bad arguments)
#
# Canonical source: obilabs/.github, tooling/apply-protection.sh.
set -eu

ORG=obilabs
ALL=0
PRIVATE_ONLY=0
DRY_RUN=0
REQUIRE_CHECKS=''
AUTO_CHECKS=0
REPOS=''

die() { echo "apply-protection: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --all) ALL=1; shift ;;
    --private-only) PRIVATE_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --org) ORG=${2:?--org needs a value}; shift 2 ;;
    --require-check)
      [ $# -ge 2 ] || die "--require-check needs a value"
      if [ "$2" = auto ]; then AUTO_CHECKS=1; else
        REQUIRE_CHECKS="$REQUIRE_CHECKS$2
"
      fi
      shift 2
      ;;
    -h | --help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) REPOS="$REPOS $1"; shift ;;
  esac
done

[ "$ALL" -eq 1 ] || [ -n "$REPOS" ] || die "name at least one repository, or pass --all"
[ "$ALL" -eq 0 ] || [ -z "$REPOS" ] || die "--all takes no repository names"

command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
NEW_REPO=$SELF_DIR/new-repo.sh
[ -r "$NEW_REPO" ] || die "cannot find $NEW_REPO (run this from a clone of obilabs/.github)"

# ------------------------------------------------------------- repo list ----
if [ "$ALL" -eq 1 ]; then
  REPOS=$(gh repo list "$ORG" --limit 200 --no-archived --json name --jq '.[].name' | sort) ||
    die "cannot list repositories in '$ORG'"
  [ -n "$REPOS" ] || die "no repositories found in '$ORG'"
fi

echo "apply-protection: org=$ORG"
[ "$DRY_RUN" -eq 1 ] && echo "apply-protection: DRY RUN - nothing will be changed."

rows=''
failed=0

for repo in $REPOS; do
  echo ""
  echo "################ $ORG/$repo"

  meta=$(gh api "repos/$ORG/$repo" --jq '[.private, (.default_branch // "main")] | @tsv' 2>/dev/null) || {
    echo "  cannot read $ORG/$repo with this token - skipped."
    rows="$rows| \`$repo\` | ? | not readable with this token | skipped |
"
    failed=1
    continue
  }
  private=$(printf '%s' "$meta" | cut -f1)
  branch=$(printf '%s' "$meta" | cut -f2)
  [ "$private" = true ] && vis=private || vis=public

  if [ "$PRIVATE_ONLY" -eq 1 ] && [ "$vis" != private ]; then
    echo "  public, and --private-only was given - skipped."
    continue
  fi
  if [ "$branch" != main ]; then
    echo "  WARNING: default branch is '$branch', not 'main'."
    echo "           new-repo.sh protects 'main' only; protect '$branch' by hand."
    rows="$rows| \`$repo\` | $vis | default branch is \`$branch\`, not \`main\` | **by hand** |
"
    failed=1
    continue
  fi

  # ---- required status checks -------------------------------------------
  checks=$REQUIRE_CHECKS
  if [ "$AUTO_CHECKS" -eq 1 ]; then
    # Only require a check the repository demonstrably runs: read the check-run
    # names on the tip of the default branch. Requiring a check that never
    # reports leaves every pull request stuck in "Expected".
    found=$(gh api "repos/$ORG/$repo/commits/$branch/check-runs" \
      --jq '[.check_runs[].name] | unique | .[]' 2>/dev/null |
      grep -i 'hygiene' || true)
    if [ -n "$found" ]; then
      checks="$checks$found
"
      echo "  Discovered hygiene check(s): $(printf '%s' "$found" | tr '\n' ' ')"
    else
      echo "  No hygiene check has reported on $branch - not requiring one here."
      echo "  (Add .github/workflows/hygiene.yml to this repo first; see tooling/README.md.)"
    fi
  fi

  set -- "$repo" "$vis" --require-existing --no-clone
  [ "$DRY_RUN" -eq 1 ] && set -- "$@" --dry-run
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    set -- "$@" --require-check "$c"
  done <<EOF
$checks
EOF

  rc=0
  # Captured rather than piped so the exit status is new-repo.sh's, not sed's.
  out=$(sh "$NEW_REPO" "$@" 2>&1) || rc=$?
  printf '%s\n' "$out" | sed 's/^/  /'

  # ---- independent read-back --------------------------------------------
  # new-repo.sh verifies its own work; this verifies it again from the outside,
  # because "the script said it worked" is not evidence.
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ "$rc" -eq 0 ]; then
      rows="$rows| \`$repo\` | $vis | (dry run - nothing applied) | plan is valid |
"
    else
      rows="$rows| \`$repo\` | $vis | (dry run) | **new-repo.sh exited $rc - see above** |
"
      failed=1
    fi
    continue
  fi

  prot_out=$(gh api "repos/$ORG/$repo/branches/$branch/protection" 2>&1) && prot_rc=0 || prot_rc=$?
  if [ "$prot_rc" -eq 0 ]; then
    admins=no
    printf '%s' "$prot_out" | tr ',' '\n' | grep -A1 'enforce_admins' |
      grep -q '"enabled":true' && admins=yes
    prs=no
    printf '%s' "$prot_out" | grep -q 'required_pull_request_reviews' && prs=yes
    if [ "$admins" = yes ] && [ "$prs" = yes ]; then
      state='protected, PR required, **admins bound**'
      echo "  VERIFIED: $ORG/$repo main is protected and admins are bound."
    else
      state="protected, but PR required=$prs, admins bound=$admins - **incomplete**"
      echo "  WARNING: protection on $ORG/$repo is incomplete." >&2
      failed=1
    fi
  elif printf '%s' "$prot_out" | grep -qE 'Upgrade to GitHub Pro|upgrade your plan'; then
    state='**REFUSED BY THE PLAN** - private repo on GitHub Free'
    echo "  REFUSED: GitHub will not protect a private repo on this plan."
    failed=1
  elif printf '%s' "$prot_out" | grep -q 'Branch not protected'; then
    state='**NOT PROTECTED** (no plan message - investigate)'
    failed=1
  else
    state='**unknown** - the protection API returned an error'
    failed=1
  fi
  rows="$rows| \`$repo\` | $vis | $state | $( [ "$rc" -eq 0 ] && echo ok || echo "new-repo.sh exited $rc" ) |
"
done

# ---------------------------------------------------------------- report ----
cat <<EOF

================================================================
 Protection summary - $ORG
================================================================

| Repo | Visibility | State of \`main\` after this run | new-repo.sh |
|---|---|---|---|
EOF
printf '%s' "$rows"

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<'EOF'

Dry run: nothing was changed, so nothing was verified. Re-run without
--dry-run to apply, then read the table above - it is the read-back, not the
intention.
EOF
  # A dry run still fails when the PLAN is broken (a repo that cannot be read,
  # a default branch that is not main, new-repo.sh refusing the arguments).
  exit "$failed"
fi

if [ "$failed" -eq 1 ]; then
  cat <<'EOF'

At least one repository is NOT protected. If the reason is "REFUSED BY THE
PLAN", that is GitHub Free gating branch protection on private repositories -
the fix is GitHub Team ($4/user/month), and the substitute until then is the
local pre-push hook plus tooling/preflight.sh. Any other reason is a real
misconfiguration; fix it and re-run.
EOF
  exit 1
fi

echo ""
echo "Every requested repository is protected, with admins bound."
exit 0
