REPO_ROOT := $(abspath ..)
PDK_ROOT ?= $(abspath $(REPO_ROOT)/../PDK)
PDK ?= ihp-sg13cmos5l
NIX_DIR ?= $(abspath $(REPO_ROOT)/../librelane)

.PHONY: all act_bank_container psum_requant_container efpga_subsystem_top zip unzip nix

all: act_bank_container psum_requant_container efpga_subsystem_top

act_bank_container:
	$(MAKE) -C act_bank_container PDK_ROOT="$(PDK_ROOT)" PDK="$(PDK)" NIX_DIR="$(NIX_DIR)"

psum_requant_container:
	$(MAKE) -C psum_requant_container PDK_ROOT="$(PDK_ROOT)" PDK="$(PDK)" NIX_DIR="$(NIX_DIR)"

efpga_subsystem_top:
	$(MAKE) -C efpga_subsystem_top PDK_ROOT="$(PDK_ROOT)" PDK="$(PDK)" NIX_DIR="$(NIX_DIR)"

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
	cd "$(NIX_DIR)" && nix-shell --run 'cd "$(CURDIR)" && exec bash --rcfile <(cat "$${HOME}/.bashrc"; printf "%s\n" '\''PS1="\[\\033[01;35m\][nix-shell]\[\\033[00m\] \[\\033[01;32m\]$${USER}@\\h\[\\033[00m\]:\[\\033[01;34m\]\\w\[\\033[00m\]> "'\'') -i'

