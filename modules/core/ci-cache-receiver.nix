{
  config,
  lib,
  ...
}:

# The receiving end of the CI push path: a low-privilege login user on europa
# that GitHub Actions SSHes in as to `nix copy --to ssh://jupiter-ci@europa`
# the closures it builds (using GitHub's free CPU), plus the per-user GC-roots
# directory that pins the last N main-branch builds so europa's nix.gc doesn't
# evict what CI just pushed (see docs/ci-harmonia-push-runbook.md §retention).
#
# The user is in nix.settings.trusted-users so the daemon accepts path imports
# from it. Its SSH authorized key is the CI runner's PUBLIC key (a public value
# — safe in config); the matching private key lives only as the EUROPA_CI_SSH_KEY
# GitHub Actions secret. SSH is reachable only over the LAN/WireGuard path to
# 10.1.1.2 (europa is not publicly port-forwarded on 22), so the blast radius of
# a leaked CI key is "import/store paths on europa", not shell-on-the-NAS.
#
# Mirrors buildbot-nix's per-worker gcroots + trusted-user pattern
# (nixosModules/worker.nix), extended from keep-last-1 to a configurable N.

let
  cfg = config.jupiter.core.ciCacheReceiver;
in
{
  options.jupiter.core.ciCacheReceiver = {
    enable = lib.mkEnableOption "the jupiter-ci SSH/nix-copy receiver + GC-roots dir for GitHub Actions pushes";

    user = lib.mkOption {
      type = lib.types.str;
      default = "jupiter-ci";
      description = "Name of the receiving login user.";
    };

    authorizedKey = lib.mkOption {
      type = lib.types.str;
      default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL3B7HKhlapwb97py3c5Y1LTMBH1htrUSgY1GWQ5pqAq jupiter-ci@github-actions";
      description = ''
        The CI runner's PUBLIC ed25519 key (safe to commit). Generate the
        keypair, set the private half as the EUROPA_CI_SSH_KEY GitHub Actions
        secret, and paste the public half here. See
        docs/ci-harmonia-push-runbook.md.
      '';
    };

    retain = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = ''
        Number of most-recent main-branch builds to pin per host as GC roots.
        Older rooted builds are unrooted by scripts/ci/retain-recent.sh so
        europa's nix.gc can reclaim them.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.${cfg.user} = { };
    users.users.${cfg.user} = {
      isNormalUser = true;
      group = cfg.user;
      home = "/var/lib/${cfg.user}";
      description = "GitHub Actions CI nix-copy receiver";
      openssh.authorizedKeys.keys = [ cfg.authorizedKey ];
    };

    # Allow the daemon to accept store-path imports over this SSH user's
    # `nix copy --to ssh://...`. Merges with any other trusted-users entries.
    nix.settings.trusted-users = [ cfg.user ];
    # Signatures stay REQUIRED (the nix default). CI signs every path it
    # pushes: scripts/ci/post-build-hook.sh runs `nix store sign` with the
    # HARMONIA_KEY before `nix store copy`, so europa verifies instead of
    # trusting whatever arrives over SSH. (require-sigs=false here was a
    # P0: it made europa's store accept unsigned imports from ANY
    # trusted-user context, silently corrupting the trust chain Harmonia
    # downstream relies on — europa serves these paths to the fleet.)

    # Per-user GC-roots dir owned by the receiver, where CI registers one
    # indirect root per build (<host>.<sha>) for the retain-recent rotation.
    # Log directory for post-build-hook (written by CI via SSH).
    systemd.tmpfiles.rules = [
      "d /nix/var/nix/gcroots/per-user/${cfg.user} 0755 ${cfg.user} ${cfg.user} - -"
      "d /var/log/jupiter-ci 0755 ${cfg.user} ${cfg.user} - -"
    ];
  };
}
