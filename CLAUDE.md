# obilabs/.github: notes for the agent working on this repo

The org's shared hygiene tooling and its public profile. Nothing product-specific
lives here. Read `tooling/README.md` first — it states the policy and the three
layers that enforce it.

## What is in here, and who depends on it

- `.github/workflows/hygiene.yml` — the **reusable** workflow every ObiLabs repo
  calls as `uses: obilabs/.github/.github/workflows/hygiene.yml@main`. It is
  consumed from `@main`, so a change here reaches every repository on its next
  push. Treat it as production: a broken step blocks every PR in the org.
- `tooling/git-hooks/` — the local hooks, installed once per machine to
  `~/.config/obilabs/git-hooks` via `install.sh` / `install.ps1`. The path rules
  in the hooks and in the reusable workflow are duplicated by necessity;
  `tooling/git-hooks/test/run.sh` fails if the two blocks drift, so change both
  in the same commit and run the tests.
- `tooling/repo-template/` — the fragments (`SECURITY.md`, `README-footer.md`,
  `.gitignore`) applied to a repository that already exists. A new repository is
  created from `obilabs/repo-template` itself. Note: the org docs refer to a
  `tooling/new-repo.sh` that does not exist in this repo yet; creating one (repo
  from template, then branch protection with `enforce_admins`, secret scanning
  and push protection) would make the documented path real.
- `workflow-templates/` — what the GitHub "new workflow" UI offers org members.
- `profile/README.md` — the org's public front page. It is marketing copy read by
  strangers: under-promise, describe what works today.
- `SECURITY.md` — the org-wide default security policy. A repository without its
  own SECURITY.md inherits this one, so keep the reporting route correct.

## Rules

- Changes to the reusable workflow or the hooks are **fail-closed by design**: an
  unresolvable commit range or a tool error must fail the job, never pass quietly.
  Keep it that way.
- Do not weaken a check to make a specific repository's PR go green — fix the
  repository, or add a documented `hygiene:allow` on the individual line.
- The policy table in `tooling/README.md` is the readable form of the engineering
  principles that are canonical in the private `obilabs/north-star` repo
  (`PRINCIPLES.md`). Point at the canon; do not copy it in.

## Commits and identity

- Commit as `Michael Agu <36439190+openmoto@users.noreply.github.com>` (or your own
  GitHub noreply address). This repo *is* the thing that enforces that rule.
- **No AI co-author trailers** (`Co-authored-by: Claude …`) and no "Generated with
  Claude Code" lines. AI-assisted development is disclosed once, per repo README.
- Work on a branch and land it through a pull request. Never commit to,
  force-push or `git branch -f` `main`.
- Public repository: routine engineering wording in commits, PR titles and PR
  bodies. Never narrate a security finding here.
