# Operations audit

Criteria for the operations dimension of `nixos-review`. Each row:
**check → detect → severity**. Sources accessed 2026-09-30.

## Deployment topology

| Check | Detect | Severity |
|---|---|---|
| The deployed revision equals the reviewed commit (no mutable refs, no `--refresh` on production paths) | read CI/deploy scripts, `system.autoUpgrade.flake`, runbooks | major |
| Each topology's assumptions are met (on-host pull needs outbound net + secrets on host; push needs SSH + elevation; CI-built needs cache reachability) | match the mechanism to host reality; check a substitute-only host can actually substitute | major |
| Rollback path is explicit per topology and reachable by a human | runbook; generations exist; remote console/SSH alternative | major; blocker when the only rollback is disabled |
| Tool auto-rollback (deploy-rs magic rollback) not disabled without a replacement guard | `rg 'magicRollback\|autoRollback'` | blocker on console-less hosts |
| No `nix-collect-garbage -d` in scheduled units or runbooks before verification practice exists | `rg 'collect-garbage'` .github scripts/ systemd units | blocker |

## Generations and rollback

| Check | Detect | Severity |
|---|---|---|
| Boot-entry retention is sized to the ESP and to the rollback policy (`configurationLimit`) | evaluate options; `ls /boot/loader/entries`; `findmnt /boot` | blocker when unbounded on a small ESP; major when too low to keep a rollback |
| Current generation is not already the only one (GC/prune policy keeps a known-good) | `nixos-rebuild list-generations`; GC config | major |
| A written rollback runbook exists (boot menu, `switch-to-configuration boot`, `switch --rollback`) | docs/runbooks | major on remote hosts |
| `nix.gc`/`system.autoUpgrade.runGarbageCollection` do not silently delete rollback targets | read module config | major |

## Backup and recovery

| Check | Detect | Severity |
|---|---|---|
| Backup set covers declarative-system state (`/var/lib` service dirs, databases, `/etc/machine-id`, `/var/lib/nixos`, ZFS datasets) | reconcile backup paths against the state inventory | major for each critical gap |
| Secrets/age identities are escrowed outside the machine and repo | runbook; `sops.age.keyFile`/`identityPaths` locations | blocker if unrecoverable |
| Snapshots are not treated as backups (same-pool snapshots die with the pool) | ZFS/sanoid config; replication off-pool? | major |
| Backup policy is tested: restore runbook exists and retention/prune are dry-run reviewed | restic `check --read-data-subset` evidence; `forget --dry-run` discipline | blocker when no restore test exists, major when periodic verification is absent |
| Total-loss bootstrap is documented (installer path, where SSH/age keys live, what is rebuilt vs restored) | docs/runbooks | major |

## CI

| Check | Detect | Severity |
|---|---|---|
| What CI proves is named accurately (eval ≠ build ≠ boot) and every host appears in the matrix | workflows vs `nixosConfigurations` attrs | major for missing hosts; major when eval is called "tested" |
| Cache write is restricted: trusted branches only, no write on `pull_request_target`/`workflow_run` | triggers, `cache-mode`, token scope | blocker |
| Jobs cannot leak secrets to untrusted code | trigger + checkout + `persist-credentials` + secrets usage | blocker |
| Failure handling: no `continue-on-error` on build/test/deploy; timeouts and `concurrency` set | `rg 'continue-on-error\|timeout-minutes\|concurrency'` | major |
| Actions pinned, permissions minimal, installer pinned, `flake.lock` committed | workflow review | major |
| Recent build retention by store GC roots, not Actions cache (caches evict) | `nix-store --add-root`/`nix build --out-link` in CI | minor–major |

## Observability and operability

| Check | Detect | Severity |
|---|---|---|
| Journals persist (`Storage=persistent`, `/var/log/journal` on disk) for post-mortem and reboot forensics | `journalctl --disk-usage`, `journalctl -b -1`; `services.journald.*` | major on production |
| Critical services have restart/watchdog semantics | `Restart=`, `WatchdogSec=` in unit config | major for the critical set |
| Time sync exists and timers order against it (RTC-less hosts need `systemd-time-wait-sync`) | `timedatectl`; `after time-sync.target` | major |
| Disk/ZFS/RAID health has monitoring and alerts, not just logs | `zpool status -x`, smartd, sanoid monitor options, alerting path | major |
| `system.autoUpgrade` is observed, not blind: reboots bounded (`rebootWindow`), schedule staggered | module config | major for unobserved reboots |
| "Production" vs kiosk expectations are stated so the findings are calibrated | repo docs | minor–major |

## Boot chain

| Check | Detect | Severity |
|---|---|---|
| The host can boot the previous generation (fallback exists, entries retained) | bootloader config, `configurationLimit`, boot menu in a VM | blocker on console-less remote hosts with no fallback |
| Single ESP / no mirror on critical hosts is a known, accepted risk | `efibootmgr -v`, `findmnt /boot`, mirrored boots | major; blocker where loss of the ESP is unrecoverable remotely |
| `neededForBoot` complete for all boot-required mounts | `fileSystems.*.neededForBoot`, impermanence volumes | blocker (stage 1 hang) |
| Network-rooted hosts (iSCSI/NFS) have initrd networking and a recovery story | initrd config, docs | blocker for those hosts |
| PXE/netboot chains have no unnoticed single point of failure; pinned toplevels and ordering are documented | `rg 'pxe\|netboot\|ipxe'`; docs | major |
| Irreversible installs (nixos-anywhere/disko) have device paths and runbook matches | disk config vs runbook | blocker on mismatch |

## Documentation versus reality

| Check | Detect | Severity |
|---|---|---|
| Runbook hostnames/paths/commands resolve against the repo and live state | cross-check every named host against `nixosConfigurations`, every path against `fileSystems` | blocker when it would misdirect recovery; major for a wrong path; minor for cosmetics |
| Status claims ("live", "done", "tested") match git history and observable state | spot-check the claims | major |
| Irreversible operations have a named procedure and warning | docs | major when absent |

## Sources

- NixOS manual, state/GC/rollback/autoUpgrade/netboot/release notes: https://nixos.org/manual/nixos/stable/ (accessed 2026-09-30)
- nixpkgs `auto-upgrade.nix`, systemd-boot and GRUB modules: https://github.com/NixOS/nixpkgs (accessed 2026-09-30)
- nix.dev, provisioning remote machines, binary caches, post-build-hook, CI: https://nix.dev/tutorials/nixos/provisioning-remote-machines and guides/recipes (accessed 2026-09-30)
- deploy-rs: https://github.com/serokell/deploy-rs; colmena: https://github.com/nix-community/colmena; nixos-anywhere: https://github.com/nix-community/nixos-anywhere (accessed 2026-09-30)
- restic forget/check/encryption: https://restic.readthedocs.io/en/stable/ (accessed 2026-09-30)
- sanoid: https://github.com/jimsalterjrs/sanoid; OpenZFS man pages: https://openzfs.github.io/openzfs-docs/man/master/ (accessed 2026-09-30)
- GitHub Actions secure use and caching: https://docs.github.com/en/actions (accessed 2026-09-30)
- journald/timer/service man pages: https://www.freedesktop.org/software/systemd/man/latest/ (accessed 2026-09-30)
