# Shared by librelane/<macro>/Makefile. MACRO defaults to the folder name, FILELIST to
# FILE_LISTS/asic/<macro>_asic.f.
# Run the targets inside the FABulous nix env (make nix): it provides LibreLane and the tools,
# and FAB_PDK_HASH, the PDK version of the whole project.
LIBRELANE_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT := $(abspath $(LIBRELANE_DIR)/..)
LL_DIR ?= $(CURDIR)
MACRO ?= $(notdir $(LL_DIR))
FILELIST ?= $(REPO_ROOT)/FILE_LISTS/asic/$(MACRO)_asic.f
NIX_DIR ?= $(REPO_ROOT)/OWAS_Fabric/FABulous
VIEWS_DIR ?= $(REPO_ROOT)/MACROS/$(MACRO)/views

PDK_FAMILY ?= ihp-sg13
PDK ?= ihp-sg13cmos5l
PDK_ROOT ?= $(HOME)/.ciel/$(PDK_FAMILY)

# LibreLane auto-loads librelane_plugin_* modules from PYTHONPATH
export PYTHONPATH := $(LIBRELANE_DIR)$(if $(PYTHONPATH),:$(PYTHONPATH))

# VERILOG_FILES come from the filelist, passed to librelane before config.yaml
VERILOG_FILES_JSON := $(LL_DIR)/verilog_files.json
LL_CONFIGS := $(VERILOG_FILES_JSON) $(LL_DIR)/config.yaml
LL_ARGS := --pdk $(PDK) --pdk-root $(PDK_ROOT) --manual-pdk

.PHONY: all
all: librelane

.PHONY: librelane librelane-explore librelane-nodrc librelane-magicdrc librelane-klayoutdrc
librelane: check-versions $(VERILOG_FILES_JSON)
	librelane $(LL_CONFIGS) $(LL_ARGS) --save-views-to $(VIEWS_DIR)/

librelane-explore: check-versions $(VERILOG_FILES_JSON)
	librelane $(LL_CONFIGS) $(LL_ARGS) --save-views-to $(VIEWS_DIR)/ --flow SynthesisExploration

librelane-nodrc: check-versions $(VERILOG_FILES_JSON)
	librelane $(LL_CONFIGS) $(LL_ARGS) --save-views-to $(VIEWS_DIR)/ --skip KLayout.DRC --skip Magic.DRC --skip KLayout.Antenna --skip KLayout.Density

librelane-magicdrc: check-versions $(VERILOG_FILES_JSON)
	librelane $(LL_CONFIGS) $(LL_ARGS) --save-views-to $(VIEWS_DIR)/ --skip KLayout.DRC

librelane-klayoutdrc: check-versions $(VERILOG_FILES_JSON)
	librelane $(LL_CONFIGS) $(LL_ARGS) --save-views-to $(VIEWS_DIR)/ --skip Magic.DRC

.PHONY: librelane-openroad librelane-klayout
librelane-openroad: check-versions $(VERILOG_FILES_JSON)
	librelane $(LL_CONFIGS) $(LL_ARGS) --last-run --flow OpenInOpenROAD

librelane-klayout: check-versions $(VERILOG_FILES_JSON)
	librelane $(LL_CONFIGS) $(LL_ARGS) --last-run --flow OpenInKLayout

# Always regenerated (absolute paths, cheap)
$(VERILOG_FILES_JSON): FORCE
	python3 $(REPO_ROOT)/scripts/filelist_to_librelane.py $(FILELIST) -o $@

.PHONY: FORCE
FORCE:

.PHONY: check-versions
check-versions:
	@test -n "$(FAB_PDK_HASH)" \
		|| { echo "ERROR: FAB_PDK_HASH is not set: run the targets inside make nix"; exit 1; }
	@test "$$(readlink -f $(PDK_ROOT)/$(PDK))" = "$$(readlink -f $(PDK_ROOT)/ciel/$(PDK_FAMILY)/versions/$(FAB_PDK_HASH)/$(PDK))" \
		|| { echo "ERROR: $(PDK_ROOT)/$(PDK) is not $(PDK_FAMILY) $(FAB_PDK_HASH). Run: ciel enable --pdk-family $(PDK_FAMILY) $(FAB_PDK_HASH)"; exit 1; }
	@python3 -c 'import librelane, pathlib; print((pathlib.Path(librelane.__file__).parent / "pdk_hashes.yaml").read_text())' \
		| grep -q "^$(PDK_FAMILY): $(FAB_PDK_HASH)$$" \
		|| { echo "ERROR: the LibreLane in this shell does not recommend $(PDK_FAMILY) $(FAB_PDK_HASH)"; exit 1; }

.PHONY: nix
nix:
	@test -f "$(NIX_DIR)/flake.nix" \
		|| { echo "ERROR: $(NIX_DIR) has no flake.nix: run git submodule update --init --recursive"; exit 1; }
	nix develop $(NIX_DIR) --command bash -c 'cd "$(CURDIR)" && exec bash --rcfile <(cat "$${HOME}/.bashrc"; printf "%s\n" '\''PS1="\[\\033[01;35m\][nix-shell]\[\\033[00m\] \[\\033[01;32m\]$${USER}@\\h\[\\033[00m\]:\[\\033[01;34m\]\\w\[\\033[00m\]> "'\'') -i'
