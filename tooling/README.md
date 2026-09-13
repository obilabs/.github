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
| 3. GitHub push protection | Public repositories (secret scanning enabled) | Known provider token formats, rejected by GitHub before they land. |

## Install the local hooks

macOS / Linux / Git Bash:

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

## Escape hatches

Use them deliberately; CI still checks everything the local hooks skip.

| Situation | Escape |
|---|---|
| A single line is a false positive or a deliberately fake credential (test fixture) | Put the marker `hygiene:allow` in a comment on that line. Honoured by the pre-commit hook and the CI path check. For gitleaks, use `gitleaks:allow` or a `.gitleaks.toml` allowlist. |
| Skip all pre-commit / pre-push content checks for one command | `OBILABS_HYGIENE_SKIP=1 git commit ...` (prints a loud warning) |
| A genuine direct push to `main` (for example the first push of a brand-new repo) | `OBILABS_ALLOW_MAIN_PUSH=1 git push ...` |

## Repository template

`tooling/repo-template/` holds the baseline files for new repositories:
`.gitignore`, `SECURITY.md` (private vulnerability reporting), and
`README-footer.md` with the one-line AI-assisted development disclosure.
