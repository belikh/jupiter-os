.PHONY: build-all check update fmt fmt-check

# Build every registered host closure (the 4 dashboard kiosks).
build-all:
	@echo "Building dashboard kiosks (amalthea, metis, adrastea, thebe)..."
	nix build .#nixosConfigurations.amalthea.config.system.build.toplevel
	nix build .#nixosConfigurations.metis.config.system.build.toplevel
	nix build .#nixosConfigurations.adrastea.config.system.build.toplevel
	nix build .#nixosConfigurations.thebe.config.system.build.toplevel
	@echo "All builds completed successfully!"

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

# Update flake locks
update:
	nix flake update

# Evaluate all flake checks (every host closure). Eval-only (--no-build):
# once a host sets jupiter.build.microarch its closure derivations carry
# requiredSystemFeatures=["gccarch-<arch>"] and can't build on a dev machine
# without the matching system-feature + the private attic substituter. The
# real build verification lives in CI's boot-test matrix (kiosks) and the
# build server (microarch-tuned hosts). Use `make build-all` for a local
# full build of the untuned hosts.
check:
	nix flake check --no-build

# Format all Nix files with the flake's formatter (nixfmt-rfc-style)
fmt:
	nix fmt .

# Verify formatting without writing changes (used by CI)
fmt-check:
	nix run nixpkgs#nixfmt-rfc-style -- --check .
