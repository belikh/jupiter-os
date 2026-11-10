# Security audit

Criteria for the security dimension of `nixos-review`. Each row:
**check → detect → severity**. Sources accessed 2026-09-30.

## Secrets

| Check | Detect | Severity |
|---|---|---|
| No plaintext secrets anywhere, including git history | `gitleaks git --redact -v`; `rg -n -i 'password\s*=\s*"[^"]+"\|api[_-]?key\|-----BEGIN .*PRIVATE KEY\|sk-[A-Za-z0-9]{20,}'` | blocker (rotate first, then purge) |
| No secret reaches evaluation or the store (`writeText`, `environment.etc`, `builtins.readFile`, `toString`, activation scripts) | trace every value derived from a decrypted path; the store is world-readable | blocker |
| Passwords use `hashedPasswordFile` (from the secret manager) not plaintext `password`/`initialPassword` | `rg 'password\s*=\|initialPassword'` | critical on a real secret |
| sops/agenix declarations set `owner`/`group`/`mode` for the consumer, not default root | `rg 'sops\.secrets\|age\.secrets'`; compare to the unit's `User` | major |
| `neededForUsers = true` used only for password hashes (it cannot set an owner) | `rg neededForUsers` | critical if carrying a usable secret beyond hashes |
| Consuming units are in `restartUnits`/`reloadUnits` so rotation takes effect | cross-check each secret's consumers | major |
| Recipients are current: no departed hosts, dummy/placeholder keys, or missing `updatekeys` after edits | `.sops.yaml`/agenix rules vs hosts; `rg 'REPLACE\|dummy\|placeholder'` | major; blocker if a committed private key exists |
| Decryption identities live outside the store, are 0600, and are recoverable (escrow/backup) | `sops.age.keyFile`/`sshKeyPaths`, `identityPaths`; backup runbooks | major; blocker if no recovery path for critical secrets |

## Privilege and accounts

| Check | Detect | Severity |
|---|---|---|
| `mutableUsers` posture is intentional | `rg mutableUsers`; `false` on servers is drift-free, not mandatory | minor |
| Wheel membership minimal; `wheelNeedsPassword` intact | `rg 'wheel\|security.sudo'` | critical for NOPASSWD `ALL`, major otherwise |
| No user-writable binary in a sudo rule | inspect `security.sudo.extraRules` | critical |
| sshd: no `PermitRootLogin = "yes"`; password auth posture deliberate (the NixOS default is *enabled* — not itself a mistake) | `rg 'services.openssh\|PermitRootLogin\|PasswordAuthentication'` | major for `yes`; minor for password auth on a public host |
| `authorizedKeys.keys` only (public); `keyFiles` read at build time | `rg 'authorizedKeys'` | minor; major if a private key is referenced |
| Network-facing units run as a dedicated/DynamicUser, not root (`User=` unset means root) | `rg 'systemd.services'`, check `serviceConfig.User` | major |

## Network exposure

| Check | Detect | Severity |
|---|---|---|
| Firewall posture reviewed: `allowed*Ports` open to all interfaces; `openFirewall = true` is a claim to verify | `rg 'allowedTCPPorts\|allowedUDPPorts\|openFirewall\|firewall\.interfaces'` | major for DB/admin/API ports; blocker for unauthenticated admin surfaces |
| Services bind deliberately (explicit `listenAddress`/bind where the design is local-only) | read unit/service options; unset often means `0.0.0.0` | major where credentials cross an untrusted network |
| Overlay VPN keys held in secrets and referenced by file | `rg 'privateKey\s*=\|privateKeyFile'`; inline private keys are world-readable | blocker for inline private key |
| VPN peer `AllowedIPs` matches the role (full-tunnel is a client pattern, not a server one) | `rg AllowedIPs` | major for server-side `0.0.0.0/0` |
| `checkReversePath = false` scoped to the interface it is needed on | `rg checkReversePath` | minor scoped, major global |

## systemd hardening

Calibration first: `systemd-analyze security` itself warns that a high
exposure score "neither means … no effective sandboxing … nor that the service
is actually vulnerable". Flag missing hardening on network-facing units; do
not demand it on NFS/database/hardware daemons that cannot tolerate it.

| Check | Detect | Severity |
|---|---|---|
| Network-facing services have at least `NoNewPrivileges`, filesystem protection, and a dedicated user | `systemd-analyze security <unit>` (0–10 exposure); `systemctl show <unit> -p ProtectSystem -p ProtectHome -p NoNewPrivileges -p DynamicUser` | major when running as root with full FS access |
| `ProtectSystem=strict` paired with state via `StateDirectory`/`ReadWritePaths` rather than blanket writes | read `serviceConfig` | minor–major |
| Restrictive syscall/address families only where compatible (JVM/.NET/shell services legitimately need `MemoryDenyWriteExecute=false`) | read unit; do not flag compatibility exceptions | minor / no finding |
| `DynamicUser` not required — the wiki notes it is often impractical on NixOS | judgement; a static dedicated user is acceptable | none |

## Supply chain and CI

| Check | Detect | Severity |
|---|---|---|
| Actions pinned to full commit SHAs (tags can move) | `rg 'uses: \w+/\S+@(v[0-9]+\|main\|master)' .github/workflows` | major; critical in jobs with secrets/write |
| Workflow `permissions` minimised per job | `rg 'permissions:'`; `contents: write` on PR workflows | critical |
| No privileged trigger checking out untrusted PR code (`pull_request_target`, `workflow_run`, `issue_comment` + `head.sha/ref`) | grep triggers and `persist-credentials` | blocker |
| Self-hosted runners not used for public repos (fork PRs persist compromise) | runner labels in workflows | blocker |
| No `curl \| bash` / build scripts from untrusted refs executing with secrets | grep install steps | major; critical with secrets |
| Nix refs in CI are locked, not mutable | `rg 'github:'` builds without lock; `builtins.fetch*` unhashed | major |

## Update and vulnerability posture

| Check | Detect | Severity |
|---|---|---|
| Release branch supported (EOL check) | `rg 'nixos-2[0-9]\.'` vs endoflife.date | critical for EOL, blocker for long-EOL |
| `system.autoUpgrade` settings deliberate (URI pin, `allowReboot` + `rebootWindow`, staggering) | `rg 'autoUpgrade'` | major for unchecked reboot authority |
| Unfree/insecure/broken allowances carry per-package rationale | `allowUnfree`, `permittedInsecurePackages`, `meta.knownVulnerabilities` suppressions | major for a network daemon |
| No exposed debug interfaces (debug ports, admin UIs, anonymous MQTT) | service options; `ss -tlnp` on live hosts | blocker for anonymous admin/control |

## Calibration — do not flag

- NixOS sshd defaults (`PasswordAuthentication = true`) and `openFirewall` on
  an opted-in service: defaults, not misconfigurations.
- A service on `0.0.0.0` behind an authenticated reverse proxy, by design.
- Public keys in the world-readable store: they are public.
- `root:root` ownership of a root-consumed secret: the default.
- A deliberate kiosk with password auth or a full-tunnel VPN client.
- Over-hardening gaps where the service's own model forbids the sandbox.

One finding per root cause; separate "explicitly enabled exposure" from
"default left unchanged"; require a reachable attacker path before elevating.

## Sources

- NixOS manual, firewall and security: https://nixos.org/manual/nixos/stable/#sec-firewall (accessed 2026-09-30)
- nixpkgs sshd, sudo, users-groups, auto-upgrade modules: https://github.com/NixOS/nixpkgs (accessed 2026-09-30)
- systemd.exec sandboxing directives: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html (accessed 2026-09-30)
- systemd-analyze security caveat: https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html (accessed 2026-09-30)
- NixOS wiki, Systemd/Hardening: https://wiki.nixos.org/wiki/Systemd/Hardening (accessed 2026-09-30)
- sops-nix: https://github.com/Mic92/sops-nix; agenix: https://github.com/ryantm/agenix (accessed 2026-09-30)
- GitHub Actions security hardening: https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions (accessed 2026-09-30)
- GitHub Security Lab, preventing pwn requests: https://securitylab.github.com/resources/github-actions-preventing-pwn-requests (accessed 2026-09-30)
- Gitleaks: https://github.com/gitleaks/gitleaks (accessed 2026-09-30)
- endoflife.date, NixOS: https://endoflife.date/nixos (accessed 2026-09-30)
- NixOS wiki, WireGuard: https://wiki.nixos.org/wiki/WireGuard (accessed 2026-09-30)
