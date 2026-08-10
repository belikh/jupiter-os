{ lib, fetchFromGitHub, nodePackages, stdenv, writeShellScriptBin, makeWrapper, pkgs, ... }:

let
  # Fetch aeonfun/aeon from GitHub main branch
  # Update rev and sha256 when updating to a newer commit
  aeonSrc = fetchFromGitHub {
    owner = "aeonfun";
    repo = "aeon";
    rev = "main";
    sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    fetchSubmodules = false;
  };

  # Build the dashboard (Next.js app)
  dashboard = nodePackages.buildNodePackage {
    pname = "aeon-dashboard";
    version = "0.1.0";

    src = aeonSrc + "/apps/dashboard";

    # Use the package.json from the dashboard app
    packageJSON = aeonSrc + "/apps/dashboard/package.json";

    # Don't run tests during build
    doCheck = false;

    # Build the Next.js app
    buildCommand = "npm run build";

    # Install dependencies
    npmFlags = [ "--production=false" ];

    # Required native dependencies for Next.js
    nativeBuildInputs = [ nodePackages.node-gyp ];

    # Environment variables for build
    NODE_ENV = "production";
    NEXT_TELEMETRY_DISABLED = "1";
  };

  # Build the CLI (TypeScript app that uses dashboard lib)
  cli = nodePackages.buildNodePackage {
    pname = "aeon-cli";
    version = "0.1.0";

    src = aeonSrc + "/apps/cli";

    packageJSON = aeonSrc + "/apps/cli/package.json";

    doCheck = false;

    buildCommand = "npm run build";

    npmFlags = [ "--production=false" ];

    nativeBuildInputs = [ nodePackages.node-gyp ];

    NODE_ENV = "production";
  };

  # Wrap the aeon launcher script to use pre-built artifacts
  # The original ./aeon launcher is at aeonSrc/aeon
  aeonLauncher = writeShellScriptBin "aeon" ''
    #!/usr/bin/env bash
    set -euo pipefail

    DIR="${BASH_SOURCE[0]%/*}"
    ROOT_DIR="${DIR}/../.."

    # The pre-built CLI entry point
    CLI_DIST="${ROOT_DIR}/apps/cli/dist/index.js"
    DASHBOARD_DIR="${ROOT_DIR}/apps/dashboard"

    if [ "$#" -gt 0 ]; then
      # CLI mode: delegate to pre-built CLI
      exec node "$CLI_DIST" "$@"
    else
      # Dashboard mode: start Next.js server
      cd "$DASHBOARD_DIR"
      exec node node_modules/next/dist/bin/next start -p 5555 -H 0.0.0.0
    fi
  '';

  # Combined package with both dashboard and CLI
  combined = stdenv.mkDerivation {
    pname = "aeon";
    version = "0.1.0";

    src = aeonSrc;

    buildInputs = [ dashboard cli aeonLauncher ];

    installPhase = ''
      mkdir -p $out/bin
      mkdir -p $out/lib/aeon

      # Copy pre-built dashboard
      cp -r ${dashboard}/.next $out/lib/aeon/.next
      cp -r ${dashboard}/public $out/lib/aeon/public 2>/dev/null || true
      cp -r ${dashboard}/node_modules $out/lib/aeon/node_modules 2>/dev/null || true
      cp ${dashboard}/package.json $out/lib/aeon/package.json

      # Copy pre-built CLI
      cp -r ${cli}/dist $out/lib/aeon/cli-dist
      cp ${cli}/package.json $out/lib/aeon/cli-package.json

      # Copy the launcher
      cp ${aeonLauncher} $out/bin/aeon
      chmod +x $out/bin/aeon

      # Create a symlink for the dashboard start script
      ln -s $out/bin/aeon $out/bin/aeon-dashboard
    '';

    # Make the output relocatable
    dontStrip = true;
  };

in
{
  inherit combined dashboard cli;
  aeon-dashboard = combined;
  aeon-cli = combined;
}