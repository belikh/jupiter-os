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
# Materializes plaintext secrets from sops, STAGES them with `git add -f` so the
# pure flake build can see them (secrets/pallene-secrets/* is gitignored, so the
# flake's git-source filter hides the on-disk files and the ISO would otherwise
# bake the dummy .placeholder values — R2 log upload + self-destruct silently
# broke for exactly this reason on the first real run), builds, then unstages +
# removes the plaintext on EXIT (trap covers a failed/interrupted build too).
# Do NOT use plain `nix build .#pallene-iso` for a real run — that bakes in the
# dummy placeholder tokens; always go through this target.
pallene-iso:
	@echo "Materializing pallene build-server secrets from sops..."
	@mkdir -p secrets/pallene-secrets
	sops exec-env secrets/secrets.yaml 'printf "%s" "$$binarylane_api_token" > secrets/pallene-secrets/binarylane-api-token'
	sops exec-env secrets/secrets.yaml 'printf "%s" "$$attic_push_token" > secrets/pallene-secrets/attic-push-token'
	sops exec-env secrets/secrets.yaml 'printf "%s" "$$cloudflare_account_id" > secrets/pallene-secrets/r2-account-id'
	sops exec-env secrets/secrets.yaml 'printf "%s" "$$r2_access_key_id" > secrets/pallene-secrets/r2-access-key-id'
	sops exec-env secrets/secrets.yaml 'printf "%s" "$$r2_secret_access_key" > secrets/pallene-secrets/r2-secret-access-key'
	sops exec-env secrets/secrets.yaml 'printf "%s" "$$wireguard_pallene_private_key" > secrets/pallene-secrets/wireguard-private-key'
	@set -e; \
	SECS='secrets/pallene-secrets/binarylane-api-token secrets/pallene-secrets/attic-push-token secrets/pallene-secrets/r2-account-id secrets/pallene-secrets/r2-access-key-id secrets/pallene-secrets/r2-secret-access-key secrets/pallene-secrets/wireguard-private-key'; \
	git add -f $$SECS; \
	trap 'git reset -q $$SECS 2>/dev/null; rm -f $$SECS' EXIT; \
	echo "Building pallene ISO (real secrets staged so the pure flake build can see them)..."; \
	nix build .#pallene-iso

# Drive one full ephemeral build-server run: build the ISO, upload it to R2,
# then hand off to scripts/binarylane-build-server.sh to create the
# BinaryLane server, boot it from the ISO, and wait for it to rebuild the
# world and self-destruct. Requires awscli on PATH (for the R2 upload) and
# real values for the cloudflare_account_id / r2_access_key_id /
# r2_secret_access_key / binarylane_api_token sops keys. Override the build
# target git ref with GIT_REF=... (defaults to dashboard-v2).
rebuild-world: pallene-iso
	sops exec-env secrets/secrets.yaml '\
		export AWS_ACCESS_KEY_ID="$$r2_access_key_id"; \
		export AWS_SECRET_ACCESS_KEY="$$r2_secret_access_key"; \
		export R2_ACCOUNT_ID="$$cloudflare_account_id"; \
		export ISO_URL="$$(./scripts/upload-pallene-iso-r2.sh)"; \
		export BINARYLANE_API_TOKEN="$$binarylane_api_token"; \
		./scripts/binarylane-build-server.sh'
