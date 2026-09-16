# Niro project setup

This directory is one environment profile: its authorized targets, preparation
mechanism, test identities, and runtime settings. Keep staging, local, and
production profiles in separate directories.

## Test an existing staging application

Set up the environment once:

1. Edit `scope.yaml` and authorize only the staging hosts and ports Niro may
   test. A person must authorize every remote target.
2. Add `harness/seed.sh` (macOS/Linux) or `harness/seed.ps1` (Windows). It should
   create or reset dedicated test users, tenants, and resources using the
   application's existing API, job, or seed tooling. Add the matching `reset`
   script only when runs need a separate clean-baseline operation.
3. Have that mechanism generate `niro/credentials.yaml` and
   `niro/fixtures.yaml`. Both files are gitignored; commit the
   preparation code, not its environment-specific output.
4. Run Niro with this environment profile:

```bash
niro find --config-dir=niro --url=https://staging.example.com --goal "Test authentication and tenant isolation"
niro fix --config-dir=niro --url=https://staging.example.com --goal "Test authentication and tenant isolation"
```

`--url` tells Niro this is an existing runtime. Niro invokes the approved
preparation during a run and again when it needs a
clean baseline. You should not recreate accounts, credentials, or fixtures by
hand before each assessment. For an existing remote runtime, the committed
preparation is the approval boundary: Niro runs it but does not rewrite it during
the assessment. If it cannot prepare required state, Niro reports the blocker.

Use a staging, pre-production, or dedicated test environment when testing can
change data or trigger integrations. Open `harness/README.md` for the existing
runtime preparation contract.

## Let Niro start the application

For a checkout-local or CI runtime, Niro authors and operates the complete
`start`, `stop`, `seed`, and `reset` lifecycle under `harness/`. It builds from
the current checkout and uses the project's existing Dockerfile, Compose file,
development command, factories, migrations, and seed helpers.

Omit `--url` when you want Niro to own this lifecycle.

Review and commit the harness so future runs reproduce the same baseline. A
person may authorize the local host and port produced by that harness.

Docker or Podman is always required for Niro's isolated attack-tool sandbox.
That container runtime is separate from where the application itself runs.

## Know the files

| File | Purpose | Commit it? |
| --- | --- | --- |
| `niro.yaml` | Optional limits, models, Git-provider publishing, telemetry, and sandbox settings | Yes |
| `scope.yaml` | Network destinations Niro is authorized to reach | Yes |
| `harness/` | Approved preparation for staging, or the complete lifecycle for a Niro-started app | Yes |
| `credentials.yaml` | Generated target test credentials | No |
| `fixtures.yaml` | Generated references to prepared test state | No |
| `accepted-behaviors.yaml` | Specific reviewed product behavior Niro should treat as intentional | Yes |
| `accepted-coverage-gaps.yaml` | Specific environment limitations Niro should not repeatedly report | Yes |
| `findings/` | Mutable local finding evidence used during verification and remediation | No |
| `harness/run/` | Mutable runtime state and output owned by the harness | No |
| `artifacts/` | Latest terminal run manifest, summary, report, and generated bundles | No |

The `.example` files are format references. Copy an accepted-behavior or
coverage-gap example only when that specific advanced context applies. Do not
create empty registers for a first run.

Claude Code is the default agent CLI. Pass `--agent=codex` or
`--agent=copilot` to use another supported agent CLI. Niro detects GitHub,
GitLab, Azure DevOps, and other supported Git providers from the repository
remote. It creates reviewable changes but never merges them.

## jupiterOS profile

This directory is the **local, loopback-only** profile for the jupiterOS
repository. The run is find-only (no fix PRs) and the goal is two-fold:

1. **Review the jupiterOS fleet configuration** — every host under `hosts/`,
   every module under `modules/`, secrets handling, and network exposure — for
   exploitable security weaknesses. This is static review by the agent; the
   `fleet_config_surface` fixture points at the relevant paths.
2. **Dynamically test the one runtime this profile may reach** — the
   arcade-webapp started locally by `harness/start.sh` on port 18094. `scope.yaml`
   authorises only `127.0.0.1:18094` and `localhost:18094`; no fleet host,
   LAN address, tailnet name, or CIDR is ever in scope. Widening this list is a
   separate, deliberate decision that needs its own environment profile.

Run it locally from the repository root (requires Docker or Podman and an
authenticated agent CLI):

```bash
niro find --autonomous --agent=copilot --config-dir=niro \
  --goal "Review the jupiterOS fleet configuration and test the arcade-webapp runtime"
```

In CI, dispatch the **Niro Find** workflow manually. It pins Niro v0.1.80 and
one agent CLI version per provider, sets up the `niro-autonomous` GitHub
environment (required reviewers optional but recommended), and uploads the
report PDF and knowledge bundle as artifacts. Provider secrets/variables are
configured once — `scripts/niro-setup-deepseek.sh` walks the DeepSeek
Copilot-BYOK path stage by stage (API key → variables → optional reviewers →
bootstrap dispatch), and `scripts/niro-setup.sh` covers the other
providers/non-interactive use. The workflow's guard steps fail fast, before
any run, when the selected agent's provider configuration is incomplete.

`headless: true` and `telemetry: false` are set in `niro.yaml` for a reason:
the first prevents an autonomous run halting on an interactive
acknowledgement gate until the job timeout, the second records an explicit
decision that no run telemetry leaves this estate.
