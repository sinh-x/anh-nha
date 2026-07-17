# AGENTS.md — anh-nha

This file guides AI agents and contributors working in the `anh-nha` repository (Flutter Android photo sync client for Immich).

## Branch Strategy

This repository follows a standard Git Flow branching model.

### Branch Model

- **`main`** — Production-ready code. Every commit on `main` is a release candidate. Direct pushes are blocked by GitHub branch protection (PR required, `enforce_admins: true`). All changes land via PR merge.
- **`develop`** — Integration branch. Feature branches are created from `develop` and merged back into `develop`. `develop` tracks `main` and is promoted to `main` for releases.
- **`feature/*`** — Short-lived branches for individual work items. Branch off `develop`, merge back to `develop` via PR.

### Branch Naming Convention

Feature branches MUST follow this pattern:

```
feature/ANH-NNN-topic-slug
```

- `ANH-NNN` — the ticket ID from the anh-nha ticket board (e.g., `ANH-002`).
- `topic-slug` — short kebab-case description of the work (e.g., `branch-strategy`, `login-fix`, `sync-engine`).
- If no ticket is associated, use `feature/<topic-slug>` only — but prefer having a ticket for every branch.

Examples:

- `feature/ANH-002-branch-strategy`
- `feature/ANH-003-sync-engine`
- `feature/ANH-010-tailscale-auth`

### PR / Merge Process

1. **Branch off `develop`** — create the feature branch with the naming convention above.
2. **Work locally** — commit using conventional commits: `type(scope): summary`. Valid types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`. Scope optional (e.g., `sync`, `auth`, `ui`).
3. **Push the feature branch** — `git push -u origin feature/ANH-NNN-topic-slug`.
4. **Open a PR** targeting `develop` (the integration branch). PR title uses the same conventional commit format.
5. **Merge via squash** on `develop` once approved. For releases, open a PR from `develop` to `main`.
6. **Delete the feature branch** after merge to keep the branch list clean.

### Direct Push Policy

- **Never** push directly to `main`. Branch protection enforces this with `enforce_admins: true` (applies to all users including the repo owner) and `allow_force_pushes: false`.
- `develop` accepts direct pushes (solo developer setup), but prefer PRs for non-trivial changes to preserve review history.
- Feature branches accept direct pushes freely.