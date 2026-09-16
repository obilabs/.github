# Repository hygiene tooling

Shared tooling that keeps the same avoidable mistakes out of ObiLabs repositories.
It costs nothing to run: plain POSIX shell hooks, a reusable GitHub Actions workflow,
and GitHub's own secret scanning.

## Policy

| Rule | Why |
|---|---|
| Commit with a GitHub **noreply** identity (`<id>+<user>@users.noreply.github.com`), never a personal webmail address. | Keeps personal addresses out of permanent, public commit metadata while still attributing the work. |
| **No AI co-author trailers** (`Co-authored-by: Claude ...`, "Generated with Claude Code"). | AI is a tool, not a co-author. AI-assisted development is disclosed **once** in each README (see `repo-template/README-footer.md`). |
| **No absolute user-home paths** (`C:\Users\<name>\`, `/Users/<name>/`, `/home/<name>/`). | They break portability and leak the developer's username. Use repo-relative paths or environment variables. | <!-- hygiene:allow -->
| **No secrets** in files or history; no `.env` / key / credential files. | Rotating a leaked credential is expensive; a history rewrite is worse. Commit `.env.example` instead. |
| **`main` changes only through a pull request.** | Every change on `main` is reviewed. Private repos on the Free plan cannot enforce this server-side, so the hook does it locally. |

## Layers

Each layer catches what the previous one missed.

| Layer | Where | Catches |
|---|---|---|
| 1. Local git hooks | `tooling/git-hooks/`, installed once per machine | Webmail identity, secrets and user-home paths in added lines, personal denylist strings, credential-shaped filenames (pre-commit); strips AI trailers (commit-msg); direct pushes to `main`/`master`, webmail identities and AI trailers in pushed commits (pre-push). |
| 2. CI reusable workflow | `.github/workflows/hygiene.yml`, called from every repo | gitleaks secret scan, commit identity + AI trailer check, and user-home path check over the commits in each PR / push. Runs even when someone never installed the hooks or used an escape hatch. |
| 3. GitHub push protection | Public repositories (secret scanning enabled) | Known provider token formats, rejected by GitHub before they land. Private repos are plan-gated, so layer 2 is their only scanner. |
| 4. Org drift detector | `tooling/org-drift.sh`, scheduled weekly | **After the fact**: commits that reached `main` without a PR, protection or secret scanning that got turned off, repos that never adopted layer 2. |

See **[docs/GOVERNANCE.md](../docs/GOVERNANCE.md)** for what is actually
*enforced* versus what is only *detected*, and what a paid plan would change.

## Create a new repository

```sh
sh tooling/new-repo.sh <repo-name> <public|private> [--dry-run] [--no-clone]
```

Creates `obilabs/<repo-name>` from `obilabs/repo-template` and applies every
governance setting the plan allows, in order:

1. validates the name and visibility, and that `gh` is authenticated with the
   `repo`, `read:org` and `workflow` scopes;
2. `gh repo create --template obilabs/repo-template`, then waits for `main`;
3. branch protection on `main` requiring a pull request, **plus an explicit
   `enforce_admins` call**, then reads the protection back to verify it;
4. secret scanning, push protection, Dependabot alerts and security updates;
   squash-only merges and delete-branch-on-merge;
5. clones the repo and sets `user.name` / `user.email` to the ObiLabs noreply
   identity, then checks `core.hooksPath` points at the org hooks;
6. prints what was applied, what was skipped, and a checklist of what the owner
   must still click.

It is **idempotent**: run it again on an existing repo and it re-applies the
settings instead of failing (it never changes an existing repo's visibility).

On a **private** repo GitHub answers *"Upgrade to GitHub Pro"* for protection and
secret scanning. The script detects that, prints a plain warning that the local
pre-push hook is then the only guard, and **continues** - refusing to create the
repo would not change the plan.

`--dry-run` prints every command it would run and changes nothing; it still does
the read-only checks (auth, scopes, whether the repo already exists) so the dry
run takes the same branch a real run would.

## Install the local hooks

**New machine, rebuilt VM, or a fresh agent worktree - one command:**

```sh
curl -fsSL https://raw.githubusercontent.com/obilabs/.github/main/tooling/bootstrap.sh | sh
```

(`obilabs/.github` is public, so no token is needed. `bootstrap.sh` clones this
repo to a temp dir, runs `install.sh`, verifies the result and fails loudly if a
hook is missing.)

From an existing clone - macOS / Linux / Git Bash:

```sh
sh tooling/git-hooks/install.sh
```

Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File tooling\git-hooks\install.ps1
```

The installer copies the hooks to `~/.config/obilabs/git-hooks/`, sets the global
`core.hooksPath` to `~/.config/obilabs/git-hooks`, and creates an empty personal
denylist at `~/.config/obilabs/hygiene-denylist`. Re-run it after pulling hook
updates.

- **Existing repo hooks keep working.** Each hook runs the repository's own
  `.git/hooks/<name>` afterwards, with the same arguments and stdin.
- **Repos that set a local `core.hooksPath`** (for example husky) override the
  global setting, so the hygiene hooks do not run there. Pass repo directories to
  the installer to check them (`sh tooling/git-hooks/install.sh ../repo-a ../repo-b`);
  it prints the lines to add to that repo's hooks to chain the checks in.
- **Personal denylist.** Add one string per line (for example your personal email
  address or machine username). Matching is case-insensitive against added lines.
  The file stays on your machine and is never committed.

Uninstall:

```sh
git config --global --unset core.hooksPath
rm -rf ~/.config/obilabs/git-hooks
```

Run the hook test suite (creates throwaway repos under a temp directory; your
real git config is untouched):

```sh
sh tooling/git-hooks/test/run.sh
```

## Add the CI check to a repository

Use the **ObiLabs Hygiene** workflow template (Actions, New workflow), or add
`.github/workflows/hygiene.yml`:

```yaml
name: Hygiene

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  hygiene:
    uses: obilabs/.github/.github/workflows/hygiene.yml@main
```

A `.gitleaks.toml` at the repository root is honoured automatically (use it to
allowlist test fixtures).

### Scheduled full-history secret scan

The default `scan: range` mode looks only at the commits a PR or push
introduces. Add a weekly `scan: full` pass so a secret that predates the
workflow - or one that arrived through a direct push to an unprotected `main` -
is still found:

```yaml
on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: '17 6 * * 1'

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

In `full` mode only the secret scan runs, over every commit reachable from every
ref.

## Detect drift across the organisation

```sh
sh tooling/org-drift.sh --days 7
```

Reports, for every non-archived repo in the org: commits that reached the default
branch **without a pull request**, whether protection is on and binds admins,
whether secret scanning is on, and whether the repo calls the hygiene workflow at
all. Exits `1` on drift.

`.github/workflows/org-drift.yml` runs it weekly and keeps one rolling issue in
this repository up to date. It needs an `ORG_GOVERNANCE_TOKEN` secret (a
fine-grained PAT that can read every repo in the org); without it the workflow
fails rather than reporting a false all-clear.

**This is detection, not prevention.** A direct push to a private repo's `main`
on the Free plan succeeds; this reports it afterwards. The limits are spelled out
in [docs/GOVERNANCE.md](../docs/GOVERNANCE.md).

## Escape hatches

Use them deliberately; CI still checks everything the local hooks skip.

| Situation | Escape |
|---|---|
| A single line is a false positive or a deliberately fake credential (test fixture) | Put the marker `hygiene:allow` in a comment on that line. Honoured by the pre-commit hook and the CI path check. For gitleaks, use `gitleaks:allow` or a `.gitleaks.toml` allowlist. |
| Skip all pre-commit / pre-push content checks for one command | `OBILABS_HYGIENE_SKIP=1 git commit ...` (prints a loud warning) |
| A genuine direct push to `main` (for example the first push of a brand-new repo) | `OBILABS_ALLOW_MAIN_PUSH=1 git push ...` |

## Repository template

New repositories are created with `tooling/new-repo.sh` (above) from
`obilabs/repo-template`. `tooling/repo-template/` holds the baseline files:
`.gitignore`, `SECURITY.md` (private vulnerability reporting), and
`README-footer.md` with the one-line AI-assisted development disclosure.
