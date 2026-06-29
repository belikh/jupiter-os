.PHONY: test-lenovo test-t460s test-nas test-dashboards test-elitedesk update check build-all build-mx4300 \
        fmt fmt-check tf-plan-unifi tf-apply-unifi tf-plan-cloudflare tf-apply-cloudflare \
        boot-smoke-lenovo boot-smoke-t460s boot-smoke-nas boot-smoke-dashboards

# Build all machines and firmware (useful for verifying everything compiles)
build-all:
	@echo "Building Lenovo compute node..."
	nix build .#nixosConfigurations.lenovo.config.system.build.toplevel
	@echo "Building T460s laptop..."
	nix build .#nixosConfigurations.t460s.config.system.build.toplevel
	@echo "Building NAS..."
	nix build .#nixosConfigurations.nas.config.system.build.toplevel
	@echo "Building Dashboards..."
	nix build .#nixosConfigurations.dashboards.config.system.build.toplevel
	@echo "Building Elitedesk..."
	nix build .#nixosConfigurations.elitedesk.config.system.build.toplevel
	$(MAKE) build-mx4300
	@echo "All builds completed successfully!"

# Build the OpenWrt firmware with injected secrets
build-mx4300:
	@echo "Injecting secrets into OpenWrt config templates..."
	sops exec-env secrets/secrets.yaml 'envsubst < hosts/parents-house/access-points/mx4300-files/etc/uci-defaults/99-mesh-setup.sh.tmpl > hosts/parents-house/access-points/mx4300-files/etc/uci-defaults/99-mesh-setup.sh'
	sops exec-env secrets/secrets.yaml 'envsubst < hosts/parents-house/wyze-cams/wz_mini.conf.tmpl > hosts/parents-house/wyze-cams/wz_mini.conf'
	@echo "Building Linksys MX4300 OpenWrt Firmware..."
	nix build .#mx4300-firmware
	@echo "Cleaning up plaintext configs (do not commit these!)..."
	rm -f hosts/parents-house/access-points/mx4300-files/etc/uci-defaults/99-mesh-setup.sh
	rm -f hosts/parents-house/wyze-cams/wz_mini.conf

# Build and run a QEMU virtual machine for a specific host
# Usage: make test-lenovo
test-%:
	@echo "Building and launching VM for host: $*..."
	nixos-rebuild build-vm --flake .#$*
	@echo "Starting VM... (Press Ctrl+A then X to exit the QEMU console)"
	./result/bin/run-$*-vm -m 2048 -smp 2

# Headless boot smoke test: build the host VM and assert it reaches multi-user,
# then shut it down (no interactive console). Used by CI; needs /dev/kvm.
# Usage: make boot-smoke-t460s
boot-smoke-%:
	./scripts/boot-smoke.sh $* 300

# Update flake locks
update:
	nix flake update

# Check flake evaluation
check:
	nix flake check

# Format all Nix files with the flake's formatter (nixfmt-rfc-style)
fmt:
	nix fmt

# Verify formatting without writing changes (used by CI)
fmt-check:
	nix run nixpkgs#nixfmt-rfc-style -- --check .

# ---------------------------------------------------------------------------
# Terraform / terranix
#
# terranix renders the HCL in terraform/<stack>/default.nix to a config.tf.json,
# which we drop next to it (terraform reads *.tf.json and ignores *.nix). State
# lives in terraform/<stack>/ (gitignored). Provider credentials are pulled from
# the encrypted secrets and exported as TF_VAR_* via `sops exec-env`.
#
# Required secret keys (secrets/secrets.yaml):
#   unifi          -> unifi_password
#   cloudflare     -> cloudflare_api_token   (NOTE: add this; not yet present)
# ---------------------------------------------------------------------------

# $(1) = stack name (unifi|cloudflare), $(2) = terraform subcommand (plan|apply)
define tf-run
	@echo "Rendering terranix config for '$(1)'..."
	nix build .#terranix-$(1) --no-link --print-out-paths | xargs -I{} install -m600 {} terraform/$(1)/config.tf.json
	cd terraform/$(1) && terraform init -input=false
	@echo "Running 'terraform $(2)' for '$(1)' (secrets injected via sops)..."
	sops exec-env secrets/secrets.yaml 'cd terraform/$(1) && \
		TF_VAR_unifi_password="$$unifi_password" \
		TF_VAR_cloudflare_api_token="$$cloudflare_api_token" \
		terraform $(2)'
endef

tf-plan-unifi:
	$(call tf-run,unifi,plan)

tf-apply-unifi:
	$(call tf-run,unifi,apply)

tf-plan-cloudflare:
	$(call tf-run,cloudflare,plan)

tf-apply-cloudflare:
	$(call tf-run,cloudflare,apply)
