# The top also needs the AXI register library, which the design filelists leave out
FILELIST = $(REPO_ROOT)/FILE_LISTS/asic/efpga_subsystem_asic.f $(REPO_ROOT)/FILE_LISTS/libs/axi_lib.f

include ../common.mk

.PHONY: zip zip-final
zip: zip-final

zip-final:
	test -d "$(VIEWS_DIR)"
	find "$(VIEWS_DIR)" -type f \( \
		-name "*.gds" -o \
		-name "*.def" -o \
		-name "*.mag" -o \
		-name "*.odb" -o \
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
