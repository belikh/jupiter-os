# Application preparation

This directory makes application state repeatable. The required operations
depend on where the application runs.

During `niro find` and `niro fix`, Niro invokes the applicable approved
operations before testing and whenever it needs a clean baseline. Review and
commit them so a local or CI run prepares the same state every time.

Use these conventional entry points on the platform that runs Niro:

| Operation | macOS/Linux | Windows |
| --- | --- | --- |
| `start` | `start.sh` | `start.ps1` |
| `stop` | `stop.sh` | `stop.ps1` |
| `seed` | `seed.sh` | `seed.ps1` |
| `reset` | `reset.sh` | `reset.ps1` |

You need only the scripts required by the selected runtime and platform. A thin
script may invoke an existing Make target, package script, API client, or staging
job rather than duplicate the application's setup logic.

## Existing application runtime

Supplying `--url` to `niro find` or `niro fix` selects this contract. Niro does
not start or stop the application at that URL. Provide only the preparation
operations the environment needs:

| Operation | Contract |
| --- | --- |
| `seed` | Create or reconcile dedicated test users, tenants, roles, and resources; generate `../credentials.yaml` and `../fixtures.yaml` |
| `reset` | Optional. Restore the dedicated test state to a clean baseline when a run can leave it changed |

Use an approved application API, staging job, or existing seed tool. Keep the
operation idempotent and scoped to dedicated test data. It must not provision a
different target, widen `../scope.yaml`, or mutate unrelated staging data.

The committed staging scripts are customer-approved operations. Niro may invoke
them, but it does not rewrite, extend, or replace them during an assessment. If
they cannot produce required state or access, Niro reports the blocker for a
person to resolve.

Retrieve secrets through the customer's existing secret-management path. Write
raw credentials only to `../credentials.yaml`; write non-secret identifiers and
references to `../fixtures.yaml`. Niro adds both generated files to `.gitignore`.

If signup and normal application flows can create all required state, the seed
operation may drive those flows rather than use database or infrastructure
access. Niro does not assume permission to administer the staging environment.

## Niro-managed application runtime

Omitting `--url` selects this contract. Niro starts the application from the
current checkout and provides the full lifecycle:

| Operation | Contract |
| --- | --- |
| `start` | Build the current checkout, start the full service graph, and verify every tested surface is healthy |
| `stop` | Shut down the application and supporting services cleanly |
| `seed` | Create a deterministic baseline and generate `../credentials.yaml` and `../fixtures.yaml` |
| `reset` | Restore that clean baseline between runs |

Use the application's own development path. Prefer its existing Dockerfile or
Compose file, language, factories, migrations, and seed helpers. Keep lifecycle
commands as thin orchestration around those tools and verify them on the
operating system they support.

## State and source

Commit preparation scripts and configuration under `niro/harness/`.
Keep mutable databases, logs, snapshots, and build output owned by the harness
under `niro/harness/run/`; Niro adds that directory to `.gitignore`.

Treat application source outside `niro/` as read-only for harness
state. The harness may build the project normally, but it should not scatter its
own databases, logs, or generated runtime files throughout the source tree.

For a Niro-started application, build from the current checkout rather than a
published image. This ensures the target contains the code Niro is reviewing.

## jupiterOS: the arcade-webapp harness

This profile starts exactly one service: the Go application in
`pkgs/arcade-webapp` (the jupiterOS Arcade pipeline dashboard), built from the
current checkout. No fleet host is ever contacted — `niro/scope.yaml`
authorises only `127.0.0.1:18094` and `localhost:18094`. The run's goal also
directs the agent at the wider jupiterOS fleet configuration (`hosts/`,
`modules/`, `flake.nix`) for static review, but the only reachable runtime is
this local one.

| Entry point | Behaviour |
| --- | --- |
| `start.sh` | Builds `./cmd/arcade-webapp` into `run/bin/`, starts it on `0.0.0.0:18094` in its own session (and writes `run/app.pid` + `run/app.log`), then waits for `/healthz`. Refuses to start if the port is already bound; idempotent while healthy. |
| `stop.sh` | SIGTERMs the whole process group, escalates to SIGKILL, removes the PID file, sweeps an orphan of the built binary, and verifies the port is released. |
| `seed.sh` | Regenerates the deterministic ROM corpus (`cmd/fixturegen`, matching the committed DATs in `pkgs/arcade-webapp/testdata/dats`), stages the DATs, `POST /rescan`s, waits for `/inventory.json` to report nes=5 / snes=4 / gb=4, then creates (or reuses) the *Niro Fixture Collection* through `POST /collections/create` and `POST /collections/<id>/add`. Writes `niro/credentials.yaml` and `niro/fixtures.yaml` (both gitignored). |
| `reset.sh` | `stop.sh`, wipes `run/` and the generated credentials/fixtures, then `start.sh` + `seed.sh`. |

### Why the app binds 0.0.0.0

Niro's attack tooling runs in a container. On native Linux Docker a listener
bound to `127.0.0.1` only is unreachable from that container, so the harness
binds `0.0.0.0:18094`. The committed scope file still authorises the
destination only under its loopback names; do not add a LAN, tailnet, or CIDR
target to make the app reachable — fix reachability on the harness side
instead.

### Determinism and offline behaviour

`start.sh` deliberately does not wire aria2, igir, or Skyscraper, and sets the
scheduled DAT refresh and scrape intervals to `0`. The run therefore makes no
third-party network calls and the seeded state is byte-identical every time.
The seeded credential is not an identity: the app is unauthenticated
(no login, sessions, or cookies); its only gate is the `HX-Request` header
required on mutating endpoints, modelled as a `static_token` so the attacker
agent knows where the value goes.

### Toolchain

The scripts use `go` when it is on `PATH` (CI supplies it via
`actions/setup-go`, version pinned by `pkgs/arcade-webapp/go.mod`) and fall
back to `nix develop -c go` (the flake devShell, version pinned by
`flake.lock`) on a bare NixOS checkout.
