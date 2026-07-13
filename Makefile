.PHONY: build-all check update fmt fmt-check pallene-iso rebuild-world

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

# ---------------------------------------------------------------------------
# Ephemeral BinaryLane "rebuild the world" build server. See
# hosts/pallene/configuration.nix + modules/services/build-server.nix.
# Required sops keys (secrets/secrets.yaml): binarylane_api_token,
# attic_push_token — set real values via `sops secrets/secrets.yaml` before
# the first real run (committed values are dummy placeholders).
# ---------------------------------------------------------------------------

# Build the pallene ISO with the BinaryLane API + attic push tokens baked in.
# Materializes plaintext secrets from sops, builds, then removes the plaintext
# copies immediately (gitignored — see .gitignore). Do NOT use plain
# `nix build .#pallene-iso` for a real run — that bakes in the dummy
# placeholder tokens; always go through this target.
pallene-iso:
	@echo "Materializing pallene build-server secrets from sops..."
	@mkdir -p secrets/pallene-secrets
	sops exec-env secrets/secrets.yaml 'printf "%s" "$$binarylane_api_token" > secrets/pallene-secrets/binarylane-api-token'
	sops exec-env secrets/secrets.yaml 'printf "%s" "$$attic_push_token" > secrets/pallene-secrets/attic-push-token'
	@echo "Building pallene ISO..."
	nix build .#pallene-iso
	@echo "Cleaning up plaintext secrets (gitignored — do not commit)..."
	rm -f secrets/pallene-secrets/binarylane-api-token secrets/pallene-secrets/attic-push-token

# Build the ISO, then boot it on BinaryLane to run one rebuild-the-world cycle.
# On this branch the BinaryLane create/attach-ISO/wait lifecycle is a manual
# step (the driving scripts from master aren't ported yet): upload the built
# ISO (./result/iso/*.iso) to a host BinaryLane can fetch, create a server
# booted from it, and let the build-server module self-destruct on completion.
# The cloud-init user-data can carry a target git ref (overriding defaultRef).
rebuild-world: pallene-iso
	@echo "pallene ISO built at ./result — boot it on BinaryLane to run one cycle:"
	@echo "  1. Upload ./result/iso/*.iso to a URL BinaryLane can fetch."
	@echo "  2. Create a BinaryLane VPS (>=8 vcpu / 16GB) booted from the custom ISO."
	@echo "     Optional: set user-data to a git ref to build a specific commit."
	@echo "  3. The build-server module clones the repo, builds europa's btver2"
	@echo "     closure, pushes to attic.jupiter.au, then self-destructs."
	@echo "  4. On europa: \`attic cache create jupiter-os\` (if not done), then"
	@echo "     \`nixos-rebuild switch\` substitutes the tuned closure from localhost:8080."
	@echo "See docs/plans/2026-07-13-001-feat-europa-phase2-tuned-closure-plan.md."
