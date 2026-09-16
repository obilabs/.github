# shellcheck shell=sh
# ONE definition of the "this commit subject names a pull request" heuristic,
# sourced by tooling/org-drift.sh and tooling/preflight.sh. Two copies of a
# heuristic drift apart, and then two tools disagree about the same commit.
#
# Rewriting history (the 2026-09 identity and AI-trailer scrubs) makes GitHub
# lose the commit-to-PR association even for commits that WERE merged through a
# pull request; those commits still say "(#123)". Treating them as direct pushes
# cries wolf, so both tools set them aside instead.
#
# This is a courtesy against false alarms, NOT proof of review: a direct push
# with a subject ending in "(#123)" passes it. Only the GitHub API association
# (org-drift.sh) or branch protection can tell you more.

# subject_names_pr <subject> : true when the subject names a pull request.
subject_names_pr() {
  printf '%s' "$1" | grep -Eq '\(#[0-9]+\)|^Merge pull request #[0-9]+'
}
