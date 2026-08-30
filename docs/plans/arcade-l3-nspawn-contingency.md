# L3/L2 degraded tier — the nspawn contingency lane

**Status:** named contingency (arcade remediation plan §6.E binding
condition; SPEC.md §3), documented per W3. Not built. This file is the
design that gets implemented the day hosted KVM disappears.

## What it exists for

The L2 (`arcade-webapp-vm`) and L3 (`arcade-webapp-browser-vm`) checks
boot QEMU VMs on the CI runner. Hosted KVM for public repos is
generosity, not contract. Both CI jobs therefore carry a **fail-loud
`/dev/kvm` probe** that refuses the silent TCG fallback (software
emulation, 10–12× slower, misdiagnosing as flaky timeouts — the exact
failure class that gets a gate deleted in week two). When that probe
fires, the answer is NOT "re-run hoping it passes" and NOT "delete the
gate". The answer is: implement this lane.

## The design

Run the same test targets — the real `modules/services/arcade-webapp.nix`
against the deterministic fixture corpus, plus the chromium/Playwright
browser contract — inside systemd-nspawn containers instead of QEMU:

- The pinned nixpkgs' test framework supports nspawn natively: test
  nodes expose a `containers` attribute set backed by
  `modules/virtualisation/nspawn-container` (nixos/lib/testing/nodes.nix
  at the locked rev) — the driver boots them in seconds with no
  `/dev/kvm` and near-native speed, over the same testScript API.
- The L2 smoke (`jupiter-arcade-webapp-smoke.service`) and the L3
  browser service (`jupiter-arcade-webapp-browser.service`) are plain
  systemd units driving HTTP against 127.0.0.1 — they are
  hypervisor-agnostic by construction and move over unmodified.
- Chromium-in-container needs no GPU and no KVM; the playwright browser
  farm (`playwright-driver.browsers-chromium`) is a store path either
  way.

## What it costs

- **Lost:** the kernel/boot plane. The nspawn lane shares the host
  kernel; QEMU-specific behaviour (initrd, direct kernel boot, the
  boot-time budget) is no longer exercised. That plane is L5's kiosk
  smoke territory anyway.
- **Kept:** everything the 403/swap-contract class lives in — the real
  module, the real service manager, the real browser sending real
  headers, the real fragment swaps.
- **Migration cost:** roughly a day (new flake check wiring the same
  host files into the nspawn backend, one CI job rename, one green run,
  one negative-test re-proof per lane).

## Switch procedure

1. The `/dev/kvm` probe in `arcade-webapp-l2-vm` / `arcade-webapp-l3-browser`
   fails on main (this is the trigger — it is loud by design).
2. Implement the nspawn variants as `checks.x86_64-linux.arcade-webapp-nspawn`
   and `arcade-webapp-browser-nspawn`, importing the SAME host files
   (`tests/hosts/arcade-webapp-vm.nix`, `tests/hosts/arcade-webapp-browser-vm.nix`).
3. Re-run the L3 negative test (break `hxRequestOK`, expect
   `ARCADE-WEBAPP-BROWSER: FAIL … 403`, revert) against the nspawn lane
   before trusting it — a lane that has never gone red is not a lane.
4. Delete the QEMU jobs only after the nspawn jobs are green and
   negative-proven; update SPEC.md §3 and the ledger. Never leave both
   silently failing.
