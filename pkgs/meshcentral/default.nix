{
  lib,
  fetchFromGitHub,
  buildNpmPackage,
  nodejs,
}:

# MeshCentral — the web-based remote monitoring and management server, built
# from the owner's fork (github:belikh/MeshCentral) at the revision europa
# deploys. Upstream ships no flake, and the fork carries fleet-specific work
# (the MCP bridge/credential surface, the command catalogue, the agent session
# registry) that upstream does not, so the source is pinned by revision rather
# than consumed as a flake input. Bump `rev` + `hash` together, and recompute
# `npmDepsHash` when the fork's package-lock.json changes (`nix build .#meshcentral`
# reports the correct value on a mismatch).
#
# Packaging mirrors nixpkgs' own meshcentral derivation: `npm ci` assembles
# node_modules from the committed lockfile, there is no build step
# (`dontNpmBuild`), and the two patches below repair the require paths and the
# entry point that `npm ci`'s install layout breaks. The fork's `.npmrc` sets
# `engine-strict = true`, and upstream supports Node >=20 LTS, so the runtime
# is pinned to nixpkgs' `nodejs_22` (the module and the flake package both pass
# it explicitly — never pkgs.nodejs, whose major the nixpkgs pin may float).
buildNpmPackage rec {
  pname = "meshcentral";
  version = "1.2.5";

  src = fetchFromGitHub {
    owner = "belikh";
    repo = "MeshCentral";
    rev = "e22a90aa529e349674c32e9ee32da1815b2cae3b";
    hash = "sha256-HHzs2sQ0wb+K4QW6cYUcxfStX60LRCl6x1IBCi1BYVU=";
  };

  patches = [
    # pkcs7-modified.js loads node-forge through a path relative to the
    # application root (`./node_modules/node-forge/...`). That path exists in a
    # git checkout but not in the npm-global layout `npm ci` produces, so
    # resolve the modules by package name instead.
    ./fix-js-include-paths.patch
    # meshcentral.js only calls mainStart() when it is the main module; the bin
    # shim npm generates `require`s it as a module, so nothing would start.
    # Unconditional mainStart() is correct for this packaging.
    ./run.patch
    # At boot MeshCentral verifies its required modules by reading each
    # package.json. Two of them (ua-client-hints-js, otplib) restrict `exports`
    # without exposing ./package.json, so the require-based probe throws
    # ERR_PACKAGE_PATH_NOT_EXPORTED and the fallback looks one level too high —
    # in the npm-global layout deps sit beside `meshcentral`, but buildNpmPackage
    # nests them under `meshcentral/node_modules`. Point the fallback at the
    # package's own node_modules; without this the server calls `npm install`
    # into the read-only store and exits.
    ./node-modules-path.patch
  ];

  npmDepsHash = "sha256-0qyegL+Ju6XEbMfzaz811WqB5Zr5GT50Ve3PVRRQL68=";

  inherit nodejs;

  dontNpmBuild = true;

  meta = {
    description = "Web-based remote monitoring and management server (belikh fork)";
    homepage = "https://github.com/belikh/MeshCentral";
    license = lib.licenses.asl20;
    mainProgram = "meshcentral";
    platforms = lib.platforms.linux;
  };
}
