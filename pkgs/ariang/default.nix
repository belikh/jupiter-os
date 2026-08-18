{
  lib,
  fetchFromGitHub,
  buildNpmPackage,
  nodejs,
}:

# AriaNg — the browser-based UI for aria2's JSON-RPC. Built from source
# (upstream master d6a7653, the commit this tree's task-name patch is based
# on) so the patch below applies cleanly, instead of the prebuilt AllInOne
# zip the module used to fetch (1.3.12, which carries no source-level patch
# site).
#
# package-lock.json next to this file is the upstream lockfile re-generated
# with a modern npm (`npm install --package-lock-only --no-audit --no-fund`):
# the committed one is npm 6-era v1 which fetchNpmDeps can't use (git deps
# lack resolved/integrity). It pins the one git dependency
# (angular-input-dropdown) to a commit; prefetch-npm-deps rewrites git URLs
# to codeload tarballs, so no SSH access is needed. Graft it in via postPatch
# (same trick as pkgs/dsh).
#
# `gulp build` (the `npm run build` default) emits the static site into
# dist/; nginx serves that directory directly. gulp's git-rev-sync usage is
# wrapped in tryFn (gulpfile.js) so the source tree needs no .git dir.
buildNpmPackage rec {
  pname = "ariang";
  version = "1.3.14";

  src = fetchFromGitHub {
    owner = "mayswind";
    repo = "AriaNg";
    rev = "d6a765377e1eecfbcc387dcb824124df114decfb";
    hash = "sha256-NLXgszZUBF/LC2moWe4wQQbMDkhdvNxYeL+AO1fhQMw=";
  };

  patches = [ ./aria-task-name-from-dir.patch ];

  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  # `npm run build` = `gulp clean build`. The default buildNpmPackage
  # installPhase runs `npm pack` for npm-package-shaped outputs; a static
  # web UI just needs dist/ served.
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r dist/. $out/
    runHook postInstall
  '';

  dontNpmTest = true;

  # npm v11 needs to write to the cache (the fetcher's store copy is
  # read-only); buildNpmPackage copies it to $TMPDIR when this is set.
  makeCacheWritable = true;

  inherit nodejs;

  npmDepsHash = "sha256-FwGD+XXJ9YOxfNQ6Rvj/J/+E8yLxXyW7qjYe7nYkqhE=";

  meta = {
    description = "AriaNg web UI for aria2, built with a task-name-from-dir patch";
    homepage = "https://github.com/mayswind/AriaNg";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}