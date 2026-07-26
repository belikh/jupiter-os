.PHONY: update check boot-smoke-%

update:
	./scripts/fake-nix-flake-update.sh

check:
	./scripts/fake-check.sh

boot-smoke-%:
	./scripts/fake-boot-smoke.sh $*
