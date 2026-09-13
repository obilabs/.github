#!/bin/sh
# Test suite for the ObiLabs hygiene git hooks. POSIX sh; needs only git.
#
#   sh tooling/git-hooks/test/run.sh
#
# Everything runs against throwaway repos under a temp HOME with an isolated
# global git config, so the developer's real config is never touched.
# Fake credentials are assembled at runtime so this file itself stays clean.
set -u

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
hooks_src=$(dirname -- "$here")
repo_root=$(CDPATH='' cd -- "$hooks_src/../.." && pwd -P)

work=$(mktemp -d 2>/dev/null || mktemp -d -t hygiene-test)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM

export HOME="$work/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export GIT_CONFIG_NOSYSTEM=1
unset OBILABS_HYGIENE_SKIP OBILABS_ALLOW_MAIN_PUSH OBILABS_CONFIG_DIR OBILABS_HYGIENE_DENYLIST \
  GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL \
  GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true

git config --global user.name "Test Dev"
git config --global user.email "1+testdev@users.noreply.github.com"
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global core.autocrlf false
git config --global advice.ignoredHook false

pass=0
failed=0
log="$work/last.log"

ok() { pass=$((pass + 1)); echo "ok   - $1"; }
notok() {
  failed=$((failed + 1))
  echo "FAIL - $1"
  [ -f "$log" ] && sed 's/^/       | /' "$log"
}
expect_ok() {
  _d=$1; shift
  if "$@" >"$log" 2>&1; then ok "$_d"; else notok "$_d"; fi
}
expect_fail() {
  _d=$1; shift
  if "$@" >"$log" 2>&1; then notok "$_d (expected failure, got success)"; else ok "$_d"; fi
}
log_has() { # log_has <desc> <fixed string>
  if grep -qF -- "$2" "$log"; then ok "$1"; else notok "$1"; fi
}

n=0
new_repo() {
  n=$((n + 1))
  r="$work/repo$n"
  git init -q "$r"
  git -C "$r" commit -q --allow-empty -m "init"
}
g() { git -C "$r" "$@"; }
# stage_line <file> <content>
stage_line() { printf '%s\n' "$2" >>"$r/$1" && g add -- "$1"; }
commit() { g commit -q -m "${1:-test commit}"; }

# --- fake credential material, assembled so no literal appears in this file ---
aws_key="AKIA""ABCDEFGHIJKLMNOP"
gh_token="ghp_""abcdefghijklmnopqrstuvwxyz0123456789"
pk_header="-----BEGIN RSA ""PRIVATE KEY-----"
win_path="C:""\\Users\\bob\\project\\file.txt"
mac_path="\"/Us""ers/bob/project/file.txt\""
linux_path="cd /ho""me/bob/project/"

echo "# syntax"
for f in pre-commit commit-msg pre-push hygiene-lib.sh install.sh test/run.sh; do
  expect_ok "sh -n $f" sh -n "$hooks_src/$f"
done

echo "# install"
expect_ok "install.sh succeeds" sh "$hooks_src/install.sh"
hp=$(git config --global --get core.hooksPath)
if [ "$hp" = '~/.config/obilabs/git-hooks' ]; then ok "global core.hooksPath is ~-relative"; else notok "global core.hooksPath is ~-relative (got '$hp')"; fi
if [ -x "$HOME/.config/obilabs/git-hooks/pre-commit" ] && [ -f "$HOME/.config/obilabs/git-hooks/hygiene-lib.sh" ]; then
  ok "hooks copied to ~/.config/obilabs/git-hooks"
else
  notok "hooks copied to ~/.config/obilabs/git-hooks"
fi
if [ -f "$HOME/.config/obilabs/hygiene-denylist" ]; then ok "denylist created"; else notok "denylist created"; fi
expect_ok "install.sh is idempotent" sh "$hooks_src/install.sh"

echo "# commit identity"
new_repo
stage_line a.txt hello
expect_fail "gmail user.email blocks commit" g -c user.email=someone@gmail.com commit -q -m x
log_has "block message names noreply fix" "noreply"
expect_fail "googlemail author env blocks commit" env GIT_AUTHOR_EMAIL=Someone@GoogleMail.com git -C "$r" commit -q -m x
expect_ok "noreply identity commits" commit

echo "# secrets in added lines"
new_repo
stage_line creds.txt "aws = $aws_key"
expect_fail "AWS access key id blocks commit" commit
log_has "hit reports file:line and rule" "creds.txt:1  [aws-access-key-id]"
log_has "message explains the allow marker" "hygiene:allow"
g reset -q
rm -f "$r/creds.txt"
stage_line token.txt "token=$gh_token"
expect_fail "GitHub token blocks commit" commit
g reset -q
rm -f "$r/token.txt"
stage_line key.txt "$pk_header"
expect_fail "private key header blocks commit" commit
g reset -q
rm -f "$r/key.txt"
stage_line fixture.txt "fake = $aws_key  # hygiene:allow"
expect_ok "hygiene:allow marker permits the line" commit
stage_line fixture.txt "unrelated new line"
expect_ok "pre-existing allowed line is not rescanned" commit

echo "# user-home paths"
new_repo
stage_line p.txt "$win_path"
expect_fail "Windows user-home path blocks commit" commit
g reset -q; rm -f "$r/p.txt"
stage_line p.txt "$mac_path"
expect_fail "macOS user-home path blocks commit" commit
g reset -q; rm -f "$r/p.txt"
stage_line p.txt "$linux_path"
expect_fail "Linux user-home path blocks commit" commit
g reset -q; rm -f "$r/p.txt"
stage_line p.txt "see https://example.com/home/about/ for details"
expect_ok "URL containing /home/ is not a user path" commit

echo "# user-local denylist"
new_repo
printf '%s\n' "secret-codename-zebra" >>"$HOME/.config/obilabs/hygiene-denylist"
stage_line notes.txt "project SECRET-CODENAME-ZEBRA kickoff"
expect_fail "denylist entry blocks commit (case-insensitive)" commit
log_has "denylist hit is reported" "[denylist entry]"
g reset -q; rm -f "$r/notes.txt"

echo "# credential-shaped filenames"
new_repo
for bad in .env config/.env.local server.pem cert.p12 my-service-account-prod.json credentials.json; do
  mkdir -p "$(dirname "$r/$bad")"
  stage_line "$bad" "x=1"
  expect_fail "staging $bad blocks commit" commit
  g reset -q
  rm -f "$r/$bad"
done
for good in .env.example .env.sample env.example; do
  stage_line "$good" "KEY="
  expect_ok "staging $good is allowed" commit
done

echo "# global escape hatch"
new_repo
stage_line creds.txt "aws = $aws_key"
expect_ok "OBILABS_HYGIENE_SKIP=1 allows the commit" env OBILABS_HYGIENE_SKIP=1 git -C "$r" commit -q -m skip
log_has "skip prints a loud warning" "SKIPPED"

echo "# commit-msg trailer stripping"
new_repo
printf 'Add feature\n\nBody text.\n\nCo-authored-by: Alice <1+alice@users.noreply.github.com>\nCo-Authored-By: Claude Opus <noreply@anthropic.com>\n' >"$work/msg1"
printf '\360\237\244\226 Generated with [Claude Code](https://claude.com/claude-code)\n\n\n' >>"$work/msg1"
stage_line m.txt msg
expect_ok "commit with AI trailer succeeds" g commit -q -F "$work/msg1"
g log -1 --format=%B >"$log"
if grep -qiE 'claude|anthropic' "$log"; then notok "AI trailer and attribution removed"; else ok "AI trailer and attribution removed"; fi
log_has "human co-author trailer kept" "Co-authored-by: Alice"
printf 'subject\n\nbody\nco-authored-by: claude <noreply@anthropic.com>\n\n\n' >"$work/msg2"
printf 'subject\n\nbody\n' >"$work/msg2.expected"
(cd "$work" && sh "$HOME/.config/obilabs/git-hooks/commit-msg" msg2) >"$log" 2>&1
if cmp -s "$work/msg2" "$work/msg2.expected"; then ok "trailing blank lines trimmed"; else notok "trailing blank lines trimmed"; fi
printf 'fine message\n' >"$work/msg3"
expect_ok "commit-msg never fails on a clean message" sh "$HOME/.config/obilabs/git-hooks/commit-msg" "$work/msg3"

echo "# pre-push"
new_repo
remote="$work/remote$n.git"
git init -q --bare "$remote"
g remote add origin "$remote"
expect_fail "push to main is refused" g push -q origin main
log_has "refusal explains the PR route" "pull request"
expect_ok "OBILABS_ALLOW_MAIN_PUSH=1 allows push to main" env OBILABS_ALLOW_MAIN_PUSH=1 git -C "$r" push -q origin main
g checkout -q -b master
expect_fail "push to master is refused" g push -q origin master
g checkout -q main
g checkout -q -b feature
stage_line f.txt feature
commit
expect_ok "push of a clean feature branch succeeds" g push -q origin feature
expect_fail "refspec feature:main is refused" g push -q origin feature:main

g checkout -q -b gmail-branch
stage_line f.txt more
expect_ok "(setup) gmail commit via skip" env OBILABS_HYGIENE_SKIP=1 git -C "$r" -c user.email=dev@gmail.com commit -q -m gm
expect_fail "new branch with gmail-authored commit is refused" g push -q origin gmail-branch
log_has "offending identity listed" "dev@gmail.com"

g checkout -q feature
stage_line f.txt again
printf 'Fix thing\n\nCo-authored-by: Claude <noreply@anthropic.com>\n' >"$work/msg4"
expect_ok "(setup) trailer commit via --no-verify" g commit -q --no-verify -F "$work/msg4"
expect_fail "existing branch with AI trailer commit is refused" g push -q origin feature
g reset -q --hard origin/feature

echo "# chaining to repo hooks"
new_repo
remote="$work/remote$n.git"
git init -q --bare "$remote"
g remote add origin "$remote"
hookdir=$(g rev-parse --git-common-dir)
case $hookdir in /* | [A-Za-z]:*) ;; *) hookdir="$r/$hookdir" ;; esac
mkdir -p "$hookdir/hooks"
printf '#!/bin/sh\necho ran >"%s"\nexit 1\n' "$work/pc.mark" >"$hookdir/hooks/pre-commit"
printf '#!/bin/sh\necho "chained-by-repo-hook" >>"$1"\n' >"$hookdir/hooks/commit-msg"
printf '#!/bin/sh\necho "args:$1" >"%s"\ncat >>"%s"\n' "$work/pp.mark" "$work/pp.mark" >"$hookdir/hooks/pre-push"
chmod +x "$hookdir/hooks/pre-commit" "$hookdir/hooks/commit-msg" "$hookdir/hooks/pre-push"
stage_line c.txt chained
expect_fail "repo pre-commit hook runs and its failure is honoured" commit
if [ -f "$work/pc.mark" ]; then ok "repo pre-commit hook was invoked"; else notok "repo pre-commit hook was invoked"; fi
rm -f "$hookdir/hooks/pre-commit"
expect_ok "commit succeeds without the failing repo hook" commit
if g log -1 --format=%B | grep -q chained-by-repo-hook; then ok "repo commit-msg hook chained with args"; else notok "repo commit-msg hook chained with args"; fi
g checkout -q -b topic
expect_ok "push with repo pre-push hook succeeds" g push -q origin topic
if grep -q "args:origin" "$work/pp.mark" 2>/dev/null && grep -q "refs/heads/topic" "$work/pp.mark"; then
  ok "repo pre-push hook received args and stdin"
else
  notok "repo pre-push hook received args and stdin"
fi

echo "# CI workflow stays in sync with the hooks"
extract_rules() { sed -n '/# BEGIN path-rules/,/# END path-rules/p' "$1" | sed 's/^[[:space:]]*//'; }
extract_rules "$hooks_src/hygiene-lib.sh" >"$work/rules.lib"
extract_rules "$repo_root/.github/workflows/hygiene.yml" >"$work/rules.ci"
if [ -s "$work/rules.lib" ] && cmp -s "$work/rules.lib" "$work/rules.ci"; then
  ok "path rules identical in hygiene-lib.sh and hygiene.yml"
else
  diff "$work/rules.lib" "$work/rules.ci" >"$log" 2>&1
  notok "path rules identical in hygiene-lib.sh and hygiene.yml"
fi

echo ""
echo "passed: $pass  failed: $failed"
[ "$failed" -eq 0 ]
