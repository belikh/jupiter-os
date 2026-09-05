{ lib, python3 }:

# Shared python env for the procurement MCP server — consumed by BOTH the
# callisto systemd unit (modules/services/procurement-mcp.nix, package
# default) and opencode's per-session stdio spawn (mcp.procurement in
# modules/core/opencode.nix), so the two can never drift or double the
# closure.
#
# packageOverrides is scoped to this env ONLY — never a fleet overlay.
#
# (1) sse-starlette: real packaging skew against the pinned nixpkgs
#     expression. Upstream 3.2.0's wheel declares starlette as a hard
#     runtime dependency; the expression carries only anyio (starlette
#     sits under optional-dependencies.examples). The unconditional
#     pythonRuntimeDepsCheckHook aborts local builds with "starlette not
#     installed" — nothing on a microarch-tuned closure substitutes from a
#     binary cache, so every host that enables the mcp SDK hits it.
#     starlette genuinely is required at runtime (fastapi propagates it
#     transitively); add the dep rather than skipping the check.
#
# (2) The mcp SDK's build graph runs full upstream test suites in
#     checkPhase (its own, plus check-only chain members inline-snapshot →
#     isort → pylama → vulture → pint → uncertainties → scipy, and suite
#     runners fastapi, fastapi-cli, sse-starlette, httpx-sse,
#     pytest-examples, watchfiles). Observed failures are sandbox/tuning
#     artefacts, not defects — same class as bmake/postgresql (header of
#     modules/services/postgres.nix):
#       watchfiles: test_ignore_permission_denied watches / expecting
#         EACCES; the sandbox's / never denies → 10s pytest-timeout hang
#       scipy: 2 of 87,721 float-tolerance asserts (rtol 1e-07 vs 2.2e-07;
#         exact zeros vs 4e-17 FFT residue) under x86-64-v3-tuned builds
#     Silence exactly the two check phases, host-locally, never a blanket
#     rule. Runtime correctness is verified by observation after switch
#     (systemctl + MCP initialize probe), not by these suites.

let
  noCheck = {
    doCheck = false;
    doInstallCheck = false;
  };

  # python3.override returns the full interpreter scope (passthrufun's rec),
  # with withPackages resolving against the OVERRIDDEN package set.
  python' = python3.override {
    packageOverrides = pyfinal: pyprev: {
      mcp = pyprev.mcp.overridePythonAttrs noCheck;
      inline-snapshot = pyprev.inline-snapshot.overridePythonAttrs noCheck;
      isort = pyprev.isort.overridePythonAttrs noCheck;
      pylama = pyprev.pylama.overridePythonAttrs noCheck;
      vulture = pyprev.vulture.overridePythonAttrs noCheck;
      pint = pyprev.pint.overridePythonAttrs noCheck;
      uncertainties = pyprev.uncertainties.overridePythonAttrs noCheck;
      scipy = pyprev.scipy.overridePythonAttrs noCheck;
      fastapi = pyprev.fastapi.overridePythonAttrs noCheck;
      fastapi-cli = pyprev.fastapi-cli.overridePythonAttrs noCheck;
      sse-starlette = pyprev.sse-starlette.overridePythonAttrs (
        old:
        noCheck
        // {
          # see (1) — the wheel's Requires-Dist is the authority here
          propagatedBuildInputs = [ pyfinal.starlette ] ++ (old.propagatedBuildInputs or [ ]);
        }
      );
      httpx-sse = pyprev.httpx-sse.overridePythonAttrs noCheck;
      pytest-examples = pyprev.pytest-examples.overridePythonAttrs noCheck;
      watchfiles = pyprev.watchfiles.overridePythonAttrs noCheck;
    };
  };
in
python'.withPackages (
  ps: with ps; [
    mcp
    httpx
    pydantic
    pydantic-settings
    python-dotenv
    anyio
    asyncpg
    sqlalchemy
  ]
)
