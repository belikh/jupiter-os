{
  lib,
  buildNpmPackage,
  nodejs,
  fetchurl,
}:

# remote-opencode (github.com/bevibing/remote-opencode) — Discord bot that
# bridges a local OpenCode CLI to Discord slash commands. Packaged from the
# published npm tarball, same pattern as pkgs/dsh: upstream ships dist/
# prebuilt with no lockfile, so package-lock.json next to this file was
# generated with `npm install --package-lock-only --omit=dev` against the
# tarball's own package.json (~216 prod-only entries, pure JS except one).
# Regenerate it when bumping `version`. The pin is deliberate — update by
# changing version + re-locking, never by floating.
#
# node-pty note: declared in package.json but imported NOWHERE in dist/
# (leftover from the shell-spawn feature removed upstream in 1.5.1), so the
# sandboxed skip of lifecycle scripts costs nothing — its prebuild-download
# install script could never run here anyway.
buildNpmPackage rec {
  pname = "remote-opencode";
  version = "1.5.3";

  src = fetchurl {
    url = "https://registry.npmjs.org/remote-opencode/-/remote-opencode-${version}.tgz";
    hash = "sha512-pP1aOaxjC7XJL/P+IF1JaP7B0GT13ODTb1fZJVHW6FCnqBQgmI/hFZ0tAXjvvgh9VCboI68ERrWYCKJ3FLxCzA==";
  };

  # The tarball ships no lockfile; graft the generated one in so `npm ci`
  # + fetchNpmDeps have a deterministic tree to work from.
  postPatch = ''
    cp ${./package-lock.json} package-lock.json

    # Discord hard-rejects message edits past 2000 chars (BASE_TYPE_MAX_LENGTH).
    # Upstream's 1-second stream ticker feeds UNCHUNKED formatOutput() into a
    # single message.edit, so any reply longer than ~2k chars fails every tick
    # ("Failed to edit stream message" spam) and the live view never updates —
    # observed live on callisto 2026-08-26. Keep the TAIL (freshest tokens)
    # inside the limit; final delivery already chunks via
    # formatOutputForMobile()/splitIntoChunks(1900). Reported upstream.
    substituteInPlace dist/src/services/executionService.js \
      --replace-fail "const newContent = formatted || 'Processing...';" \
        "const newContent = (formatted && formatted.length > 1700) ? '…' + formatted.slice(-1680) : (formatted || 'Processing...');"
  '';

  npmInstallFlags = [ "--omit=dev" ];

  dontNpmBuild = true;
  dontNpmTest = true;

  inherit nodejs;

  npmDepsHash = "sha256-XhyL3UorD1nOko/ecMZBLmbzsvW3AEyCYWcVTCrNUG8=";

  meta = {
    description = "Discord bot for remote OpenCode CLI access";
    homepage = "https://github.com/bevibing/remote-opencode";
    license = lib.licenses.mit;
    mainProgram = "remote-opencode";
    platforms = lib.platforms.linux;
  };
}
