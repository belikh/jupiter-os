.PHONY: test-lenovo test-t460s test-nas test-dashboards test-elitedesk update check

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
