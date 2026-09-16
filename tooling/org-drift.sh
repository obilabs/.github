#!/bin/sh
# ObiLabs governance drift detector.
#
#   sh tooling/org-drift.sh [--org obilabs] [--days 7] [--repo NAME]... [--quiet]
#   sh tooling/org-drift.sh --repo NAME --commit SHA      (single-commit mode)
#
# Single-commit mode answers one question about one commit - "did this reach the
# branch through a pull request?" - and is what the push-guard workflow calls a
# minute after a push, so the same association logic has exactly one
# implementation. Exit 0 = associated (or a rewritten-history false alarm),
# 1 = direct push, 2 = could not be determined.
#
# For every non-archived repository in the organisation it reports:
#   1. commits on the default branch that are NOT associated with any pull
#      request - i.e. somebody pushed straight to main;
#   2. whether branch protection is on, and whether it binds admins;
#   3. whether secret scanning / push protection / Dependabot alerts are on;
#   4. whether the repo calls the shared hygiene workflow at all.
#
# It writes a Markdown report to stdout and exits:
#   0  no drift found
#   1  drift found (direct pushes, or a protection/scanning regression)
#   2  the check itself could not run (auth, API failure)
#
# THIS IS DETECTION, NOT PREVENTION. On the GitHub Free plan a private
# repository cannot have server-side branch protection, so a direct push to main
# SUCCEEDS and is only visible here afterwards. See docs/GOVERNANCE.md.
#
# Needs: gh, authenticated with a token that can read every repo in the org.
# Canonical source: obilabs/.github, tooling/org-drift.sh.
set -eu

ORG=obilabs
DAYS=7
ONLY=''
QUIET=0
COMMIT=''

while [ $# -gt 0 ]; do
  case $1 in
    --org) ORG=${2:?--org needs a value}; shift 2 ;;
    --days) DAYS=${2:?--days needs a value}; shift 2 ;;
    --repo) ONLY="$ONLY $2"; shift 2 ;;
    --commit) COMMIT=${2:?--commit needs a value}; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h | --help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "org-drift: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case $DAYS in
  '' | *[!0-9]*) echo "org-drift: --days must be a whole number" >&2; exit 2 ;;
esac

command -v gh >/dev/null 2>&1 || { echo "org-drift: gh is not installed" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "org-drift: gh is not authenticated" >&2; exit 2; }

progress() { [ "$QUIET" -eq 1 ] || echo "org-drift: $*" >&2; }

# ---------------------------------------------------- PR association (shared) --
# ONE definition of "did this commit arrive through a pull request?", used by
# the org-wide sweep below AND by --commit mode, which the push-guard workflow
# calls. Do not write a second implementation of this anywhere.

# commit_pr_count <repo> <sha> -> number of associated pull requests, or '?'
# when the API could not answer. A squash- or merge-commit landed by a PR IS
# associated with that PR, so 0 means the commit reached the branch another way.
commit_pr_count() {
  # gh prints the API error body on stdout, so validate the answer instead of
  # trusting the exit status: anything that is not a number means "unknown".
  _n=$(gh api "repos/$ORG/$1/commits/$2/pulls" --jq '[.[].number] | length' 2>/dev/null) || _n=''
  case ${_n:-} in
    '' | *[!0-9]*) echo '?' ;;
    *) echo "$_n" ;;
  esac
}

# commit_sha <repo> <sha-ish> -> the full 40-character sha, or '' if unknown.
# The commits/<sha>/pulls endpoint rejects abbreviated shas with a 422.
commit_sha() {
  _s=$(gh api "repos/$ORG/$1/commits/$2" --jq '.sha' 2>/dev/null) || _s=''
  case ${_s:-} in
    *[!0-9a-f]* | '') echo '' ;;
    *) [ "${#_s}" -eq 40 ] && echo "$_s" || echo '' ;;
  esac
}

# commit_info <repo> <sha> -> TSV: date, author name, first line of the message.
commit_info() {
  gh api "repos/$ORG/$1/commits/$2" \
    --jq '[(.commit.author.date|split("T")[0]), (.commit.author.name), (.commit.message|split("\n")[0])] | @tsv' \
    2>/dev/null || echo ''
}

# subject_names_pr lives in tooling/lib/pr-subject.sh so that this script and
# tooling/preflight.sh share one definition of the heuristic.
_lib=$(dirname "$0")/lib/pr-subject.sh
[ -r "$_lib" ] || { echo "org-drift: missing $_lib" >&2; exit 2; }
# shellcheck source=tooling/lib/pr-subject.sh
. "$_lib"

# ISO-8601 cutoff, DAYS ago. GNU date and BSD date disagree; try both.
SINCE=$(date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
  date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
  echo '')
[ -n "$SINCE" ] || { echo "org-drift: could not compute a date $DAYS days ago" >&2; exit 2; }

# ------------------------------------------------------ single-commit mode --
# Used by .github/workflows/push-guard.yml, minutes after a push, in the repo
# the push landed in. Still detection - the ref has already moved - but minutes
# instead of a week, and reported where the violation happened.
if [ -n "$COMMIT" ]; then
  one=$(printf '%s' "$ONLY" | tr -s ' ' | sed 's/^ //;s/ $//')
  case $one in
    '') echo "org-drift: --commit needs exactly one --repo NAME" >&2; exit 2 ;;
    *\ *) echo "org-drift: --commit takes a single --repo, got:$ONLY" >&2; exit 2 ;;
  esac
  case $COMMIT in
    *[!0-9A-Fa-f]*) echo "org-drift: --commit must be a hex sha, got '$COMMIT'" >&2; exit 2 ;;
  esac

  full=$(commit_sha "$one" "$COMMIT")
  [ -n "$full" ] || {
    echo "org-drift: cannot read commit $COMMIT in $ORG/$one" >&2
    exit 2
  }
  COMMIT=$full

  info=$(commit_info "$one" "$COMMIT")
  [ -n "$info" ] || {
    echo "org-drift: cannot read commit $COMMIT in $ORG/$one" >&2
    exit 2
  }
  c_date=$(printf '%s' "$info" | cut -f1)
  c_who=$(printf '%s' "$info" | cut -f2)
  c_subj=$(printf '%s' "$info" | cut -f3)

  prs=$(commit_pr_count "$one" "$COMMIT")
  [ "$prs" = '?' ] && {
    echo "org-drift: cannot read the pull requests associated with $COMMIT" >&2
    exit 2
  }

  short=$(printf '%s' "$COMMIT" | cut -c1-8)
  if [ "$prs" -gt 0 ]; then
    echo "Commit \`$short\` is associated with $prs pull request(s). Arrived through review."
    exit 0
  fi
  if subject_names_pr "$c_subj"; then
    cat <<EOF
Commit \`$short\` has no associated pull request, but its subject names one:

    $c_subj

GitHub loses that association when history is rewritten, so this is reported and
NOT failed. If no history was rewritten recently, treat it as a direct push.
EOF
    exit 0
  fi

  cat <<EOF
## Direct push to \`$ORG/$one\`

| | |
|---|---|
| Commit | \`$COMMIT\` |
| Author | $c_who |
| Date | $c_date |
| Subject | $c_subj |

This commit reached the default branch with **no associated pull request**. It
should have gone through a branch and a pull request:

    git switch -c fix/<something> $short
    gh pr create

**This check ran after the ref already moved** - it cannot undo the push. What to
do now: open a pull request for the change retrospectively if review still
matters, and run \`sh tooling/preflight.sh\` in every clone and agent worktree so
the next one is refused locally instead of reported here.
EOF
  exit 1
fi

if [ -n "$ONLY" ]; then
  repos=$ONLY
else
  repos=$(gh repo list "$ORG" --limit 200 --no-archived \
    --json name --jq '.[].name' | sort) ||
    { echo "org-drift: cannot list repositories in '$ORG'" >&2; exit 2; }
fi
[ -n "$repos" ] || { echo "org-drift: no repositories found in '$ORG'" >&2; exit 2; }

drift=0
direct_push_rows=''
rewritten_rows=''
posture_rows=''
notes=''

for repo in $repos; do
  progress "checking $ORG/$repo"
  meta=$(gh api "repos/$ORG/$repo" \
    --jq '[.private, (.default_branch // "main"), (.security_and_analysis.secret_scanning.status // "unavailable"), (.security_and_analysis.secret_scanning_push_protection.status // "unavailable")] | @tsv' 2>/dev/null) || {
    notes="$notes- \`$repo\`: could not be read with this token (skipped).
"
    continue
  }
  private=$(printf '%s' "$meta" | cut -f1)
  branch=$(printf '%s' "$meta" | cut -f2)
  ss=$(printf '%s' "$meta" | cut -f3)
  spp=$(printf '%s' "$meta" | cut -f4)
  [ "$private" = true ] && vis=private || vis=public

  # ---- branch protection -------------------------------------------------
  prot_out=$(gh api "repos/$ORG/$repo/branches/$branch/protection" 2>&1) && prot_rc=0 || prot_rc=$?
  if [ "$prot_rc" -eq 0 ]; then
    if printf '%s' "$prot_out" | tr ',' '\n' | grep -A1 'enforce_admins' | grep -q '"enabled":true'; then
      prot='on (admins bound)'
    else
      prot='on (**admins NOT bound**)'
      drift=1
    fi
    printf '%s' "$prot_out" | grep -q 'required_pull_request_reviews' ||
      { prot="$prot, **no PR required**"; drift=1; }
  elif printf '%s' "$prot_out" | grep -q 'Upgrade to GitHub Pro'; then
    prot='n/a (plan-gated)'
  elif printf '%s' "$prot_out" | grep -q 'Branch not protected'; then
    prot='**off**'
    [ "$vis" = public ] && drift=1
  else
    prot='unknown (API error)'
  fi

  case $ss in enabled) ssv='on' ;; unavailable) ssv='n/a (plan-gated)' ;; *) ssv="**$ss**" ;; esac
  case $spp in enabled) sppv='on' ;; unavailable) sppv='n/a (plan-gated)' ;; *) sppv="**$spp**" ;; esac

  # Does the repo call the shared hygiene workflow? That is the substitute for
  # the plan-gated secret scanning, so a private repo without it has no scanner.
  if gh api "repos/$ORG/$repo/contents/.github/workflows" --jq '.[].name' 2>/dev/null |
    grep -q .; then
    if gh api "search/code?q=repo:$ORG/$repo+path:.github/workflows+obilabs/.github" \
      --jq '.total_count' 2>/dev/null | grep -qv '^0$'; then
      hyg='yes'
    else
      # search/code is unreliable on fresh repos; fall back to fetching the file.
      if gh api "repos/$ORG/$repo/contents/.github/workflows/hygiene.yml" \
        --jq '.content' 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null |
        grep -q 'obilabs/.github/.github/workflows/hygiene.yml'; then
        hyg='yes'
      else
        hyg='**no**'
        drift=1
      fi
    fi
  else
    hyg='**no**'
    drift=1
  fi

  posture_rows="$posture_rows| \`$repo\` | $vis | $prot | $ssv | $sppv | $hyg |
"

  # ---- direct pushes to the default branch -------------------------------
  shas=$(gh api "repos/$ORG/$repo/commits?sha=$branch&since=$SINCE&per_page=100" \
    --jq '.[].sha' 2>/dev/null) || shas=''
  for sha in $shas; do
    prs=$(commit_pr_count "$repo" "$sha")
    [ "$prs" = '?' ] && continue
    if [ "$prs" -eq 0 ]; then
      info=$(commit_info "$repo" "$sha")
      d=$(printf '%s' "$info" | cut -f1)
      who=$(printf '%s' "$info" | cut -f2)
      subj=$(printf '%s' "$info" | cut -f3 | cut -c1-70 | tr '|' '/')
      row="| \`$repo\` | \`$(printf '%s' "$sha" | cut -c1-8)\` | $d | $who | $subj |
"
      # Rewritten history leaves commits whose PR association GitHub has lost;
      # see subject_names_pr above for why those are separated out rather than
      # reported as unreviewed work.
      if subject_names_pr "$subj"; then
        rewritten_rows="$rewritten_rows$row"
      else
        direct_push_rows="$direct_push_rows$row"
        drift=1
      fi
    fi
  done
done

# ------------------------------------------------------------------ report --
cat <<EOF
# ObiLabs governance drift - \`$ORG\`

Window: commits on the default branch since **$SINCE** (last $DAYS days).
Generated by \`tooling/org-drift.sh\`.

## Direct pushes to the default branch

EOF

if [ -n "$direct_push_rows" ]; then
  cat <<'EOF'
Commits below reached the default branch with **no associated pull request**.
On the Free plan a private repo cannot refuse these server-side, so this is a
report of something that already happened - not something that was blocked.

| Repo | Commit | Date | Author | Subject |
|---|---|---|---|---|
EOF
  printf '%s' "$direct_push_rows"
else
  echo "None found in this window."
fi

if [ -n "$rewritten_rows" ]; then
  cat <<'EOF'

### Unassociated, but the subject names a pull request

GitHub loses the commit-to-PR association when history is rewritten (ObiLabs did
this twice in 2026-09 to scrub identities and AI trailers). These commits look
unassociated but name a PR in their subject, so they were most likely merged
normally. Listed for completeness; they do NOT fail this check.

| Repo | Commit | Date | Author | Subject |
|---|---|---|---|---|
EOF
  printf '%s' "$rewritten_rows"
fi

cat <<'EOF'

## Protection and scanning posture

`n/a (plan-gated)` means GitHub sells this feature and the org is on the Free
plan; it is not a misconfiguration, and the substitute is the hygiene workflow
plus the local pre-push hook.

| Repo | Visibility | `main` protection | Secret scanning | Push protection | Hygiene workflow |
|---|---|---|---|---|---|
EOF
printf '%s' "$posture_rows"

if [ -n "$notes" ]; then
  echo ""
  echo "## Notes"
  echo ""
  printf '%s' "$notes"
fi

cat <<'EOF'

## What this can and cannot catch

**Catches:** a commit that reached the default branch without a pull request; a
repo whose protection or secret scanning was turned off; a repo that never
adopted the shared hygiene workflow.

**Cannot catch:** the push itself (detection is after the fact); a force-push
that erased the offending commit before this ran; a secret in a commit that was
later rewritten out of the branch; a direct push whose subject is dressed up to
look like a PR merge (the heuristic above is a courtesy, not a proof); anything
in a repository this token cannot read. Prevention on private repos needs
GitHub Team - see docs/GOVERNANCE.md.
EOF

exit "$drift"
