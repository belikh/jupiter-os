{
  lib,
  buildNpmPackage,
  nodejs,
  fetchurl,
}:

# DeepSeek Harness (`dsh`) — DeepSeek AI's open-source agent harness
# ("everything is a plugin", powered by Cordis). Pinned to the published
# npm tarball of @deepseek-ai/dsh, which ships the CLI prebuilt (lib/bin.js
# + bundled chunks) but NOT a lockfile — package-lock.json next to this
# file was generated with `npm install --package-lock-only --omit=dev`
# against the tarball's own package.json and pins the full prod-only
# dependency tree (~637 entries, all pure JS). Regenerate it when bumping
# `version`. The project is a fast-moving developer preview, so the pin is
# deliberate: update by changing version + re-locking, never by floating.
#
# No build/test phases: the tarball is the built artifact (upstream CI
# publishes it from `dist/npm/…tgz`); `npm ci --omit=dev` just assembles
# node_modules around it.
buildNpmPackage rec {
  pname = "dsh";
  version = "0.1.0-rc.6";

  src = fetchurl {
    url = "https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-${version}.tgz";
    hash = "sha512-brpZfED7ieRa2PQ5tUxMhHrM1pb2CmKFVM/f6yMULBDMicahk+Z2OsHgTwTDnoiZm23Ftu9rQz0NN4pflaoJcg==";
  };

  # The tarball ships no lockfile; graft the generated one in so
  # `npm ci` + fetchNpmDeps have a deterministic tree to work from.
  #
  # 0.1.0-rc.6 mounts the cordis HMR receiver whose loader hard-requires
  # node's --expose-internals ("--expose-internals is required for HMR
  # service") even though both shipped app bundles disable the hmr row
  # (upstream rc bug: the disable doesn't take effect in the composed
  # tree). NODE_OPTIONS cannot carry the flag (node rejects it there), so
  # bake it into the shebang — the kernel passes it as the single allowed
  # shebang argument. Worker threads/fork() inherit process.execArgv, so
  # spawned profile processes get it too; `dsh plugin`'s pnpm child is
  # unaffected (it never reads our execArgv).
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
    substituteInPlace lib/bin.js \
      --replace-fail '#!/usr/bin/env node' '#!${nodejs}/bin/node --expose-internals'
  '';

  # npm's global bin shim execs node directly, bypassing bin.js's shebang
  # above — inject the flag into the shim itself so process.execArgv
  # carries it on every invocation path. --replace-fail so a shim-template
  # change in a future nixpkgs breaks the build loudly instead of
  # silently dropping the flag.
  postFixup = ''
    substituteInPlace "$out/bin/dsh" \
      --replace-fail 'exec "${nodejs}/bin/node"  ${placeholder "out"}/lib/node_modules/@deepseek-ai/dsh/lib/bin.js' \
                     'exec "${nodejs}/bin/node" --expose-internals ${placeholder "out"}/lib/node_modules/@deepseek-ai/dsh/lib/bin.js'
  '';

  npmInstallFlags = [ "--omit=dev" ];

  dontNpmBuild = true;
  dontNpmTest = true;

  inherit nodejs;

  npmDepsHash = "sha256-yvKSLb3oCpmIIhkrdFPVui9Hpxz68wBLqibDAFlBfbU=";

  meta = {
    description = "DeepSeek Harness (dsh) — agent harness with a web UI, everything is a plugin";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    license = lib.licenses.mit;
    mainProgram = "dsh";
    platforms = lib.platforms.linux;
  };
}
