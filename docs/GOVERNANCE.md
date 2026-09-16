# Governance: what is enforced, what is only detected

ObiLabs is on the **GitHub Free** plan. That single fact decides most of what
follows: GitHub gates branch protection and secret scanning for **private**
repositories behind paid plans. Public repositories get both for free.

So the honest summary is:

| Repository | Direct push to `main` | Secrets |
|---|---|---|
| **Public** (aegis, helios, rubric, busyflag, baitcheck, .github, repo-template) | **Prevented** by branch protection with `enforce_admins` | **Prevented** by GitHub push protection, plus the CI gitleaks scan |
| **Private** (web, mtp, obilabs-platform, north-star, rubric-banks, obilabs.dev, baitcheck-dashboard) | **Prevented only on machines that installed the local hook.** Otherwise it succeeds, and is **detected within minutes** by the push guard - which fails the run and opens an issue, but cannot undo the push | **Detected** by the CI gitleaks scan; the push itself is not blocked |

Nothing below closes that gap. It narrows it, and it makes the gap visible.

## The layers, in the order they act

Read the label, not the intent. Only two of these can refuse anything.

| # | Layer | Label | Delay |
|---|---|---|---|
| 1 | `tooling/preflight.sh` before work starts | **ADVISES ONLY** - nothing runs it for you unless you wire in the SessionStart hook | none |
| 2 | Local git hooks (`tooling/git-hooks/`) | **PREVENTS**, on machines where they are installed, unless bypassed | none |
| 3 | GitHub branch protection (`enforce_admins`) | **PREVENTS**, server-side, no exceptions - **public repos only on the Free plan** | none |
| 4 | Push guard (`.github/workflows/push-guard.yml`) | **DETECTS** - the ref has already moved | ~1-2 minutes |
| 5 | CI hygiene workflow (`hygiene.yml`) | **DETECTS** secrets and identity per PR/push | minutes |
| 6 | Org drift detector (`tooling/org-drift.sh`) | **DETECTS**, org-wide, on a schedule | up to a week |
| 7 | `new-repo.sh` / `apply-protection.sh` | **PREVENTS** drift at setup time - applies 3 where the plan allows it | n/a |

Layer 3 is the only one that cannot be talked out of it. Everything else is
either skippable (1, 2) or after the fact (4, 5, 6).

---

## Layer 1 - preflight (ADVISES ONLY)

```sh
sh tooling/preflight.sh                 # from a clone of obilabs/.github
sh ~/.config/obilabs/preflight.sh       # installed copy, from any repo
curl -fsSL https://raw.githubusercontent.com/obilabs/.github/main/tooling/preflight.sh | sh
```

It checks the repository it is run **in**, not the one it lives in (`--dir PATH`
to point it elsewhere). Other repos do not carry a copy - use one of the last
two forms there.

Four checks, about a second (2-3 on Windows Git Bash), exit `1` with a plain
explanation of what to fix:

1. the ObiLabs hooks are active here (`core.hooksPath`, including the case where
   the repo sets its own and silences them);
2. `user.email` is the GitHub noreply address, not personal webmail;
3. the checkout is **not** on `main` / `master`;
4. remote `main` carries no commits whose subject fails to name a pull request,
   since the last tag (or the merge-base when the repo has no tags).

Check 4 is a **heuristic** - it reads subjects, not the GitHub API, because it
must stay offline-fast. It shares one definition of that heuristic with the
drift detector (`tooling/lib/pr-subject.sh`); confirm a hit with the
authoritative check before acting on it:

```sh
sh tooling/org-drift.sh --repo <name> --commit <sha>
```

**What it cannot do:** anything, unless it is run. It has no way to block a
commit or a push. It is the layer that tells an *agent* to stop, which is its
whole purpose - see the block below.

### The block to put in a repository's `CLAUDE.md`

Landing in `obilabs/repo-template` (obilabs/repo-template#1) so new
repositories inherit it. For an existing repo, paste this verbatim:

```markdown
## Preflight - run this before you touch anything

Before your first commit in this repo, run:

    curl -fsSL https://raw.githubusercontent.com/obilabs/.github/main/tooling/preflight.sh | sh

**If it exits non-zero: STOP.** Report the failure to the user, in full, and
wait for them. Do not commit, do not push, and do not work around it - not with
`--no-verify`, not with `OBILABS_HYGIENE_SKIP=1`, not with
`OBILABS_ALLOW_MAIN_PUSH=1`, and not by editing git config to make the check
pass. Those escape hatches exist for a human making a deliberate decision, not
for an agent clearing a blocker.

A failing preflight means one of: the hygiene hooks are not installed (nothing
local will stop a bad push), the commit identity would leak a personal address,
you are standing on `main`, or `main` already has commits that did not go
through a pull request. All four are the user's call, not yours.
```

### Making it non-optional (the one change that matters)

Advice becomes enforcement when the harness runs it for you. This snippet in
`~/.claude/settings.json` runs preflight at the start of every session, in that
session's working directory:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "sh \"$HOME/.config/obilabs/preflight.sh\" --quiet || echo 'OBILABS PREFLIGHT FAILED - stop and tell the user before committing or pushing.'"
          }
        ]
      }
    ]
  }
}
```

It expects a copy of the script at `~/.config/obilabs/preflight.sh`; put one
there with:

```sh
mkdir -p ~/.config/obilabs && cp tooling/preflight.sh ~/.config/obilabs/preflight.sh
```

This repository does **not** edit `~/.claude/settings.json` - that file is the
owner's, and a tool that silently rewrites a user's harness configuration is
exactly the kind of thing this document exists to prevent. Note the honest
limit: a SessionStart hook makes the result *visible* to the agent, it does not
make the agent obey. The obeying comes from the `CLAUDE.md` block above.

---

## Layer 2 - local git hooks (PREVENTS, per machine)

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

Layers 4 and 6 exist because this layer cannot be relied on.

---

## Layer 3 - GitHub branch protection (PREVENTS, server-side)

The only layer with no escape hatch: GitHub itself refuses the push, on every
machine, with nothing installed locally.

Two things have to be true, and the second is the one that gets missed:

- protection requires a pull request on `main`;
- **`enforce_admins` is on.** GitHub creates protection with `enforce_admins:
  false`, which makes it advice rather than a rule for an owner token - that is
  how five commits reached `helios/main` unreviewed on 2026-09-10.

```sh
gh api -X POST repos/obilabs/<repo>/branches/main/protection/enforce_admins
```

Proof, not belief: attempt a real push and confirm the remote answers
`protected branch hook declined`. `tooling/apply-protection.sh` applies and
reads back the whole set (Layer 7).

**Available today on public repos only.** On the Free plan GitHub answers
*"Upgrade to GitHub Pro"* for a private repo, so all seven private repos rely on
Layers 1, 2, 4 and 6 instead. See "The day GitHub Team is active" below.

---

## Layer 4 - push guard (DETECTS, minutes)

Source: `.github/workflows/push-guard.yml` - a reusable workflow, called by each
repository on `push` to `main`:

```yaml
name: Push guard
on:
  push:
    branches: [main]
permissions:
  contents: read
  pull-requests: read
  issues: write
jobs:
  push-guard:
    uses: obilabs/.github/.github/workflows/push-guard.yml@main
```

For **every commit in the push** (not just the tip) it asks GitHub whether that
commit is associated with a pull request, by calling the one implementation of
that question there is:

```sh
sh tooling/org-drift.sh --repo <name> --commit <sha>
```

A squash- or merge-commit landed by a PR **is** associated with it, so an empty
association means the commit arrived another way. A commit whose association
GitHub lost to a history rewrite still names its PR in the subject, and is
reported without failing.

On a violation the workflow **fails the run** and **opens (or updates) an issue
in the repository the push landed in**, naming the commit, its author, the
branch, and the `git switch -c` line that should have been used.

**What it changes:** the delay and the place. Layer 6 finds the same thing up to
a week later, in a different repository's issue tracker. This finds it in a
minute or two, where it happened, with a red X on the commit.

**What it cannot do:** stop the push. A workflow starts *after* the ref has
moved; nothing that runs in Actions can refuse a push. It also cannot see a
commit that was force-pushed away before it ran, and it is subject to the same
"subject names a PR" courtesy as Layer 6. Anyone who can push can also disable
the workflow - it is a tripwire, not a lock.

---

## Layer 5 - CI hygiene workflow (DETECTS, per repository)

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

## Layer 6 - org drift detector (DETECTS, org-wide, weekly)

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

## Layer 7 - repositories start, and stay, correct (PREVENTS drift at setup)

`sh tooling/new-repo.sh <name> <public|private>` creates the repo from
`obilabs/repo-template` and applies protection, `enforce_admins`, secret scanning
and push protection, Dependabot alerts and security updates, and squash-only
merge settings - then **reads the protection back to verify it**, prints what was
applied and what was skipped, and lists what still has to be clicked by hand.

On a private repo it prints a plain warning that protection is unavailable on
this plan and that the local pre-push hook is the only guard, and continues -
refusing to create the repo would not make the plan any different.

`sh tooling/apply-protection.sh <repo>...` or `--all` does the same for
repositories that **already exist**. It does not create anything and never
changes visibility: it calls `new-repo.sh --require-existing --no-clone` per
repo, so there is one implementation of the settings, then reads the protection
back **independently** and prints a table of what GitHub actually stored,
including which repositories the plan refused.

```sh
sh tooling/apply-protection.sh --all --dry-run          # read the plan
sh tooling/apply-protection.sh --all                    # apply it
sh tooling/apply-protection.sh web mtp --require-check auto
```

`--require-check auto` requires the hygiene status check on `main`, but only
where that check has actually reported on the default branch - requiring a check
a repository never runs leaves every pull request stuck on "Expected" forever.
A repo with no hygiene run is reported, not guessed at.

See `tooling/README.md` for the full interface.

---

## The day GitHub Team is active

GitHub Team ($4 USD per user/month) is what turns Layer 3 on for private
repositories. When the plan is active, in this order:

1. **Apply the whole set, everywhere.** Dry run first, then for real:

   ```sh
   sh tooling/apply-protection.sh --all --dry-run
   sh tooling/apply-protection.sh --all
   ```

   The private repos this must cover: **web, mtp, obilabs-platform, north-star,
   rubric-banks, obilabs.dev, baitcheck-dashboard**. (The org currently holds
   other private repos too - `--all` covers whatever exists on the day; the
   table it prints is the record of what was refused.)

2. **Confirm `enforce_admins` bound, by reading it back, not by believing the
   script.** `apply-protection.sh` does the read-back and prints
   `protected, PR required, **admins bound**` per repo. For the one repo you
   care most about, also prove it the hard way: try a direct push and confirm
   the remote answers `protected branch hook declined`.

3. **Require the hygiene check** where the repo runs it:

   ```sh
   sh tooling/apply-protection.sh --all --require-check auto
   ```

   A repo reported as having no hygiene run needs
   `.github/workflows/hygiene.yml` added first (see `tooling/README.md`), and
   the push guard from Layer 4 alongside it.

4. **Secret scanning and push protection:** the same command enables both and
   reports them. On Team they may still answer *plan-gated* - GitHub sells
   private-repo secret scanning as the separate **GitHub Secret Protection**
   add-on ($19 per active committer/month). If it is refused, that is the
   reason, and the CI gitleaks scan remains the substitute. Do not read a
   refusal as a misconfiguration.

5. **Re-run the drift detector** and expect the posture table to show
   `on (admins bound)` everywhere:

   ```sh
   sh tooling/org-drift.sh --days 7
   ```

What does **not** change on Team: Layers 1, 2 and 4 stay exactly as useful.
Protection stops the push to `main`, it does not stop a personal email address,
a secret, or an AI trailer from landing on a feature branch and then being
merged.

---

## What a paid plan would change

| Want | Plan | Price (Sept 2026) |
|---|---|---|
| Branch protection / rulesets on **private** repos - a direct push to `main` actually **refused by the server**, on every machine, with no hook installed | **GitHub Team** | **$4 USD per user/month** ([github.com/pricing](https://github.com/pricing)) |
| Secret scanning and **push protection** on private repos - a secret rejected *before* it lands, instead of found afterwards by CI | **GitHub Secret Protection** (add-on, available on Team) | **$19 USD per active committer/month** ([Pricing calculator](https://github.com/pricing/calculator), [Introducing GitHub Secret Protection](https://github.blog/changelog/2025-03-04-introducing-github-secret-protection-and-github-code-security/)) |

With 2 filled seats today, GitHub Team is roughly **$8/month** and converts
Layers 4 and 6's *detection* of direct pushes into Layer 3 *prevention* across
every private repo. It is the single highest-value line here, and **it is being
bought** - the runbook for the day it goes active is above.

Secret Protection at $19 per committer is a different order of money for a
narrower gain: gitleaks in CI already **finds** the same secrets, just after the
push rather than before. The gap it closes is the window between a secret landing
on GitHub's servers and CI reporting it - which matters a great deal for a public
repo (already covered free) and less for a private one. Not recommended at this
size. Revisit it if a real credential ever reaches a private repo.

Neither is an ObiLabs Principle-1 problem: both are operating expense out of
revenue, not dilution or debt.
