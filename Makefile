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
# Ephemeral BinaryLane "rebuild the world" build server — a generic, runtime-
# parameterized builder: which git ref, which hosts, every secret, all
# arrive via cloud-init user_data at server-create time (see
# scripts/binarylane-build-server.sh and modules/services/build-server.nix).
# The ISO itself carries NO secrets and needs rebuilding only when
# hosts/pallene/configuration.nix, build-server.nix, or wireguard.nix change.
# Required sops keys (secrets/secrets.yaml): binarylane_api_token,
# attic_push_token, cloudflare_account_id, r2_access_key_id,
# r2_secret_access_key, wireguard_pallene_private_key — set real values via
# `sops secrets/secrets.yaml` before the first real run.
# ---------------------------------------------------------------------------

# Build the pallene ISO. Nothing secret goes into it anymore — a plain
# `nix build` is enough (no sops materialization, no git-staging dance).
# Rebuild only actually needed when the pallene config/modules change; nix
# no-ops (a few seconds) otherwise.
pallene-iso:
	nix build .#pallene-iso

# Drive one full ephemeral build-server run: build the ISO (a no-op if
# unchanged), upload it to R2 (fixed key — overwrites, doesn't accumulate),
# then hand off to scripts/binarylane-build-server.sh, which builds the
# cloud-init user_data blob from these same sops secrets, creates the
# BinaryLane server, boots it from the ISO, and waits for it to rebuild the
# world and self-destruct.
#
# Override at invocation, none require an ISO rebuild:
#   GIT_REF=<branch/commit>   which ref to build (default: the ISO's baked default)
#   HOSTS=host1,host2         which nixosConfigurations to build (default: baked default, currently "europa")
#   MAX_JOBS=<n|auto>         nix build --max-jobs (default: baked default, "auto" = nproc)
#   CORES=<n>                 nix build --cores, per concurrent job (default: baked default, 1 — see
#                             modules/services/build-server.nix's nix.settings.cores comment before raising this)
#   TIMEOUT_SECS=<seconds>    external polling ceiling (default 36000 = 10h)
#   BL_SIZE_SLUG=<slug>       force one exact BinaryLane size, skip the tier fallback
#   ATTIC_SERVER=http://...   attic login/push endpoint (default: baked default, currently
#                             http://neptune.jupiter.au:8080 — a UDM port-forward straight to
#                             europa's atticd, NOT the WireGuard mesh; only the attic-client
#                             login/push path honours this, nix's own substituter is baked
#                             from the same option at ISO build time and can't be runtime-
#                             overridden — see atticServer's doc in build-server.nix)
rebuild-world: pallene-iso
	sops exec-env secrets/secrets.yaml '\
		export AWS_ACCESS_KEY_ID="$$r2_access_key_id"; \
		export AWS_SECRET_ACCESS_KEY="$$r2_secret_access_key"; \
		export R2_ACCOUNT_ID="$$cloudflare_account_id"; \
		export ISO_URL="$$(./scripts/upload-pallene-iso-r2.sh)"; \
		export BINARYLANE_API_TOKEN="$$binarylane_api_token"; \
		export ATTIC_PUSH_TOKEN="$$attic_push_token"; \
		export WIREGUARD_PRIVATE_KEY="$$wireguard_pallene_private_key"; \
		export R2_ACCESS_KEY_ID="$$r2_access_key_id"; \
		export R2_SECRET_ACCESS_KEY="$$r2_secret_access_key"; \
		./scripts/binarylane-build-server.sh'
