# OpenDesign web frontend (@open-design/web Next.js static export).
#
# Vendored from upstream nix/package-web.nix at nexu-io/open-design@db9ebb7b
# (last commit that shipped the official Nix distribution; retired in
# 49cc5105). Builds from the same patched src as the daemon so the daemon
# manifest, lockfile and fetched pnpm store stay byte-identical across the
# two packages.
#
# Output layout: $out/ contains the contents of `apps/web/out/` (an
# index.html plus _next/ and asset subdirectories). Drop $out into any
# static file server.
#
# OD_DAEMON_URL is set to "" at build time so the bundled JS issues
# relative requests (`/api/*`, `/artifacts/*`, `/frames/*`) instead of
# baking a build-time daemon URL into the export. The serving environment
# is therefore expected to be same-origin with the daemon — callisto's
# caddy reverse-proxies those paths to `127.0.0.1:<daemon port>`.
#
# The workspace list is the transitive `workspace:*` closure of
# @open-design/web at the pinned rev, in dependency order. Verify it against
# the repo's package.jsons when bumping open-design-src (it matched the
# retired flake's webWorkspacePaths at 0.22.1).
{
  lib,
  stdenv,
  fetchPnpmDeps,
  pnpmConfigHook,
  nodejs,
  pnpm_10,
  src,
  version,
}:
let
  pname = "open-design-web";

  workspacePaths = [
    "packages/components"
    "packages/release"
    "packages/contracts"
    "packages/host"
    "packages/platform"
    "packages/sidecar"
    "packages/sidecar-proto"
    "apps/web"
  ];

  pnpmWorkspaceFilters = map (workspacePath: "./${workspacePath}") workspacePaths;
  dependencyBuildPaths = lib.filter (workspacePath: workspacePath != "apps/web") workspacePaths;

  # Bump after changing src/lockfile/workspacePaths: `nix build .#open-design-web`
  # reports the fetched-store hash in the mismatch error, copy it here.
  pnpmDepsHash = "sha256-R1RhYbav95ZcGVpTewxKAQ9G14rg08TySbWbyU7nd8U=";
in
stdenv.mkDerivation (finalAttrs: {
  inherit pname version src;

  pnpmWorkspaces = pnpmWorkspaceFilters;

  nativeBuildInputs = [
    nodejs
    pnpm_10
    pnpmConfigHook
  ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version;
    src = finalAttrs.src;
    hash = pnpmDepsHash;
    # Force the deps-fetch derivation to use the fleet's pinned pnpm_10 as
    # well. fetchPnpmDeps defaults to `pkgs.pnpm` when `pnpm` is omitted.
    pnpm = pnpm_10;
    pnpmWorkspaces = pnpmWorkspaceFilters;
    fetcherVersion = 3;
  };

  env = {
    NODE_ENV = "production";
    OD_DAEMON_URL = "";
  };

  buildPhase = ''
    runHook preBuild
    for target in ${lib.escapeShellArgs dependencyBuildPaths}; do
      pnpm -C "$target" run --if-present build
    done

    # next.config.ts gates static-export emission on NODE_ENV=production and
    # writes to apps/web/out/.
    pnpm --filter @open-design/web run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r apps/web/out/. $out/
    runHook postInstall
  '';

  passthru = {
    inherit nodejs;
    pnpmDeps = finalAttrs.pnpmDeps;
  };

  meta = with lib; {
    description = "OpenDesign — Next.js static SPA (apps/web)";
    homepage = "https://github.com/nexu-io/open-design";
    license = licenses.asl20;
    platforms = platforms.linux ++ platforms.darwin;
  };
})
