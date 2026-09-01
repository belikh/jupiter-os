{ lib
, stdenv
, fetchPnpmDeps
, pnpmConfigHook
, makeWrapper
, python3
, gnumake
, pkg-config
, nodejs
, pnpm_10
, open-design
, jq
,
}:
# OpenDesign daemon with better_sqlite3 bumped to 13.0.3 to fix Node 24.19
# crash (RemoveEnvironmentCleanupHook: env != nullptr in
# Statement::~Statement). Upstream pins 12.10.0 (v131, Node 22) while the
# fleet runs nodejs_24 v137 (24.19). 13.0.3 ships v137 prebuilds and the
# V8 API fix, so the daemon stays on Node 24 (no v3 Node compile) and
# Design Harness (od-next) no longer crash-loops.
let
  pname = "open-design-daemon";
  version = (lib.importJSON "${open-design}/package.json").version;

  # Keep in sync with open-design/flake.nix daemonWorkspacePaths
  workspacePaths = [
    "packages/release"
    "packages/contracts"
    "packages/registry-protocol"
    "packages/agui-adapter"
    "packages/plugin-runtime"
    "packages/sidecar-proto"
    "packages/launcher-proto"
    "packages/sidecar"
    "packages/platform"
    "packages/diagnostics"
    "apps/daemon"
  ];

  pnpmWorkspaceFilters = map (workspacePath: "./${workspacePath}") workspacePaths;

  # Patched src with better_sqlite3 bumped for Node 24.19. Overwrites BOTH
  # apps/daemon/package.json AND the root pnpm-lock.yaml — fetchPnpmDeps and
  # the install phase both run `pnpm install --frozen-lockfile`, which
  # rejects a manifest whose specifiers don't match the lockfile
  # (ERR_PNPM_OUTDATED_LOCKFILE). The lockfile alongside this default.nix
  # was regenerated with `pnpm install` after the bump; refresh it whenever
  # the pinned version changes.
  patchedSrc = stdenv.mkDerivation {
    name = "open-design-patched-src";
    src = open-design;
    nativeBuildInputs = [ jq ];
    installPhase = ''
      cp -r $src $out
      chmod -R u+w $out
      ${lib.getExe jq} --arg v "13.0.3" '.dependencies."better-sqlite3" = $v' $out/apps/daemon/package.json > $out/apps/daemon/package.json.tmp && mv $out/apps/daemon/package.json.tmp $out/apps/daemon/package.json
      cp ${./pnpm-lock.yaml} $out/pnpm-lock.yaml
      echo "Bumped better_sqlite3 to 13.0.3 for Node 24.19 in patchedSrc"
      grep -q '"better-sqlite3": "13.0.3"' $out/apps/daemon/package.json || (echo "bump failed" >&2; exit 1)
      grep -q 'better-sqlite3@13.0.3' $out/pnpm-lock.yaml || (echo "lockfile copy failed" >&2; exit 1)
    '';
  };

  src = patchedSrc;
  pnpmDepsSrc = patchedSrc;

  # Use fakeHash to discover the correct pnpmDeps hash after the bump.
  # First build will fail with “got: sha256-…”, copy that into pnpmDepsHash
  # and rebuild. Keep the original hash as a comment for reference.
  pnpmDepsHash = "sha256-t/ERjkHsCHqI24aCGJ10peRN4NkPdkG5gs+262eu37o="; # was lib.fakeHash, was (import "${open-design}/nix/pnpm-deps.nix").daemonHash for 12.10.0

  pnpm_10_fixed = pnpm_10;
in
stdenv.mkDerivation (finalAttrs: {
  inherit pname version src;

  pnpmWorkspaces = pnpmWorkspaceFilters;

  nativeBuildInputs = [
    nodejs
    pnpm_10_fixed
    pnpmConfigHook
    makeWrapper
    python3
    gnumake
    pkg-config
  ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version;
    src = pnpmDepsSrc;
    hash = pnpmDepsHash;
    pnpm = pnpm_10_fixed;
    pnpmWorkspaces = pnpmWorkspaceFilters;
    fetcherVersion = 3;
  };

  env.NODE_ENV = "production";

  buildPhase = ''
    runHook preBuild

    export npm_config_nodedir=${nodejs}
    export npm_config_build_from_source=true
    export PATH="${nodejs}/lib/node_modules/npm/bin/node-gyp-bin:$PATH"

    bsq_dir=$(find node_modules/.pnpm -mindepth 2 -maxdepth 4 \
      -type d -path '*/better-sqlite3@*/node_modules/better-sqlite3' \
      -print -quit)
    if [ -z "$bsq_dir" ]; then
      echo "ERROR: better-sqlite3 not found under node_modules/.pnpm — pnpm install may have failed" >&2
      exit 1
    fi

    # Stage the upstream prebuild rather than building from source. 13.0.3
    # ships v137 prebuilds (Node 24 = ABI 137) — that is the entire point of
    # the bump (see header). The node-gyp source build generated empty gyp
    # targets under the Nix sandbox (TOUCH-only make, no CC/LD for either
    # better_sqlite3 or test_extension) and never produced the .node; the
    # prebuild is upstream's own Node-24 binary. node-gyp-build resolves
    # build/Release first, so copy the platform prebuild there.
    echo "Staging better-sqlite3 13.x prebuild (Node $(node --version), ABI $(node -p process.versions.modules)) at $bsq_dir/build/Release/"
    (
      cd "$bsq_dir"
      mkdir -p build/Release
      cp prebuilds/linux-x64.node build/Release/better_sqlite3.node
    )

    if [ ! -f "$bsq_dir/build/Release/better_sqlite3.node" ]; then
      echo "ERROR: better_sqlite3.node was not staged at $bsq_dir/build/Release/" >&2
      find "$bsq_dir" -name '*.node' -print >&2 || true
      exit 1
    fi

    for target in ${lib.escapeShellArgs workspacePaths}; do
      pnpm -C "$target" run --if-present build
    done
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/open-design $out/bin

    cp -r . $out/lib/open-design/

    for target in ${lib.escapeShellArgs workspacePaths}; do
      if [ "$target" = "apps/daemon" ]; then
        find "$out/lib/open-design/$target" -mindepth 1 -maxdepth 1 \
          ! -name dist \
          ! -name bin \
          ! -name node_modules \
          ! -name package.json \
          -exec rm -rf {} +
      else
        find "$out/lib/open-design/$target" -mindepth 1 -maxdepth 1 \
          ! -name dist \
          ! -name node_modules \
          ! -name package.json \
          -exec rm -rf {} +
      fi
    done

    rm -f \
      $out/lib/open-design/node_modules/@open-design/components \
      $out/lib/open-design/node_modules/@open-design/tools-dev \
      $out/lib/open-design/node_modules/@open-design/tools-pack \
      $out/lib/open-design/node_modules/@open-design/tools-release \
      $out/lib/open-design/node_modules/@open-design/tools-serve \
      $out/lib/open-design/node_modules/.bin/tools-dev \
      $out/lib/open-design/node_modules/.bin/tools-pack \
      $out/lib/open-design/node_modules/.bin/tools-release \
      $out/lib/open-design/node_modules/.bin/tools-serve

    chmod +x $out/lib/open-design/apps/daemon/dist/cli.js

    makeWrapper ${nodejs}/bin/node $out/bin/od \
      --add-flags $out/lib/open-design/apps/daemon/dist/cli.js \
      --set NODE_ENV production
    runHook postInstall
  '';

  passthru = {
    inherit nodejs;
    pnpmDeps = finalAttrs.pnpmDeps;
  };

  meta = with lib; {
    description = "OpenDesign daemon — local agent orchestrator + API (`od` CLI) (better_sqlite3 13.0.3 for Jupiter)";
    homepage = "https://github.com/nexu-io/open-design";
    license = licenses.asl20;
    mainProgram = "od";
    platforms = platforms.linux ++ platforms.darwin;
  };
  })
