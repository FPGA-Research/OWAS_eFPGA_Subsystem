# Backend Flow Integration Notes

This document summarizes the unified backend architecture across `OWAS_Fabric` and `OWAS_eFPGA_Subsystem`.

---

## 1. `OWAS_Fabric` Commit Structure & Contents

1. **Commit 1 (`a2c0de1`, `NeverInControl`)**:
   - Baseline `CrocoScale_Fabric` (`d8c6e5c`), including the updated `Tile/FLUT51PSDM/` (`tiles/b64x16_a48x16/` and X-propagation simulation fix in `common/FLUT51PSDM_architecture.v`) and the `FABulous` submodule linked to branch **`MLFPGA`** (`3340d7e`).
2. **Commit 2 (`267add0`, `Asma-Mohsin`)**:
   - Complete fabric and physical implementation state from `FABulous-OWAS@MLFPGA` (`3340d7e`):
     - Updated tile `.csv` pin orders, `fabric.csv`, and `eFPGA_geometry.csv`
     - Corner termination tiles (`N_term_IO_W`, `N_term_NPU_SLICE`, `S_term_IO_W`, `S_term_NPU_SLICE`)
     - Regenerated `.FABulous/` bitstream specification (`bitStreamSpec.bin`, `bitStreamSpec.csv`, `pips.txt`)
     - Regenerated tile and fabric Verilog (`Tile/**/*.v`, `Fabric/eFPGA.v`)
     - All `gds_config.yaml`, `*_io_pin_order.yaml`, `*_BEL.json`, and hardened `macro/final_views/**` (`Fabric/macro/final_views/` and `Tile/*/macro/final_views/`).
3. **Commit 3 (`2cef9b3`, `NeverInControl`)**:
   - Updated `Tile/FLUT51PSDM/gds_config.yaml` (`VERILOG_FILES`) to point to `dir::../../tiles/b64x16_a48x16/FLUT51PSDM*.v` and updated `.gitignore`.

---

## 2. `OWAS_eFPGA_Subsystem` Macro & LibreLane Structure

- **Hardened Physical Views (`MACROS/<macro>/views/`)**:
  - `MACROS/act_bank_container/views/`
  - `MACROS/psum_requant_container/views/`
  - `MACROS/efpga_subsystem_top/views/`
- **LibreLane Flow Configs & Makefiles (`librelane/`)**:
  - `librelane/Makefile`
  - `librelane/act_bank_container/{config.yaml,constraint.sdc,pdn_cfg.tcl,pin_order.cfg,Makefile}`
  - `librelane/psum_requant_container/{config.yaml,constraint.sdc,pdn_cfg.tcl,pin_order.cfg,Makefile}`
  - `librelane/efpga_subsystem_top/{config.yaml,pdn_cfg.tcl,pin_order.cfg,Makefile}`
- **Re-running Hardening in `librelane/`**:
  - Notice that `MACROS/efpga_subsystem_top/views/` in `vendor/MLFPGA_engine` was generated against commit `5140025` of `OWAS_fabric` (prior to the Oct 30–31 `3340d7e` fabric PDN/corner-tile updates). To re-harden `efpga_subsystem_top` against the latest `OWAS_Fabric` (`2cef9b3`) macro views:
    ```bash
    make -C librelane efpga_subsystem_top
    make -C librelane zip
    ```
