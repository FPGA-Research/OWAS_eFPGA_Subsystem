REPO_ROOT := $(abspath ../..)
PDK_ROOT ?= $(abspath $(REPO_ROOT)/../PDK)
PDK ?= ihp-sg13cmos5l
LL_DIR ?= $(abspath .)
NIX_DIR ?= $(abspath $(REPO_ROOT)/OWAS_Fabric/FABulous)
VIEWS_DIR ?= $(REPO_ROOT)/MACROS/act_bank_container/views
FILELIST ?= $(REPO_ROOT)/FILE_LISTS/asic/act_bank_container_asic.f

# VERILOG_FILES come from the filelist, passed to librelane before config.yaml
VERILOG_FILES_JSON := $(LL_DIR)/verilog_files.json
LL_CONFIGS := $(VERILOG_FILES_JSON) $(LL_DIR)/config.yaml

.PHONY: all
all: librelane

librelane: $(PDK_ROOT)/$(PDK) $(VERILOG_FILES_JSON)
	librelane $(LL_CONFIGS) --pdk $(PDK) --pdk-root $(PDK_ROOT) --manual-pdk --save-views-to $(VIEWS_DIR)/ 
.PHONY: librelane

librelane-explore: $(PDK_ROOT)/$(PDK) $(VERILOG_FILES_JSON)
	librelane $(LL_CONFIGS) --pdk $(PDK) --pdk-root $(PDK_ROOT) --manual-pdk --save-views-to $(VIEWS_DIR)/ --flow SynthesisExploration
.PHONY: librelane-explore

librelane-nodrc: $(PDK_ROOT)/$(PDK) $(VERILOG_FILES_JSON)
	librelane $(LL_CONFIGS) --pdk $(PDK) --pdk-root $(PDK_ROOT) --manual-pdk --save-views-to $(VIEWS_DIR)/ --skip KLayout.DRC --skip Magic.DRC --skip KLayout.Antenna --skip KLayout.Density
.PHONY: librelane-nodrc

librelane-magicdrc: $(PDK_ROOT)/$(PDK) $(VERILOG_FILES_JSON)
	librelane $(LL_CONFIGS) --pdk $(PDK) --pdk-root $(PDK_ROOT) --manual-pdk --save-views-to $(VIEWS_DIR)/ --skip KLayout.DRC
.PHONY: librelane-magicdrc

librelane-klayoutdrc: $(PDK_ROOT)/$(PDK) $(VERILOG_FILES_JSON)
	librelane $(LL_CONFIGS) --pdk $(PDK) --pdk-root $(PDK_ROOT) --manual-pdk --save-views-to $(VIEWS_DIR)/ --skip Magic.DRC
.PHONY: librelane-klayoutdrc

librelane-openroad: $(PDK_ROOT)/$(PDK) $(VERILOG_FILES_JSON)
	librelane $(LL_CONFIGS) --pdk $(PDK) --pdk-root $(PDK_ROOT) --manual-pdk --last-run --flow OpenInOpenROAD
.PHONY: librelane-openroad

librelane-klayout: $(PDK_ROOT)/$(PDK) $(VERILOG_FILES_JSON)
	librelane $(LL_CONFIGS) --pdk $(PDK) --pdk-root $(PDK_ROOT) --manual-pdk --last-run --flow OpenInKLayout
.PHONY: librelane-klayout

.PHONY: nix
nix:
	cd "$(NIX_DIR)" && nix-shell --run 'cd "$(CURDIR)" && exec bash --rcfile <(cat "$${HOME}/.bashrc"; printf "%s\n" '\''PS1="\[\\033[01;35m\][nix-shell]\[\\033[00m\] \[\\033[01;32m\]$${USER}@\\h\[\\033[00m\]:\[\\033[01;34m\]\\w\[\\033[00m\]> "'\'') -i'

# Always regenerated (absolute paths, cheap)
$(VERILOG_FILES_JSON): FORCE
	python3 $(REPO_ROOT)/scripts/filelist_to_librelane.py $(FILELIST) -o $@

.PHONY: FORCE
FORCE:
