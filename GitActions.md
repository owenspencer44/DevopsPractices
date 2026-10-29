#GitHub Actions CI Pipeline

This repo uses a single `main` branch, with a **CI (Continuous Integration) pipeline** run at two checkpoints:

1. **Before the push (local gate):** a `pre-push` git hook runs the pipeline on your Mac. If any check fails, the push is cancelled and nothing reaches GitHub.
2. **After the push (CI):** GitHub Actions runs the same pipeline on a clean Ubuntu machine and marks the commit ✔ or ✘.

- **Trigger:** `git push` to `main`
- **Checks:** syntax validation (JavaScript + C#) → unit tests (xUnit)
- **Single source of truth:** both checkpoints run the same `pipeline.yml` through the same `run-pipeline.sh`

---

## 1. High-level architecture

```
 ┌────────────────────────────────────────────────────────────┐
 │  DEVELOPER MACHINE (macOS, Apple Silicon)                  │
 │                                                            │
 │  git commit                                                │
 │  git push origin main                                      │
 │        │                                                   │
 │        ▼                                                   │
 │  .git/hooks/pre-push   (CHECKPOINT 1: local gate)          │
 │        │  runs ./run-pipeline.sh                           │
 │        │      └─► docker exec → local "mylinux" container  │
 │        │                                                   │
 │        ├── any step fails ──► exit 1 ──► ✘ PUSH CANCELLED  │
 │        │                                 (nothing sent)    │
 │        ▼ all steps pass                                    │
 │  push proceeds ────────────────────────────────────────────┼──┐
 └────────────────────────────────────────────────────────────┘  │
                                                                 ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │  GITHUB (remote: origin)                                            │
 │                                                                     │
 │  refs/heads/main updated ──► "push" event ──► matches workflow      │
 │                                               trigger in ci.yml     │
 │                                                     │               │
 │                                                     ▼               │
 │  ┌───────────────────────────────────────────────────────────────┐  │
 │  │  GITHUB-HOSTED RUNNER  (ubuntu-latest VM)                     │  │
 │  │  CHECKPOINT 2: CI                                             │  │
 │  │                                                               │  │
 │  │  JOB: checks                                                  │  │
 │  │   ├─ actions/checkout@v4      → clone repo at pushed SHA      │  │
 │  │   ├─ docker run ... mylinux   → Ubuntu 24.04 container,       │  │
 │  │   │                              repo bind-mounted at /work   │  │
 │  │   └─ ./run-pipeline.sh        → parse pipeline.yml and        │  │
 │  │                                  docker exec each step        │  │
 │  │                                                               │  │
 │  │   result ──► ✔ green tick / ✘ red cross on the commit         │  │
 │  └───────────────────────────────────────────────────────────────┘  │
 └─────────────────────────────────────────────────────────────────────┘
```

---

## 2. How `pipeline.yml` is executed

`run-pipeline.sh` is a minimal **pipeline runner**. It runs on the host (your Mac or the runner VM)
and dispatches each step into the `mylinux` container using `docker exec`.

```
   HOST (your Mac / runner VM)                    CONTAINER: mylinux (ubuntu:24.04)
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
 ┌───────────┐   ┌───────────────┐   ┌──────────────┐   ┌──────────────┐
 │  Setup    │──►│ Syntax check  │──►│ Syntax check │──►│ Logic check  │──► ✔ PASS
 │ apt-get   │   │  JavaScript   │   │     C#       │   │  Unit tests  │
 │ node/.NET │   │ node --check  │   │ dotnet build │   │ dotnet test  │
 └───────────┘   └───────────────┘   └──────────────┘   └──────────────┘
      ✘                 ✘                   ✘                  ✘
      └─────────────────┴───────────────────┴──────────────────┴──► STOP (exit 1)
```

| Stage | Command | Fails when |
|---|---|---|
| Setup | `apt-get install nodejs dotnet-sdk-8.0` | Package install fails |
| JS syntax | `node --check <file>` | A `.js` file can't be parsed |
| C# syntax | `dotnet build` on a temp project containing all non-test `.cs` files | Compiler errors |
| Unit tests | `dotnet test` on every `*.Tests.csproj` | Any `[Fact]` / `[Theory]` assertion fails |

Stages with no matching files (for example, no `.js` files or no test projects yet) print `skipping` and pass.

---

## 3. What happens on a push

```
 git push origin main
        │
        ▼
 ┌─────────────────────┐   fail   ┌──────────────────────────────────────┐
 │ pre-push hook       │────────► │ ✘ Push cancelled. GitHub untouched.  │
 │ (local pipeline)    │          │   Fix the code, commit, push again.  │
 └─────────────────────┘          └──────────────────────────────────────┘
        │ pass
        ▼
 ┌─────────────────────┐
 │ commit lands on     │
 │ origin/main         │
 └─────────────────────┘
        │
        ▼
 ┌─────────────────────┐   fail   ┌──────────────────────────────────────┐
 │ GitHub Actions CI   │────────► │ ✘ Red cross on the commit. Code is   │
 │ (clean runner)      │          │   already on main: push a fix.       │
 └─────────────────────┘          └──────────────────────────────────────┘
        │ pass
        ▼
   ✔ Green tick on the commit
```

The local hook is the **gate**: it stops bad code reaching GitHub.
The CI run is the **verification**: it proves the code passes on a clean machine, not just on your Mac.

---

## 4. Components

| File | Role |
|---|---|
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml) | **Workflow definition.** Trigger (`on: push: branches: [main]`), job, runner |
| [`pipeline.yml`](pipeline.yml) | **Pipeline definition.** Ordered list of steps (`name` + `run`) and target `container` |
| [`run-pipeline.sh`](run-pipeline.sh) | **Pipeline runner.** Parses `pipeline.yml` and runs each step via `docker exec` |
| `*.Tests/` *(none yet)* | xUnit test projects: the **logic check**. Any folder with a `*.Tests.csproj` is picked up automatically |
| [`.gitignore`](.gitignore) | Excludes build output (`bin/`, `obj/`) |
| `.git/hooks/pre-push` | **Local gate.** Reads the refs being pushed from stdin; for `refs/heads/main` it runs `run-pipeline.sh` and exits 1 on failure |

---

## 5. Running it locally vs on GitHub

```
        LOCAL                                        GITHUB ACTIONS
 ┌──────────────────────────────────┐       ┌───────────────────────────────────────┐
 │ $ syntax         (manual)        │       │ $ git push origin main                │
 │ $ git push       (pre-push hook) │       │    │  (push event)                    │
 │    │                             │       │    ▼                                  │
 │    ▼                             │       │ ci.yml → ubuntu-latest runner         │
 │ ./run-pipeline.sh                │       │    │                                  │
 │    │                             │       │    ▼                                  │
 │    ▼                             │       │ mylinux container (created fresh      │
 │ mylinux container (Docker        │       │ each run, x86_64)                     │
 │ Desktop on Apple Silicon, arm64) │       │    │                                  │
 │                                  │       │    ▼                                  │
 │ Result printed in terminal       │       │ ✔ / ✘ status on the commit            │
 └──────────────────────────────────┘       └───────────────────────────────────────┘
```

| | Local | GitHub Actions |
|---|---|---|
| Triggered by | Typing `syntax`, or `git push` (hook) | Push to `main` |
| Runs on | Your Mac (Docker Desktop) | GitHub-hosted Ubuntu VM |
| Container | Long-lived `mylinux` (tools stay installed) | New `mylinux` every run |
| On failure | Push cancelled | Red ✘ on the commit |

---

## 6. Day-to-day usage

```bash
syntax                      # optional: run the checks without pushing
git add .
git commit -m "describe the change"
git push origin main        # hook runs the pipeline first, then pushes
gh run watch                # follow the CI run live in the terminal
```

You can also follow runs in the **Actions** tab of the GitHub repository.

The local `mylinux` container must be running for the hook to pass (`docker start mylinux`).

---

## 7. Known limitations

- **The `pre-push` hook is local only.** Git hooks live in `.git/hooks/`, which isn't committed, so pushes from another machine or edits in the GitHub web UI skip the local gate. CI still runs on them, but only after the code is on `main`.
- **The hook checks your working folder, not the exact commit being pushed.** Uncommitted changes are included in the check.
- **The hook can be bypassed** with `git push --no-verify`.
- **The YAML parser is minimal.** `run-pipeline.sh` supports single-line `run:` commands only. Multi-line blocks (`run: |`) aren't supported.
- **The C# syntax check compiles all non-test `.cs` files as one program.** More than one `Main` method will fail with a "multiple entry points" error.
