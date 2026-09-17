# OpenDesign source with better-sqlite3 bumped to 13.0.3 for Node 24.19.
#
# Why the bump: upstream pins better-sqlite3 12.10.0 (ABI v131 / Node 22)
# while the fleet runs nodejs_24 24.19 (ABI v137). The 12.x addon crashes
# at startup there (RemoveEnvironmentCleanupHook: env != nullptr in
# Statement::~Statement), which took down Design Harness (od-next) in a
# crash-loop. 13.0.3 ships v137 prebuilds plus the V8 API fix, so the
# daemon can stay on Node 24 (no v3 Node compile).
#
# Both consumers (pkgs/open-design-daemon, pkgs/open-design-web) build from
# THIS tree, never the raw src, so the daemon manifest, the lockfile and
# the fetched pnpm store are always consistent:
#   - apps/daemon/package.json is patched to the bumped version;
#   - pnpm-lock.yaml is replaced by the vendored lockfile, regenerated with
#     `pnpm install --lockfile-only` against the bumped manifest (pnpm
#     refuses `--frozen-lockfile` when specifiers and lockfile disagree —
#     ERR_PNPM_OUTDATED_LOCKFILE). Refresh it whenever `open-design-src` is
#     bumped: patch a checkout of the new rev, run the command above (pnpm
#     10.33.2), and copy the result over pkgs/open-design-patched/pnpm-lock.yaml.
{
  lib,
  stdenv,
  jq,
  src,
  lockfile ? ./pnpm-lock.yaml,
}:
stdenv.mkDerivation {
  name = "open-design-patched-src";
  inherit src;
  nativeBuildInputs = [ jq ];
  installPhase = ''
    cp -r $src $out
    chmod -R u+w $out

    ${lib.getExe jq} --arg v "13.0.3" \
      '.dependencies."better-sqlite3" = $v' \
      $out/apps/daemon/package.json > $out/apps/daemon/package.json.tmp
    mv $out/apps/daemon/package.json.tmp $out/apps/daemon/package.json

    cp ${lockfile} $out/pnpm-lock.yaml

    echo "Bumped better_sqlite3 to 13.0.3 for Node 24.19 in patched src"
    grep -q '"better-sqlite3": "13.0.3"' $out/apps/daemon/package.json \
      || (echo "better-sqlite3 bump failed" >&2; exit 1)
    grep -q 'better-sqlite3@13.0.3' $out/pnpm-lock.yaml \
      || (echo "vendored lockfile does not carry better-sqlite3@13.0.3" >&2; exit 1)
  '';
}
