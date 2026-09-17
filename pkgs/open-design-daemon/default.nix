# OpenDesign daemon (`od` CLI + /api server).
#
# The source arrives pre-patched (better-sqlite3 13.0.3 + matching lockfile)
# from pkgs/open-design-patched — see that derivation for the Node 24.19
# rationale. This package only builds and installs it.
#
# Vendored when upstream retired its Nix distribution (2026-08-31,
# nexu-io/open-design@49cc5105). The workspace list is the transitive
# `workspace:*` dependency closure of @open-design/daemon at the pinned
# rev, in dependency order (verify against the repo's package.jsons when
# bumping open-design-src; it matched the retired flake's
# daemonWorkspacePaths at 0.22.1).
{
  lib,
  stdenv,
  fetchPnpmDeps,
  pnpmConfigHook,
  makeWrapper,
  python3,
  gnumake,
  pkg-config,
  nodejs,
  pnpm_10,
  src,
  version,
}:
let
  pname = "open-design-daemon";

  # Transitive `workspace:*` runtime-dependency closure of @open-design/daemon
  # at the pinned rev, in topological build order: each entry's workspace
  # dependencies appear earlier in the list, because buildPhase runs
  # `pnpm -C <target> run build` sequentially and tsc resolves the
  # dependencies' emitted dist/. Recompute when bumping open-design-src
  # (0.22.1 edges: sidecar → platform, launcher-proto → sidecar-proto,
  # agui-adapter/plugin-runtime → contracts, contracts/sidecar-proto/
  # launcher-proto → release).
  workspacePaths = [
    "packages/release"
    "packages/contracts"
    "packages/agui-adapter"
    "packages/plugin-runtime"
    "packages/sidecar-proto"
    "packages/launcher-proto"
    "packages/platform"
    "packages/sidecar"
    "packages/diagnostics"
    "packages/registry-protocol"
    "apps/daemon"
  ];

  pnpmWorkspaceFilters = map (workspacePath: "./${workspacePath}") workspacePaths;

  # Bump after changing src/lockfile/workspacePaths: `nix build .#open-design-daemon`
  # reports the fetched-store hash in the mismatch error, copy it here.
  pnpmDepsHash = "sha256-w5PgyUyslRbyv9BiGO2ySwgbCAXQ1oki8lzh6iVJsCU=";
in
stdenv.mkDerivation (finalAttrs: {
  inherit pname version src;

  pnpmWorkspaces = pnpmWorkspaceFilters;

  nativeBuildInputs = [
    nodejs
    pnpm_10
    pnpmConfigHook
    makeWrapper
    python3
    gnumake
    pkg-config
  ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version;
    src = finalAttrs.src;
    hash = pnpmDepsHash;
    pnpm = pnpm_10;
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
    # the bump (see pkgs/open-design-patched). The node-gyp source build
    # generated empty gyp targets under the Nix sandbox (TOUCH-only make, no
    # CC/LD for either better_sqlite3 or test_extension) and never produced
    # the .node; the prebuild is upstream's own Node-24 binary.
    # node-gyp-build resolves build/Release first, so copy the platform
    # prebuild there.
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
