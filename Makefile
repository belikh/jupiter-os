.PHONY: test-lenovo test-t460s test-nas test-dashboards test-elitedesk update check build-all

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
	@echo "Building Linksys MX4300 OpenWrt Firmware..."
	nix build .#mx4300-firmware
	@echo "All builds completed successfully!"

# Build and run a QEMU virtual machine for a specific host
# Usage: make test-lenovo
test-%:
	@echo "Building and launching VM for host: $*..."
	nixos-rebuild build-vm --flake .#$*
	@echo "Starting VM... (Press Ctrl+A then X to exit the QEMU console)"
	./result/bin/run-$*-vm -m 2048 -smp 2

# Update flake locks
update:
	nix flake update

# Check flake evaluation
check:
	nix flake check
