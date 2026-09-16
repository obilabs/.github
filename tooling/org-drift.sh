#!/bin/sh
# ObiLabs governance drift detector.
#
#   sh tooling/org-drift.sh [--org obilabs] [--days 7] [--repo NAME]... [--quiet]
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

while [ $# -gt 0 ]; do
  case $1 in
    --org) ORG=${2:?--org needs a value}; shift 2 ;;
    --days) DAYS=${2:?--days needs a value}; shift 2 ;;
    --repo) ONLY="$ONLY $2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h | --help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "org-drift: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case $DAYS in
  '' | *[!0-9]*) echo "org-drift: --days must be a whole number" >&2; exit 2 ;;
esac

command -v gh >/dev/null 2>&1 || { echo "org-drift: gh is not installed" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "org-drift: gh is not authenticated" >&2; exit 2; }

progress() { [ "$QUIET" -eq 1 ] || echo "org-drift: $*" >&2; }

# ISO-8601 cutoff, DAYS ago. GNU date and BSD date disagree; try both.
SINCE=$(date -u -d "-${DAYS} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
  date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
  echo '')
[ -n "$SINCE" ] || { echo "org-drift: could not compute a date $DAYS days ago" >&2; exit 2; }

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
    # A squash- or merge-commit landed by a PR IS associated with that PR, so an
    # empty association means the commit reached the branch some other way.
    prs=$(gh api "repos/$ORG/$repo/commits/$sha/pulls" --jq '[.[].number] | length' 2>/dev/null || echo '?')
    [ "$prs" = '?' ] && continue
    if [ "$prs" -eq 0 ]; then
      info=$(gh api "repos/$ORG/$repo/commits/$sha" \
        --jq '[(.commit.author.date|split("T")[0]), (.commit.author.name), (.commit.message|split("\n")[0])] | @tsv' 2>/dev/null || echo '')
      d=$(printf '%s' "$info" | cut -f1)
      who=$(printf '%s' "$info" | cut -f2)
      subj=$(printf '%s' "$info" | cut -f3 | cut -c1-70 | tr '|' '/')
      row="| \`$repo\` | \`$(printf '%s' "$sha" | cut -c1-8)\` | $d | $who | $subj |
"
      # A rewritten history (the 2026-09 scrubs) leaves commits whose PR
      # association GitHub has lost, even though they were merged through a PR.
      # Those still name their PR in the subject, so separate them out rather
      # than crying wolf: unreviewed work does not usually say "(#123)".
      if printf '%s' "$subj" | grep -Eq '\(#[0-9]+\)|^Merge pull request #[0-9]+'; then
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
