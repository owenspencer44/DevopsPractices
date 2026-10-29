# GitHub Actions CI Pipeline

This repo uses a **CI (Continuous Integration) pipeline** to gate the `main` branch.
Code is pushed to `dev`, validated automatically, and only **fast-forwarded into `main`** if every check passes.

- **Trigger:** `git push` to the `dev` branch
- **Checks:** syntax validation (JavaScript + C#) → unit tests (xUnit)
- **Deploy step:** automatic fast-forward merge of `dev` into `main`
- **Guard:** a local `pre-push` git hook blocks direct pushes to `main`

---

## 1. High-level architecture

```
 ┌──────────────────────────────┐
 │  DEVELOPER MACHINE (macOS)   │
 │                              │
 │  git commit                  │
 │  git push origin dev ────────┼──┐
 │                              │  │
 │  .git/hooks/pre-push         │  │   push to main?  ──►  ✘ BLOCKED (exit 1)
 │  (guard: rejects main)       │  │   push to dev?   ──►  ✔ allowed
 └──────────────────────────────┘  │
                                   ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │  GITHUB (remote: origin)                                            │
 │                                                                     │
 │  refs/heads/dev updated ──► "push" event ──► matches workflow       │
 │                                              trigger in ci.yml      │
 │                                                     │               │
 │                                                     ▼               │
 │  ┌───────────────────────────────────────────────────────────────┐  │
 │  │  GITHUB-HOSTED RUNNER  (ubuntu-latest VM)                     │  │
 │  │                                                               │  │
 │  │  JOB 1: checks                                                │  │
 │  │   ├─ actions/checkout@v4      → clone repo at pushed SHA      │  │
 │  │   ├─ docker run ... mylinux   → Ubuntu 24.04 container,       │  │
 │  │   │                              repo bind-mounted at /work   │  │
 │  │   └─ ./run-pipeline.sh        → parse pipeline.yml and        │  │
 │  │                                  docker exec each step        │  │
 │  │            │                                                  │  │
 │  │            ├── any step exits non-zero ──► job FAILS ✘        │  │
 │  │            │                                (main untouched)  │  │
 │  │            ▼ all steps exit 0                                 │  │
 │  │  JOB 2: merge-to-main   (needs: checks)                       │  │
 │  │   ├─ actions/checkout@v4 (ref: main, full history)            │  │
 │  │   ├─ git merge --ff-only <tested SHA>                         │  │
 │  │   └─ git push origin main   (auth: GITHUB_TOKEN,              │  │
 │  │                               permissions: contents: write)   │  │
 │  └───────────────────────────────────────────────────────────────┘  │
 │                                                     │               │
 │                                                     ▼               │
 │                                    refs/heads/main = tested commit ✔│
 └─────────────────────────────────────────────────────────────────────┘
```

---

## 2. Inside Job 1: how `pipeline.yml` is executed

`run-pipeline.sh` is a minimal **pipeline runner**. It runs on the host (the runner VM, or your Mac locally)
and dispatches each step into the `mylinux` container using `docker exec`.

```
   HOST (runner VM / your Mac)                    CONTAINER: mylinux (ubuntu:24.04)
   ───────────────────────────                    ─────────────────────────────────
   run-pipeline.sh                                /work  ◄── bind mount of repo
        │
        │ reads pipeline.yml line by line
        │ (regex match: container / - name / run)
        │
        ├─ step 1 ──── docker exec mylinux bash -c "..." ──►  echo hello world
        ├─ step 2 ──── docker exec ... ──────────────────────►  apt-get install nodejs dotnet-sdk-8.0
        ├─ step 3 ──── docker exec ... ──────────────────────►  node --check *.js
        ├─ step 4 ──── docker exec ... ──────────────────────►  dotnet build (temp .csproj)
        ├─ step 5 ──── docker exec ... ──────────────────────►  dotnet test *.Tests.csproj
        └─ step 6 ──── docker exec ... ──────────────────────►  echo passed
        │
        │  each step: exit code 0 → continue
        │             exit code ≠ 0 → print "✘ Step failed", exit 1 (fail-fast)
        ▼
   "✔ Pipeline passed"  (exit 0)
```

### Pipeline stages

```
 ┌───────────┐   ┌───────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
 │  Setup    │──►│ Syntax check  │──►│ Syntax check │──►│ Logic check  │──►│   Merge to   │
 │ apt-get   │   │  JavaScript   │   │     C#       │   │  Unit tests  │   │     main     │
 │ node/.NET │   │ node --check  │   │ dotnet build │   │ dotnet test  │   │ ff-only push │
 └───────────┘   └───────────────┘   └──────────────┘   └──────────────┘   └──────────────┘
      ✘                 ✘                   ✘                  ✘
      └─────────────────┴───────────────────┴──────────────────┴──► STOP — main is not updated
```

| Stage | Command | Fails when |
|---|---|---|
| Setup | `apt-get install nodejs dotnet-sdk-8.0` | Package install fails |
| JS syntax | `node --check <file>` | A `.js` file can't be parsed |
| C# syntax | `dotnet build` on a temp project containing all non-test `.cs` files | Compiler errors |
| Unit tests | `dotnet test` on every `*.Tests.csproj` | Any `[Fact]` / `[Theory]` assertion fails |
| Merge | `git merge --ff-only` + `git push origin main` | `main` has diverged from `dev` (not a fast-forward) |

Stages with no matching files (for example, no `.js` files) print `skipping` and pass.

---

## 3. Branch flow

```
 main   ●───────────────────────────────●  ◄── fast-forwarded by CI only
         \                             ↗
 dev      ●──────●──────●─────────────●       (you push here)
                 │      │             │
               push   push          push
                 │      │             │
                CI ✘   CI ✘          CI ✔ ──► main moves to this commit
           (main stays put)
```

- `main` only ever points to a commit that **passed CI**.
- `--ff-only` means CI never creates merge commits. `main` is simply moved forward to the tested SHA.

---

## 4. Components

| File | Role |
|---|---|
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | **Workflow definition.** Trigger (`on: push: branches: [dev]`), jobs, permissions |
| [`pipeline.yml`](pipeline.yml) | **Pipeline definition.** Ordered list of steps (`name` + `run`) and target `container` |
| [`run-pipeline.sh`](run-pipeline.sh) | **Pipeline runner.** Parses `pipeline.yml` and runs each step via `docker exec` |
| [`Calculator/`](Calculator/) | Sample application code (class library) |
| [`Calculator.Tests/`](Calculator.Tests/) | xUnit test project: the **logic check** |
| [`.gitignore`](.gitignore) | Excludes build output (`bin/`, `obj/`) |
| `.git/hooks/pre-push` | **Local guard.** Reads the refs being pushed from stdin and exits 1 if the target is `refs/heads/main` |

---

## 5. Running it locally vs on GitHub

The same `pipeline.yml` and `run-pipeline.sh` run in both places, so a local pass should mean a CI pass.

```
        LOCAL (manual trigger)                       GITHUB ACTIONS (event trigger)
 ┌──────────────────────────────────┐       ┌───────────────────────────────────────┐
 │ $ syntax                         │       │ $ git push origin dev                 │
 │    │  (alias in ~/.zshrc)        │       │    │  (push event)                    │
 │    ▼                             │       │    ▼                                  │
 │ ./run-pipeline.sh                │       │ ci.yml → ubuntu-latest runner         │
 │    │                             │       │    │                                  │
 │    ▼                             │       │    ▼                                  │
 │ mylinux container (Docker        │       │ mylinux container (created fresh      │
 │ Desktop on Apple Silicon, arm64) │       │ each run, x86_64)                     │
 │                                  │       │    │                                  │
 │ Result printed in terminal       │       │    ▼                                  │
 │ (no merge)                       │       │ pass → merge into main                │
 └──────────────────────────────────┘       └───────────────────────────────────────┘
```

| | Local | GitHub Actions |
|---|---|---|
| Triggered by | Typing `syntax` | `git push origin dev` |
| Runs on | Your Mac (Docker Desktop) | GitHub-hosted Ubuntu VM |
| Container | Long-lived `mylinux` (tools stay installed) | New `mylinux` every run |
| On success | Prints `✔ Pipeline passed` | Fast-forwards `main` |

---

## 6. Day-to-day usage

```bash
git checkout dev            # always work on dev
syntax                      # optional: run the checks locally first
git add .
git commit -m "describe the change"
git push origin dev         # triggers CI
gh run watch                # follow the run live in the terminal
```

You can also follow runs in the **Actions** tab of the GitHub repository.

**If CI fails:** fix the code on `dev`, then commit and push again. `main` is never touched by a failed run.

**After CI merges:** run `git pull origin main` on your machine so your local `main` matches GitHub.

---

## 7. Known limitations

- **The `pre-push` guard is local only.** Git hooks live in `.git/hooks/`, which isn't committed, so they don't protect `main` from other machines or from the GitHub web UI. Server-side enforcement would mean switching to pull requests with GitHub branch protection (required status checks), because a plain push restriction would also block the workflow's own merge.
- **The YAML parser is minimal.** `run-pipeline.sh` supports single-line `run:` commands only. Multi-line blocks (`run: |`) aren't supported.
- **The C# syntax check compiles all non-test `.cs` files as one program.** More than one `Main` method will fail with a "multiple entry points" error.
- **Merging is fast-forward only.** If `main` gets commits that aren't on `dev`, the merge job fails until `dev` is updated (`git pull origin main` on `dev`).
