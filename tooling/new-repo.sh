#!/bin/sh
# Create an ObiLabs repository from obilabs/repo-template and apply the standard settings.
#
#   sh tooling/new-repo.sh <name> <public|private>
#
# Public repos get: secret scanning, push protection, Dependabot alerts and security updates,
# private vulnerability reporting, and main protection that binds admins and requires the
# hygiene check (proven by a refused push). Private repos on the Free plan cannot be
# protected; they get Dependabot alerts, and the local pre-push hook guards main.
set -eu

name=${1:-}
vis=${2:-}
org=obilabs
case "$vis" in public|private) ;; *) echo "usage: sh tooling/new-repo.sh <name> <public|private>" >&2; exit 2 ;; esac
[ -n "$name" ] || { echo "usage: sh tooling/new-repo.sh <name> <public|private>" >&2; exit 2; }
repo="$org/$name"

gh repo create "$repo" "--$vis" --template "$org/repo-template"
echo "created $repo ($vis)"

gh api -X PUT "repos/$repo/vulnerability-alerts" >/dev/null
echo "dependabot alerts: on"

if [ "$vis" = public ]; then
  gh api -X PATCH "repos/$repo" \
    -F 'security_and_analysis[secret_scanning][status]=enabled' \
    -F 'security_and_analysis[secret_scanning_push_protection][status]=enabled' >/dev/null
  gh api -X PUT "repos/$repo/automated-security-fixes" >/dev/null
  gh api -X PUT "repos/$repo/private-vulnerability-reporting" >/dev/null
  echo "secret scanning, push protection, security updates, private reporting: on"

  # The template's first commit already ran the hygiene workflow once, so the check name exists.
  printf '%s' '{"required_status_checks":{"strict":false,"contexts":["hygiene / Leak prevention"]},"enforce_admins":true,"required_pull_request_reviews":{"required_approving_review_count":0},"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}' \
    | gh api -X PUT "repos/$repo/branches/main/protection" --input - >/dev/null
  echo "main protection: PR required, admins bound, hygiene check required"

  # Prove it: a protection nobody has tested is a belief, not a control.
  tmp=$(mktemp -d)
  git clone -q --depth 1 "https://github.com/$repo.git" "$tmp/r"
  if (cd "$tmp/r" && git commit -q --allow-empty -m "protection probe" \
        && OBILABS_ALLOW_MAIN_PUSH=1 git push origin HEAD:main 2>&1 | grep -q "GH006\|declined"); then
    echo "main protection: proven (direct push refused)"
  else
    echo "WARNING: direct push to main was NOT refused - check protection on $repo" >&2
    rm -rf "$tmp"; exit 1
  fi
  rm -rf "$tmp"
else
  echo "private repo on the Free plan: no branch protection available; the pre-push hook guards main"
fi

echo "next: clone it, replace the README, add the LICENSE for its product line"
