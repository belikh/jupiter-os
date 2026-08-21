.PHONY: build-all check update fmt fmt-check verify-arcade status-arcade fixture-arcade docs docs-serve

# Build every registered host closure (the 4 dashboard kiosks).
build-all:
	@echo "Building dashboard kiosks (amalthea, metis, adrastea, thebe)..."
	nix build .#nixosConfigurations.amalthea.config.system.build.toplevel
	nix build .#nixosConfigurations.metis.config.system.build.toplevel
	nix build .#nixosConfigurations.adrastea.config.system.build.toplevel
	nix build .#nixosConfigurations.thebe.config.system.build.toplevel
	@echo "All builds completed successfully!"

# Build documentation site (mdBook) from all jupiter.* modules
docs:
	nix build .#docs
	@echo "Documentation built at ./result/index.html"

# Serve documentation locally with mdbook serve
docs-serve: docs
	@echo "Serving documentation at http://localhost:3000"
	@echo "Press Ctrl+C to stop"
	nix run nixpkgs#mdbook -- serve ./result

# Build and run a QEMU virtual machine for a specific host
# Usage: make test-amalthea
test-%:
	@echo "Building and launching VM for host: $*..."
	nixos-rebuild build-vm --flake .#$*
	@echo "Starting VM... (Press Ctrl+A then X to exit the QEMU console)"
	./result/bin/run-$*-vm -m 2048 -smp 2

# Headless boot smoke test: build the host VM and assert it reaches
# multi-user, then shut it down (no interactive console). Used by CI; needs
# /dev/kvm.
# Usage: make boot-smoke-amalthea
boot-smoke-%:
	./scripts/boot-smoke.sh $* 300

# Empirical eXo Pegasus metadata checks (issue #40 acceptance / issue #42
# item 5). Needs the collections actually mounted, so it can't be a
# `nix flake check` — run it on europa against the curated dataset roots, or
# on a kiosk against its merge mounts (jupiter.exodos.mergeMountBase,
# default /mnt/exo-games — see modules/desktop/exodos.nix). Not runnable
# from a plain dev checkout with no eXo mounts present.
# Usage: make verify-arcade [ROOTS="/other/path/exo-dos ..."]
ROOTS ?= /mnt/exo-games/exo-dos /mnt/exo-games/exo-win3x /mnt/exo-games/exo-win9x
verify-arcade:
	./scripts/verify-exo-collections.sh $(ROOTS)

# Fleet arcade status — pretty-print europa's generated inventory JSON
# (cartridge ROM counts/sizes + eXo art coverage). Requires europa reachable
# at 10.1.1.2 and the arcade-inventory timer to have run at least once.
status-arcade:
	./scripts/arcade-status.sh

# Regenerate the arcade-webapp fixture ROM tree (deterministic, self-authored
# dummy bytes — see tests/fixtures/arcade/README.md) and run the igir
# zero-unmatched gate over it (gauntlet plan §1.3 item 6 / AC-3 fixture half).
# Needs go on PATH; igir comes from the flake's locked nixpkgs via nix run
# (override with IGIR=/path/to/igir to use a local binary).
fixture-arcade:
	./scripts/fixture-arcade.sh

# Update flake locks
update:
	nix flake update

# Evaluate all flake checks (every host closure). Eval-only (--no-build):
# once a host sets jupiter.build.microarch its closure derivations carry
# requiredSystemFeatures=["gccarch-<arch>"] and can't build on a dev machine
# without the matching system-feature + the Harmonia substituter. The
# real build verification lives in CI's build matrix (kiosks) and the
# build server (microarch-tuned hosts). Use `make build-all` for a local
# full build of the 4 kiosk closures (skylake-tuned — needs the system-feature
# + Harmonia).
check:
	nix flake check --no-build

# Format all Nix files with the flake's formatter (nixfmt-rfc-style)
fmt:
	nix fmt .

# Verify formatting without writing changes (used by CI)
fmt-check:
	nix run nixpkgs#nixfmt-rfc-style -- --check .
