{
  lib,
  stdenv,
  fetchPnpmDeps,
  pnpmConfigHook,
  makeWrapper,
  python3,
  gnumake,
  pkg-config,
  nodejs_22,
  pnpm_10,
  open-design,
}:
# OpenDesign daemon rebuilt with Node 22 to avoid better_sqlite3 12.10.0
# crash on Node 24.19 (RemoveEnvironmentCleanupHook: env != nullptr).
# Upstream builds with nodejs_24 (v137) but better_sqlite3 12.10.0 only
# has prebuilds up to v131 (Node 22) and its from-source build still
# triggers the V8 API bug on 24.19. Node 22 is LTS and has v127 prebuilds,
# so the native binding is stable.
#
# This derivation mirrors open-design/nix/package-daemon.nix but pins
# nodejs to nodejs_22. All other inputs (pnpm_10, src filtering, workspace
# list) are identical to the upstream flake's perSystem daemon derivation
# so the pnpmDeps hash stays valid.
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

  pnpmDepsHash = (import "${open-design}/nix/pnpm-deps.nix").daemonHash;
  pnpmWorkspaceFilters = map (workspacePath: "./${workspacePath}") workspacePaths;

  src = open-design;
  pnpmDepsSrc = open-design;

  # Use the flake's exact pnpm 10.33.2 tarball so fetchPnpmDeps matches
  # the install phase (see open-design/flake.nix pnpm_10 override).
  pnpm_10_fixed = pnpm_10;

  nodejs = nodejs_22;
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

    echo "Building better-sqlite3 from source at $bsq_dir (Node $(node --version), better-sqlite3 12.x)"
    ( cd "$bsq_dir" && node-gyp rebuild --release --build-from-source )

    if [ ! -f "$bsq_dir/build/Release/better_sqlite3.node" ]; then
      echo "ERROR: better_sqlite3.node was not produced at $bsq_dir/build/Release/" >&2
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
    description = "OpenDesign daemon — local agent orchestrator + API (`od` CLI) (Node 22 rebuild for Jupiter)";
    homepage = "https://github.com/nexu-io/open-design";
    license = licenses.asl20;
    mainProgram = "od";
    platforms = platforms.linux ++ platforms.darwin;
  };
})
