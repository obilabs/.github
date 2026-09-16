# Governance: what is enforced, what is only detected

ObiLabs is on the **GitHub Free** plan. That single fact decides most of what
follows: GitHub gates branch protection and secret scanning for **private**
repositories behind paid plans. Public repositories get both for free.

So the honest summary is:

| Repository | Direct push to `main` | Secrets |
|---|---|---|
| **Public** (aegis, helios, rubric, busyflag, baitcheck, .github, repo-template) | **Prevented** by branch protection with `enforce_admins` | **Prevented** by GitHub push protection, plus the CI gitleaks scan |
| **Private** (web, mtp, obilabs-platform, north-star, rubric-banks, obilabs.dev, baitcheck-dashboard) | **Prevented only on machines that installed the local hook.** Otherwise it succeeds and is **detected afterwards** | **Detected** by the CI gitleaks scan; the push itself is not blocked |

Nothing below closes that gap. It narrows it, and it makes the gap visible.

---

## Layer 1 - local git hooks (prevention, per machine)

Source: `tooling/git-hooks/`. Installed once per machine; `core.hooksPath` is set
globally to `~/.config/obilabs/git-hooks`.

They block, at `git commit` / `git push` time:

- a direct push to `main` or `master` (`pre-push`);
- a personal-webmail commit identity, in the working config **and** in any commit
  being pushed;
- `Co-authored-by: Claude` / "Generated with Claude Code" trailers;
- secrets, credential-shaped filenames, absolute user-home paths in added lines;
- anything on the machine's personal denylist.

Verified: `sh tooling/git-hooks/test/run.sh` - **62 assertions, all passing**,
including "push to main is refused", "refspec `feature:main` is refused", "AWS
access key id blocks commit", "GitHub token blocks commit", "private key header
blocks commit".

### Install on a new machine or a fresh agent worktree - one command

```sh
curl -fsSL https://raw.githubusercontent.com/obilabs/.github/main/tooling/bootstrap.sh | sh
```

`obilabs/.github` is public, so no token is needed. The script clones the repo
into a temp dir, runs the canonical `tooling/git-hooks/install.sh`, then verifies
`core.hooksPath` and the three hook files and **fails loudly** if any is missing.

**This is the weakest link in the whole design.** The hooks are per-machine
configuration, not a property of the repository. A new laptop, a rebuilt VM, a CI
runner, a fresh agent worktree, or a colleague's clone has none of them until
somebody runs that command. Two known ways they silently do not apply:

- a repository that sets its **own** `core.hooksPath` (husky and similar)
  overrides the global setting - run
  `sh tooling/git-hooks/install.sh <repo-dir>` and it prints the lines to chain
  the hygiene checks into that repo's hooks;
- `git push --no-verify`, or `OBILABS_ALLOW_MAIN_PUSH=1`, both by design.

Layer 3 exists because Layer 1 cannot be relied on.

## Layer 2 - CI hygiene workflow (detection, per repository)

Source: `.github/workflows/hygiene.yml`, called by every repo as:

```yaml
jobs:
  hygiene:
    uses: obilabs/.github/.github/workflows/hygiene.yml@main
```

Two modes:

| Mode | Trigger | What it scans |
|---|---|---|
| `scan: range` (default) | `pull_request`, `push` | Only the commits this PR or push introduces |
| `scan: full` | `schedule` | **Every commit reachable from every ref** - catches a secret that predates the workflow, or one that arrived through a direct push to an unprotected `main` |

Add the scheduled full-history pass to a repository alongside the existing job:

```yaml
on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: '17 6 * * 1'   # Mondays

jobs:
  hygiene:
    if: github.event_name != 'schedule'
    uses: obilabs/.github/.github/workflows/hygiene.yml@main
  hygiene-full:
    if: github.event_name == 'schedule'
    uses: obilabs/.github/.github/workflows/hygiene.yml@main
    with:
      scan: full
```

In `full` mode only the secret scan runs; the commit-identity, AI-trailer and
user-home-path checks stay on the incoming range, because they are a gate on new
commits and re-reporting years of history every week is noise, not signal.

### Why gitleaks and not trufflehog

Both are free, open source, run on private repos at no cost, and scan git
history. The decision:

| | gitleaks | trufflehog |
|---|---|---|
| Model | Regex/entropy rules, no network | Detect, then **verify** the credential by calling the provider |
| False positives | More, controlled by `.gitleaks.toml` | Far fewer on verified findings |
| Network in CI | None | Outbound calls to third parties **carrying the candidate secret** |
| Config | One TOML at the repo root | Filters/detectors on the command line |
| Already in use here | **Yes**, pinned by digest in `hygiene.yml` | No |

**Chosen: gitleaks.** The deciding argument is not accuracy, it is the network.
TruffleHog's advantage - verification - works by sending the candidate secret to
the provider from a CI runner. For a security and compliance product line that is
the wrong default, and it makes every scan depend on third-party availability.
gitleaks is hermetic: same input, same answer, no egress. It is also already
pinned and already trusted here, and swapping it for a second tool would violate
"single source of truth - no duplication" for no gain we can name.

Pinned by **digest**, not tag:

```
ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f
```

The scan **fails the build** on any finding, and also fails when gitleaks itself
errors - an unresolvable range must not look like a clean scan.

### Recording a false positive

In order of preference:

1. **Per line** - put `gitleaks:allow` in a comment on the offending line. For
   the user-home-path check the equivalent marker is `hygiene:allow`.
2. **Per pattern or path** - a `.gitleaks.toml` at the repository root; it is
   picked up automatically. Use it for test fixtures and generated files:

   ```toml
   [extend]
   useDefault = true

   [[rules]]
   id = "generic-api-key"
   [rules.allowlist]
   # A deliberately fake key in the replay fixtures. Reviewed 2026-09-16.
   paths = ['''^test/fixtures/google/.*\.json$''']
   ```

Every allowlist entry needs a comment saying **what** it is and **why** it is
safe. An allowlist without a reason is an unreviewed exception, and it lands
through a pull request like anything else.

Never disable the check to make a build green. If a real credential is found, the
job is to **rotate it first**, then clean the history - not to silence the
scanner.

## Layer 3 - org drift detector (detection, org-wide)

Source: `tooling/org-drift.sh`, scheduled by `.github/workflows/org-drift.yml`
(Mondays 13:23 UTC, plus `workflow_dispatch`).

Run it locally at any time:

```sh
sh tooling/org-drift.sh --days 7
sh tooling/org-drift.sh --days 30 --repo web --repo mtp
```

Exit codes: `0` clean, `1` drift found, `2` the check could not run.

### What it reports

1. **Commits on the default branch with no associated pull request** - i.e.
   somebody pushed straight to `main`. A squash- or merge-commit landed by a PR
   *is* associated with that PR, so an empty association means the commit got
   there another way.
2. Branch protection: on/off, and specifically whether **`enforce_admins`** is
   set. GitHub creates protection with `enforce_admins: false`, which makes the
   rule advice rather than a rule for an owner token - that is exactly how five
   commits reached `helios/main` unreviewed on 2026-09-10.
3. Secret scanning and push protection status per repo, with `n/a (plan-gated)`
   distinguished from "somebody turned it off".
4. Whether each repo calls the shared hygiene workflow at all. A private repo
   that does not has **no** secret scanning of any kind.

### What it cannot catch - read this part

- **The push itself.** This is an after-the-fact report. On the Free plan a
  private repo cannot refuse a direct push server-side, and no workflow can
  either: a workflow runs *after* the ref has already moved. Detection is the
  honest ceiling without a paid plan. Do not read a green run as "prevented".
- **A force-push that erased the evidence.** If the offending commit is gone from
  the branch before the next run, it is not in the report.
- **A secret that was rewritten out of the branch** between the push and the
  scheduled full scan.
- **A direct push dressed up as a PR merge.** GitHub loses the commit-to-PR
  association whenever history is rewritten (ObiLabs did this twice in 2026-09,
  for the gmail and Claude-trailer scrubs), so the detector puts commits that
  *name* a PR in their subject into a separate, non-failing section. A direct
  push with a subject ending in `(#123)` would land in that section too. The
  heuristic is a courtesy against false alarms, not a proof.
- **Anything the token cannot read.** Those repos are listed under "Notes" in the
  report rather than being silently counted as clean.
- **Windows between runs.** Weekly by default. Shorten the cron, or run the
  script by hand, if a window that long is not acceptable.

### Why a GitHub issue rather than only a job summary

The workflow writes **both**, but the issue is the delivery mechanism that
matters. A job summary is only seen by someone who opens the Actions run - which
is the person already paying attention. An issue notifies, survives until it is
closed, keeps a history of what drifted and when, and can be replied to. The
workflow keeps **one rolling issue** ("Governance drift on obilabs"): it updates
and reopens it while drift persists, and closes it with a comment when a run
comes back clean. The job summary costs nothing and gives each run its own
record.

### Setup this needs before it works

The default `GITHUB_TOKEN` cannot read other repositories in the org. Create a
**fine-grained PAT** scoped to all repositories in `obilabs`, with repository
permissions *Metadata: Read, Contents: Read, Pull requests: Read,
Administration: Read, Issues: Read and write*, and store it as the repository
secret **`ORG_GOVERNANCE_TOKEN`** in `obilabs/.github`. Without it the workflow
**fails** rather than reporting a false all-clear.

## Layer 4 - new repositories start correct

`sh tooling/new-repo.sh <name> <public|private>` creates the repo from
`obilabs/repo-template` and applies protection, `enforce_admins`, secret scanning
and push protection, Dependabot alerts and security updates, and squash-only
merge settings - then **reads the protection back to verify it**, prints what was
applied and what was skipped, and lists what still has to be clicked by hand.

On a private repo it prints a plain warning that protection is unavailable on
this plan and that the local pre-push hook is the only guard, and continues -
refusing to create the repo would not make the plan any different.

See `tooling/README.md` for the full interface.

---

## What a paid plan would change

| Want | Plan | Price (Sept 2026) |
|---|---|---|
| Branch protection / rulesets on **private** repos - a direct push to `main` actually **refused by the server**, on every machine, with no hook installed | **GitHub Team** | **$4 USD per user/month** ([github.com/pricing](https://github.com/pricing)) |
| Secret scanning and **push protection** on private repos - a secret rejected *before* it lands, instead of found afterwards by CI | **GitHub Secret Protection** (add-on, available on Team) | **$19 USD per active committer/month** ([Pricing calculator](https://github.com/pricing/calculator), [Introducing GitHub Secret Protection](https://github.blog/changelog/2025-03-04-introducing-github-secret-protection-and-github-code-security/)) |

With 2 filled seats today, GitHub Team is roughly **$8/month** and would convert
Layer 3's *detection* of direct pushes into *prevention* across all seven private
repos. That is the single highest-value line here, and it is the one to revisit
first if a direct push ever causes real damage.

Secret Protection at $19 per committer is a different order of money for a
narrower gain: gitleaks in CI already **finds** the same secrets, just after the
push rather than before. The gap it closes is the window between a secret landing
on GitHub's servers and CI reporting it - which matters a great deal for a public
repo (already covered free) and less for a private one. Not recommended at this
size.

Neither is an ObiLabs Principle-1 problem: both are operating expense out of
revenue, not dilution or debt. They are simply not worth buying yet, and this
document exists so that stays a decision rather than an assumption.
