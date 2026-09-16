#!/bin/sh
# Create a new ObiLabs repository from obilabs/repo-template and apply every
# governance setting the plan allows.
#
#   sh tooling/new-repo.sh <repo-name> <public|private> [--dry-run] [--no-clone]
#                          [--require-existing] [--require-check CONTEXT]...
#
# Idempotent: re-running against an existing repository re-applies the settings
# and reports them instead of failing. Settings GitHub gates behind a paid plan
# (branch protection and secret scanning on private repositories) are reported
# as SKIPPED with a plain warning; the script still exits 0, because on the Free
# plan the local pre-push hook is the only guard and refusing to create the repo
# would not change that.
#
# Canonical source: obilabs/.github, tooling/new-repo.sh.
set -eu

ORG=obilabs
TEMPLATE=obilabs/repo-template
NOREPLY_EMAIL=36439190+openmoto@users.noreply.github.com
NOREPLY_NAME='Michael Agu'
# The literal '~' is deliberate: install.sh stores a ~-relative core.hooksPath
# so the global git config carries no username-bearing absolute path.
# shellcheck disable=SC2088
HOOKS_PATH='~/.config/obilabs/git-hooks'

DRY_RUN=0
CLONE=1
NAME=''
VISIBILITY=''
REQUIRE_EXISTING=0
# Newline-separated list of required status-check contexts, empty by default:
# requiring a check a repository does not actually run would leave every pull
# request waiting forever.
REQUIRE_CHECKS=''

die() { echo "new-repo: $*" >&2; exit 1; }
usage() {
  cat >&2 <<EOF
usage: sh tooling/new-repo.sh <repo-name> <public|private> [--dry-run] [--no-clone]
                              [--require-existing] [--require-check CONTEXT]...

  <repo-name>   1-64 chars, letters/digits/._- , must start with a letter or digit
  public|private
  --dry-run          print the commands that would run; change nothing
  --no-clone         do not clone the new repository locally
  --require-existing fail instead of creating the repository (used by
                     tooling/apply-protection.sh, which must never create one)
  --require-check C  require status check "C" on main; repeat for several.
                     Only pass checks the repo really runs, or pull requests
                     will wait forever.
EOF
  exit 2
}

# ---------------------------------------------------------------- arguments --
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY_RUN=1; shift ;;
    --no-clone) CLONE=0; shift ;;
    --require-existing) REQUIRE_EXISTING=1; shift ;;
    --require-check)
      [ $# -ge 2 ] || die "--require-check needs a check name"
      REQUIRE_CHECKS="$REQUIRE_CHECKS$2
"
      shift 2
      ;;
    -h | --help) usage ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)
      if [ -z "$NAME" ]; then NAME=$1
      elif [ -z "$VISIBILITY" ]; then VISIBILITY=$1
      else die "unexpected extra argument: $1"
      fi
      shift
      ;;
  esac
done

[ -n "$NAME" ] && [ -n "$VISIBILITY" ] || usage

case $VISIBILITY in
  public | private) ;;
  *) die "visibility must be 'public' or 'private', got '$VISIBILITY'" ;;
esac

# GitHub allows more than this; we deliberately allow less so repo names stay
# predictable in URLs, image tags and directory names.
if [ "$REQUIRE_EXISTING" -eq 1 ]; then
  # The repo already exists, so GitHub's own naming rules have already been
  # applied to it; only reject characters that would be unsafe in a URL path.
  # (obilabs/.github is a real repository and starts with a dot.)
  if ! printf '%s' "$NAME" | grep -Eq '^[A-Za-z0-9._-]{1,64}$'; then
    die "invalid repo name '$NAME': use 1-64 chars of [A-Za-z0-9._-]"
  fi
elif ! printf '%s' "$NAME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'; then
  die "invalid repo name '$NAME': use 1-64 chars of [A-Za-z0-9._-], starting with a letter or digit"
fi
case $NAME in
  *..* | .git | *.git) die "invalid repo name '$NAME'" ;;
esac

# --------------------------------------------------------------- run helper --
# run <label> <command...> : echoes the command; executes it unless --dry-run.
# Returns the command's exit status (callers decide what a failure means).
run() {
  _label=$1
  shift
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

APPLIED=''
SKIPPED=''
note_applied() { APPLIED="$APPLIED  APPLIED  $1
"; }
note_skipped() { SKIPPED="$SKIPPED  SKIPPED  $1
"; }

# gh_api <method> <path> [extra args...] -> stdout=body, status in GH_API_RC.
# Captures stderr so the "Upgrade to GitHub Pro" message can be detected.
GH_API_OUT=''
GH_API_RC=0
gh_api() {
  _m=$1
  _p=$2
  shift 2
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] gh api -X %s %s %s\n' "$_m" "$_p" "$*"
    GH_API_OUT=''
    GH_API_RC=0
    return 0
  fi
  GH_API_RC=0
  GH_API_OUT=$(gh api -X "$_m" "$_p" "$@" 2>&1) || GH_API_RC=$?
  return 0
}

# True when the last gh_api failure was GitHub refusing on plan grounds.
plan_gated() {
  case $GH_API_OUT in
    *'Upgrade to GitHub Pro'* | *'not available for this repository'* | \
      *'Advanced Security'* | *'upgrade your plan'*) return 0 ;;
  esac
  return 1
}

# ------------------------------------------------------- 1. preflight checks --
echo "==> Preflight"
command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is not installed - https://cli.github.com"
command -v git >/dev/null 2>&1 || die "git is not installed"

auth=$(gh auth status 2>&1) || die "gh is not authenticated. Run: gh auth login"
printf '%s\n' "$auth" | sed 's/^/  /'

# Classic OAuth tokens report their scopes; fine-grained PATs and GitHub App
# tokens (including Actions' GITHUB_TOKEN) report none, and their permissions
# cannot be read from here. Check what we can, and say so when we cannot.
scopes=$(printf '%s
' "$auth" | sed -n 's/.*Token scopes: *//p' | tr -d "'" | tr ',' ' ' | tr -s ' ')
case $scopes in
  '' | ' ')
    echo "  NOTE: this token reports no OAuth scopes (fine-grained PAT or GitHub App"
    echo "        token), so its permissions cannot be checked here. It needs, on all"
    echo "        $ORG repositories: Administration: Read and write, Contents: Read"
    echo "        and write, Metadata: Read. Steps below fail plainly if it does not."
    ;;
  *)
    missing=''
    for need in repo read:org workflow; do
      case " $scopes " in
        *" $need "*) ;;
        *) missing="$missing $need" ;;
      esac
    done
    if [ -n "$missing" ]; then
      die "the authenticated gh token is missing scope(s):$missing
  Add them with: gh auth refresh -h github.com -s $(echo "$missing" | tr ' ' ',' | sed 's/^,//')"
    fi
    ;;
esac

if [ "$DRY_RUN" -eq 0 ]; then
  gh api "orgs/$ORG" >/dev/null 2>&1 ||
    die "cannot read the '$ORG' organisation with this token (need 'read:org' and membership)"
fi

REPO="$ORG/$NAME"
echo "  Target: $REPO ($VISIBILITY)"
[ "$DRY_RUN" -eq 1 ] && echo "  DRY RUN - nothing will be created or changed."

# --------------------------------------------------- 2. create from template --
echo "==> Repository"
exists=0
# Read-only, so it runs in --dry-run too: the dry run should show the same
# branch (create vs re-apply) that a real run would take.
if gh repo view "$REPO" >/dev/null 2>&1; then exists=1; fi

if [ "$exists" -eq 1 ]; then
  echo "  $REPO already exists - re-applying settings (idempotent)."
  note_applied "repository already existed; not recreated"
  cur=$(gh repo view "$REPO" --json visibility --jq '.visibility' | tr 'A-Z' 'a-z')
  if [ "$cur" != "$VISIBILITY" ]; then
    echo "  WARNING: existing visibility is '$cur', not '$VISIBILITY'. Not changing it:"
    echo "           flipping visibility is a deliberate decision, not a setup step."
    note_skipped "visibility change $cur -> $VISIBILITY (change it by hand if intended)"
    VISIBILITY=$cur
  fi
elif [ "$REQUIRE_EXISTING" -eq 1 ]; then
  die "$REPO does not exist, and --require-existing was given. This mode only
  re-applies settings to repositories that already exist; it never creates one."
else
  run "create" gh repo create "$REPO" \
    --template "$TEMPLATE" \
    --"$VISIBILITY" \
    --description "" ||
    die "gh repo create failed for $REPO"
  if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] would create $REPO from $TEMPLATE."; else echo "  Created $REPO from $TEMPLATE."; fi
  note_applied "created from $TEMPLATE ($VISIBILITY)"
  # GitHub populates a templated repo asynchronously; give main a moment to appear.
  if [ "$DRY_RUN" -eq 0 ]; then
    i=0
    while [ "$i" -lt 30 ]; do
      gh api "repos/$REPO/branches/main" >/dev/null 2>&1 && break
      i=$((i + 1))
      sleep 2
    done
    [ "$i" -lt 30 ] || echo "  WARNING: 'main' did not appear within 60s; later steps may fail."
  fi
fi

# ------------------------------------------------------- 3. branch protection --
echo "==> Branch protection on main"
protection_ok=0

# required_status_checks: null unless the caller named checks this repo really
# runs. Built as JSON rather than -F flags so a list can be passed at all.
checks_json=null
if [ -n "$REQUIRE_CHECKS" ]; then
  _ctx=''
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    # Only the two characters JSON strings must escape appear in check names.
    c=$(printf '%s' "$c" | sed 's/\\/\\\\/g; s/"/\\"/g')
    _ctx="$_ctx\"$c\","
  done <<EOF
$REQUIRE_CHECKS
EOF
  checks_json="{\"strict\":true,\"contexts\":[${_ctx%,}]}"
  echo "  Requiring status check(s): $(printf '%s' "$REQUIRE_CHECKS" | tr '\n' ' ')"
fi

PROT_BODY=$(mktemp) || die "cannot create a temporary file"
trap 'rm -f "$PROT_BODY"' EXIT INT TERM
cat >"$PROT_BODY" <<EOF
{
  "required_pull_request_reviews": {
    "required_approving_review_count": 0,
    "dismiss_stale_reviews": true
  },
  "required_status_checks": $checks_json,
  "enforce_admins": true,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true,
  "required_conversation_resolution": true
}
EOF

gh_api PUT "repos/$REPO/branches/main/protection" \
  -H "Accept: application/vnd.github+json" \
  --input "$PROT_BODY"

if [ "$GH_API_RC" -eq 0 ]; then
  # enforce_admins must be set explicitly too: the PUT above can silently leave
  # it false, which is how five commits reached helios/main unreviewed.
  gh_api POST "repos/$REPO/branches/main/protection/enforce_admins"
  if [ "$DRY_RUN" -eq 1 ]; then
    protection_ok=1
  else
    read_back=$(gh api "repos/$REPO/branches/main/protection" 2>/dev/null || true)
    pr_req=$(printf '%s' "$read_back" | grep -c 'required_pull_request_reviews' || true)
    adm=$(printf '%s' "$read_back" |
      tr ',' '\n' | grep -A1 'enforce_admins' | grep -c '"enabled":true' || true)
    checks_ok=1
    if [ -n "$REQUIRE_CHECKS" ]; then
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        printf '%s' "$read_back" | grep -qF "$c" || {
          echo "  WARNING: required check '$c' did not read back." >&2
          checks_ok=0
        }
      done <<EOF
$REQUIRE_CHECKS
EOF
    fi
    if [ "$pr_req" -gt 0 ] && [ "$adm" -gt 0 ] && [ "$checks_ok" -eq 1 ]; then
      echo "  Verified: pull request required on main, and admins are bound by it."
      [ -n "$REQUIRE_CHECKS" ] && echo "  Verified: required status check(s) are set."
      protection_ok=1
      note_applied "branch protection on main (PR required, enforce_admins=true, no force-push, no deletion)"
      [ -n "$REQUIRE_CHECKS" ] &&
        note_applied "required status check(s): $(printf '%s' "$REQUIRE_CHECKS" | tr '\n' ' ')"
    else
      echo "  WARNING: protection was written but did not read back as expected." >&2
      printf '%s\n' "$read_back" | head -c 600 | sed 's/^/    /' >&2
      note_skipped "branch protection could not be VERIFIED - check it by hand"
    fi
  fi
elif plan_gated; then
  cat <<EOF
  SKIPPED - GitHub gates branch protection on private repositories behind a paid
  plan, and this organisation is on the Free plan. GitHub's reply:
    $(printf '%s' "$GH_API_OUT" | head -c 200)

  WARNING: nothing on the server will stop a direct push to main in this repo.
  The ONLY guard is the local pre-push hook, on machines where it is installed:
      sh tooling/git-hooks/install.sh
  The scheduled org drift detector (tooling/org-drift.sh) will REPORT a direct
  push after the fact; it cannot prevent one. See docs/GOVERNANCE.md.
EOF
  note_skipped "branch protection (plan-gated on a private repo; local hook is the only guard)"
else
  echo "  WARNING: branch protection failed for a reason other than the plan:" >&2
  printf '%s\n' "$GH_API_OUT" | head -c 400 | sed 's/^/    /' >&2
  note_skipped "branch protection (unexpected API error - see above)"
fi

# ---------------------------------------------------------- 4. security knobs --
echo "==> Secret scanning and Dependabot"

set_analysis() {
  _label=$1
  _payload=$2
  gh_api PATCH "repos/$REPO" -H "Accept: application/vnd.github+json" \
    --input - <<EOF
$_payload
EOF
  if [ "$GH_API_RC" -eq 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] would enable: $_label"; else echo "  Enabled: $_label"; fi
    note_applied "$_label"
  elif plan_gated; then
    echo "  SKIPPED: $_label - plan-gated on a private repository (Free plan)."
    note_skipped "$_label (plan-gated; the CI gitleaks scan is the substitute)"
  else
    echo "  WARNING: $_label failed:" >&2
    printf '%s\n' "$GH_API_OUT" | head -c 300 | sed 's/^/    /' >&2
    note_skipped "$_label (unexpected API error)"
  fi
}

set_analysis "secret scanning" \
  '{"security_and_analysis":{"secret_scanning":{"status":"enabled"}}}'
set_analysis "secret scanning push protection" \
  '{"security_and_analysis":{"secret_scanning_push_protection":{"status":"enabled"}}}'

# Dependabot ALERTS work on private repos on the Free plan.
gh_api PUT "repos/$REPO/vulnerability-alerts"
if [ "$GH_API_RC" -eq 0 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] would enable: Dependabot alerts"; else echo "  Enabled: Dependabot alerts"; fi
  note_applied "Dependabot alerts"
else
  echo "  WARNING: Dependabot alerts could not be enabled:" >&2
  printf '%s\n' "$GH_API_OUT" | head -c 300 | sed 's/^/    /' >&2
  note_skipped "Dependabot alerts"
fi

gh_api PUT "repos/$REPO/automated-security-fixes"
if [ "$GH_API_RC" -eq 0 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] would enable: Dependabot security updates"; else echo "  Enabled: Dependabot security updates"; fi
  note_applied "Dependabot security updates"
elif plan_gated; then
  echo "  SKIPPED: Dependabot security updates - plan-gated."
  note_skipped "Dependabot security updates (plan-gated)"
else
  echo "  WARNING: Dependabot security updates could not be enabled:" >&2
  printf '%s\n' "$GH_API_OUT" | head -c 300 | sed 's/^/    /' >&2
  note_skipped "Dependabot security updates"
fi

# Merge hygiene: squash only, delete the branch after merge, no merge commits.
gh_api PATCH "repos/$REPO" -H "Accept: application/vnd.github+json" --input - <<'EOF'
{"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false,
 "delete_branch_on_merge":true,"has_wiki":false,"has_projects":false}
EOF
if [ "$GH_API_RC" -eq 0 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] would set squash-merge only + delete branch on merge"; else echo "  Set: squash-merge only, delete branch on merge, wiki/projects off"; fi
  note_applied "merge settings (squash only, delete branch on merge)"
else
  note_skipped "merge settings"
fi

# ----------------------------------------------------------- 5. local clone --
echo "==> Local clone"
if [ "$CLONE" -eq 0 ]; then
  echo "  Skipped (--no-clone)."
  note_skipped "local clone (--no-clone)"
elif [ "$DRY_RUN" -eq 1 ]; then
  printf '  [dry-run] gh repo clone %s\n' "$REPO"
  printf '  [dry-run] git -C %s config user.name "%s"\n' "$NAME" "$NOREPLY_NAME"
  printf '  [dry-run] git -C %s config user.email %s\n' "$NAME" "$NOREPLY_EMAIL"
  printf '  [dry-run] check core.hooksPath == %s\n' "$HOOKS_PATH"
elif [ -e "$NAME" ]; then
  echo "  '$NAME' already exists in $(pwd) - not cloning over it."
  note_skipped "local clone ('$NAME' already exists here)"
else
  if gh repo clone "$REPO" "$NAME" -- --quiet; then
    git -C "$NAME" config user.name "$NOREPLY_NAME"
    git -C "$NAME" config user.email "$NOREPLY_EMAIL"
    echo "  Cloned to ./$NAME"
    echo "  user.name  = $(git -C "$NAME" config user.name)"
    echo "  user.email = $(git -C "$NAME" config user.email)"
    note_applied "clone ./$NAME with the noreply commit identity"

    local_hp=$(git -C "$NAME" config --local --get core.hooksPath || true)
    global_hp=$(git config --global --get core.hooksPath || true)
    if [ -n "$local_hp" ]; then
      echo "  WARNING: this clone sets a LOCAL core.hooksPath ($local_hp);"
      echo "           it overrides the global ObiLabs hooks, so they will NOT run here."
      note_skipped "hooks active in the clone (local core.hooksPath overrides them)"
    elif [ "$global_hp" = "$HOOKS_PATH" ] || [ "$global_hp" = "$HOME/.config/obilabs/git-hooks" ]; then
      echo "  core.hooksPath = $global_hp (ObiLabs hygiene hooks active)"
      note_applied "ObiLabs hygiene hooks active in the clone"
    else
      echo "  WARNING: global core.hooksPath is '${global_hp:-unset}', not $HOOKS_PATH."
      echo "           Install the hooks on this machine:"
      echo "             sh tooling/git-hooks/install.sh"
      note_skipped "ObiLabs hygiene hooks NOT installed on this machine"
    fi
  else
    echo "  WARNING: clone failed." >&2
    note_skipped "local clone (clone failed)"
  fi
fi

# ------------------------------------------------------------- 6. summary ----
echo ""
echo "================================================================"
echo " $REPO ($VISIBILITY)"
echo "================================================================"
echo "Applied:"
[ -n "$APPLIED" ] && printf '%s' "$APPLIED" || echo "  (nothing)"
echo "Skipped:"
[ -n "$SKIPPED" ] && printf '%s' "$SKIPPED" || echo "  (nothing)"

cat <<EOF

Still to do by hand (the API cannot do these, or they are decisions):
  [ ] Replace README.md: what this does, who it is for, what works TODAY.
  [ ] Add a LICENSE for the product line - AGPL-3.0 (self-hosted products),
      Apache-2.0 (libraries and small tools), BSL 1.1 (MTP).
  [ ] Private vulnerability reporting: Settings > Security > "Private
      vulnerability reporting" (no API on the Free plan for private repos).
  [ ] Add package ecosystems to .github/dependabot.yml (npm, pip, docker, ...).
  [ ] If this repo will be called by the governance workflow on a schedule,
      confirm .github/workflows/hygiene.yml came across from the template.
EOF

if [ "$protection_ok" -eq 0 ] && [ "$VISIBILITY" = private ] && [ "$DRY_RUN" -eq 0 ]; then
  cat <<EOF
  [ ] READ THIS: main is UNPROTECTED on the server. Every machine that clones
      this repo must install the local hooks, or a direct push to main will
      succeed and only be noticed afterwards by the drift detector:
        sh tooling/git-hooks/install.sh
EOF
fi

echo ""
echo "Done."
