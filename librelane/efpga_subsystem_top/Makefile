# The top also needs the AXI register library, which the design filelists leave out
FILELIST = $(REPO_ROOT)/FILE_LISTS/asic/efpga_subsystem_asic.f $(REPO_ROOT)/FILE_LISTS/libs/axi_lib.f

include ../common.mk

# eFPGA LEF with open TopMetal1 bands, regenerated when the fabric views change
FABRIC_VIEWS = $(REPO_ROOT)/OWAS_Fabric/Fabric/macro/final_views
TM1_LEF_SCRIPT = $(REPO_ROOT)/scripts/efpga_tm1_obs_lef.py
TM1_LEF = $(LL_DIR)/eFPGA_interface/eFPGA_tm1bands.lef

$(TM1_LEF): $(FABRIC_VIEWS)/lef/eFPGA.lef $(FABRIC_VIEWS)/gds/eFPGA.gds $(TM1_LEF_SCRIPT)
	python3 $(TM1_LEF_SCRIPT) --lef $(word 1,$^) --gds $(word 2,$^) --out $@

.PHONY: tm1-lef
tm1-lef: $(TM1_LEF)

librelane librelane-explore librelane-nodrc librelane-magicdrc librelane-klayoutdrc: $(TM1_LEF)

.PHONY: zip zip-final
zip: zip-final

zip-final:
	test -d "$(VIEWS_DIR)"
	find "$(VIEWS_DIR)" -type f \( \
		-name "*.gds" -o \
		-name "*.def" -o \
		-name "*.mag" -o \
		-name "*.odb" -o \
		-name "*.sdf" -o \
		-name "*.spef" \
	\) -exec sh -c '\
		set -eu; \
		for file do \
			dir=$${file%/*}; \
			base=$${file##*/}; \
			archive=$${base}.zip; \
			tmp=$${archive}.tmp; \
			rm -f "$$dir/$$tmp"; \
			(cd "$$dir" && zip -D -q "$$tmp" "$$base"); \
			unzip -tq "$$dir/$$tmp"; \
			mv -f "$$dir/$$tmp" "$$dir/$$archive"; \
			rm -- "$$file"; \
			printf "Archived and replaced %s with %s/%s\\n" "$$file" "$$dir" "$$archive"; \
		done' sh {} +
