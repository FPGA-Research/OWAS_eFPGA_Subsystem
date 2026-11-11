REPO_ROOT := $(abspath ..)
NIX_DIR ?= $(REPO_ROOT)/OWAS_Fabric/FABulous

.PHONY: all act_bank_container psum_requant_container efpga_subsystem_top zip unzip nix

all: act_bank_container psum_requant_container efpga_subsystem_top

act_bank_container:
	$(MAKE) -C act_bank_container

psum_requant_container:
	$(MAKE) -C psum_requant_container

efpga_subsystem_top:
	$(MAKE) -C efpga_subsystem_top

zip:
	$(MAKE) -C efpga_subsystem_top zip

unzip:
	find "$(REPO_ROOT)/MACROS" -name "*.zip" -exec sh -c '\
		set -eu; \
		for z do \
			dir=$${z%/*}; \
			(cd "$$dir" && unzip -oq "$${z##*/}"); \
			printf "Extracted %s\n" "$$z"; \
		done' sh {} +

nix:
	@test -f "$(NIX_DIR)/flake.nix" \
		|| { echo "ERROR: $(NIX_DIR) has no flake.nix: run git submodule update --init --recursive"; exit 1; }
	nix develop $(NIX_DIR) --command bash -c 'cd "$(CURDIR)" && exec bash --rcfile <(cat "$${HOME}/.bashrc"; printf "%s\n" '\''PS1="\[\\033[01;35m\][nix-shell]\[\\033[00m\] \[\\033[01;32m\]$${USER}@\\h\[\\033[00m\]:\[\\033[01;34m\]\\w\[\\033[00m\]> "'\'') -i'

