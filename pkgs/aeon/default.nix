{
  lib,
  fetchFromGitHub,
  stdenv,
  buildNpmPackage,
  nodejs,
  makeWrapper,
  pkgs,
  ...
}:

let
  # Fetch aeonfun/aeon from GitHub main branch.
  # Bump sha256 when updating: set to lib.fakeHash, build, paste the got: hash.
  aeonSrc = fetchFromGitHub {
    owner = "aeonfun";
    repo = "aeon";
    rev = "main";
    sha256 = "sha256-5CjJYn8DrcBR+Q7Y+V4PfmfRIhHJK8qpFND3FVXnOgQ=";
    fetchSubmodules = false;
  };

  # Install the dashboard's npm dependencies (offline via fetchNpmDeps).
  #
  # We do NOT run `next build` here: the dashboard fetches Google Fonts
  # (Inter, Space Mono) at build time via next/font/google, which requires
  # network — impossible inside the Nix sandbox. Instead, we install deps
  # only, and the NixOS module runs `next dev` at runtime (same as aeon's
  # own ./aeon launcher, which uses `npm run dev`, not `next start`).
  dashboard = buildNpmPackage {
    pname = "aeon-dashboard";
    version = "0.1.0";

    src = aeonSrc;
    sourceRoot = "source/apps/dashboard";

    npmDepsHash = "sha256-1I71PGGBoZaDxDb58ag/S/PuqxRyxZNX/LYSlMxe6zU=";

    # Don't run `next build` — the NixOS module runs `next dev` at runtime
    dontNpmBuild = true;

    doCheck = false;

    env = {
      NEXT_TELEMETRY_DISABLED = "1";
    };

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -r node_modules $out/node_modules
      cp package.json $out/package.json
      # Copy source files needed for `next dev`
      cp -r app $out/app
      cp -r components $out/components
      cp -r lib $out/lib
      cp -r public $out/public 2>/dev/null || true
      cp next.config.ts $out/next.config.ts
      cp tsconfig.json $out/tsconfig.json
      cp postcss.config.mjs $out/postcss.config.mjs 2>/dev/null || true
      cp proxy.ts $out/proxy.ts 2>/dev/null || true
      cp instrumentation.ts $out/instrumentation.ts 2>/dev/null || true

      runHook postInstall
    '';
  };

in
{
  inherit dashboard;
  aeon-dashboard = dashboard;
  aeon-cli = dashboard;
}
