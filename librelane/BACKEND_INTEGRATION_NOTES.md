# Backend Flow Integration Notes & Pending Re-Run Checklist

This document records what was transplanted from `vendor/MLFPGA_engine` (`Asma-Mohsin/OWAS_fabric` and `FABulous-OWAS@MLFPGA`) into the unified `OWAS_Fabric` and `OWAS_eFPGA_Subsystem` repositories, what was **intentionally excluded** to protect RTL Simulation, Vivado Emulation, and bitstream compatibility, and what needs to be re-run in the backend flow.

---

## 1. What Was Transplanted

### In `OWAS_Fabric`
- **Hardened Physical Views (`macro/final_views/`)**:
  - Top-level stitched fabric macro views: `Fabric/macro/final_views/{gds,lef,nl,pnl,def,odb,sdc,spice,mag,mag_gds,klayout_gds,json_h,vh,metrics.*}`
  - All 15 tile macro views: `Tile/<TileName>/macro/final_views/{gds,lef,nl,pnl,def,odb,sdc,spef,spice,mag,mag_gds,klayout_gds,json_h,vh,metrics.*}`
- **LibreLane / FABulous Physical Configuration Files**:
  - `Fabric/gds_config.yaml` (top-level halo spacing and PDN configuration)
  - `Tile/include/gds_config.yaml` (shared `ihp-sg13cmos5l` synthesis, placement, and routing settings)
  - `Tile/<TileName>/gds_config.yaml` (updated `DIE_AREA` bounding boxes for all tiles)
  - `Tile/<TileName>/<TileName>_io_pin_order.yaml` (per-tile physical pin placement configurations)

### In `OWAS_eFPGA_Subsystem`
- **Hardened Physical Views (`MACROS/<macro>/views/`)**:
  - `MACROS/act_bank_container/views/`
  - `MACROS/psum_requant_container/views/`
  - `MACROS/efpga_subsystem_top/views/`
- **LibreLane Flow Configs & Makefiles (`librelane/`)**:
  - `librelane/Makefile`
  - `librelane/act_bank_container/{config.yaml,constraint.sdc,pdn_cfg.tcl,pin_order.cfg,Makefile}`
  - `librelane/psum_requant_container/{config.yaml,constraint.sdc,pdn_cfg.tcl,pin_order.cfg,Makefile}`
  - `librelane/efpga_subsystem_top/{config.yaml,pdn_cfg.tcl,pin_order.cfg,Makefile}`
  - All `VERILOG_FILES` in `config.yaml` now reference the single-source-of-truth RTL in `RTL/`, `MACROS/`, and `OWAS_Fabric/` instead of duplicated files under `ip/`.

---

## 2. What Was Intentionally Excluded (and Why)

### A. `Tile/FLUT51PSDM/` RTL Files (`FLUT51PSDM_architecture.v` & Duplicate `.v` Files)
- **Files Excluded**:
  - `Tile/FLUT51PSDM/common/FLUT51PSDM_architecture.v`
  - `Tile/FLUT51PSDM/FLUT51PSDM.v`
  - `Tile/FLUT51PSDM/FLUT51PSDM_ConfigMem.v`
  - `Tile/FLUT51PSDM/FLUT51PSDM_switch_matrix.v`
- **Reason**:
  - `Asma-Mohsin/OWAS_fabric` was branched prior to commit `d8c6e5c` (*"fix: update FLUT51PSDM to fix x-prop simulation issue"*). Her copy of `FLUT51PSDM_architecture.v` uses raw dynamic array indexing (`assign q0 = row0[addr01];`) instead of the X-tolerant `mux8()` function tree, which causes fatal X-propagation across the LUT in RTL simulation whenever unused LUT inputs are `X`.
  - Additionally, the canonical `FLUT51PSDM` tile wrapper, switch matrix, and config memory live in `Tile/FLUT51PSDM/tiles/b64x16_a48x16/`.
- **Resolution Applied**:
  - Kept the golden `Tile/FLUT51PSDM/` RTL untouched and updated `Tile/FLUT51PSDM/gds_config.yaml` (`VERILOG_FILES`) to point directly to `dir::../../tiles/b64x16_a48x16/FLUT51PSDM*.v`.

### B. Tile `.csv` Wire-Order Modifications & Regenerated Tile/Switch-Matrix `.v` Files (Commit `4a842df`)
- **Files Excluded**:
  1. `Tile/AXIL_S_IO_W/AXIL_S_IO_W_0..5/AXIL_S_IO_W_0..5.csv`, `AXIL_S_IO_W_0..5_switch_matrix.v`, `AXIL_S_IO_W_0..5.v`, and `Tile/AXIL_S_IO_W/AXIL_S_IO_W.v`
  2. `Tile/AXI_M_IO_W/AXI_M_IO_W_0..9/AXI_M_IO_W_0..9.csv`
  3. `Tile/EXT_PMOD/EXT_PMOD_0..1/EXT_PMOD_0..1.{csv,v}` and `Tile/EXT_PMOD/EXT_PMOD.v`
  4. `Tile/NPU_ACCUM_N/NPU_ACCUM_N_0..3/NPU_ACCUM_N_0..3.{csv,v}` and `Tile/NPU_ACCUM_N/NPU_ACCUM_N.v`
  5. `Tile/NPU_ACCUM_S/NPU_ACCUM_S_0..3/NPU_ACCUM_S_0..3.{csv,v}` and `Tile/NPU_ACCUM_S/NPU_ACCUM_S.v`
  6. `Tile/NPU_CTRL_CFG/NPU_CTRL_CFG_0..1/NPU_CTRL_CFG_0..1.{csv,v}` and `Tile/NPU_CTRL_CFG/NPU_CTRL_CFG.v`
  7. `Tile/NPU_SLICE/NPU_SLICE_0..3/NPU_SLICE_0..3.{csv,v}` and `Tile/NPU_SLICE/NPU_SLICE.v`
  8. `Tile/SOC_DEBUG_IO/SOC_DEBUG_IO.csv`
- **Reason**:
  - **Bitstream Desynchronization in `AXIL_S_IO_W`**: In commit `4a842df` (*"redid tiles with updated pin order"*), the `source_dest` direction columns in `AXIL_S_IO_W_0..5.csv` were reordered from `WEST, SOUTH, EAST` to `EAST, SOUTH, WEST` and the switch matrices were regenerated, but `.FABulous/bitStreamSpec.bin` and `.FABulous/bitStreamSpec.csv` were **not** regenerated. Because FABulous assigns `ConfigBits[k]` indices in the order output ports appear in the CSV, 28 switch-matrix multiplexers per `AXIL_S_IO_W` subtile (`S1BEG*`, `S2BEG*`, `S2BEGb*`, `S4BEG*`, `E1BEG*`, `E2BEG*`, `E2BEGb*`) received different `ConfigBits` indices than what `.FABulous/bitStreamSpec.bin` encodes.
  - **Unregenerated `AXI_M_IO_W` CSVs**: `AXI_M_IO_W_0..9.csv` had `WEST` and `EAST` swapped in `a78cf27`, while `AXI_M_IO_W_0..9_switch_matrix.v` was left unregenerated.
  - **Carry-Chain (`Ci`/`Co`) Column Order Mismatch**: In `EXT_PMOD`, `NPU_ACCUM_N`, `NPU_ACCUM_S`, `NPU_CTRL_CFG`, `NPU_SLICE`, and `SOC_DEBUG_IO`, the `NORTH/SOUTH` `Ci`/`Co` lines were moved after the `SOUTH` routing wires, whereas the adjacent `FLUT51PSDM` tile defines `Co`/`Ci` immediately after `NORTH`.
- **Consequence**:
  - The currently committed `Tile/**/macro/final_views/` and `Fabric/macro/final_views/` (and consequently `MACROS/efpga_subsystem_top/views/`) were built from the `4a842df` tile netlists and therefore **must be regenerated** from the golden `OWAS_Fabric` RTL before final signoff or gate-level bitstream simulation.

### C. `FABulous-OWAS` Commit `6934d44` (`pdn obstructions` in `helper.py`)
- **File Excluded**:
  - `FABulous/fabulous/fabric_generator/gds_generator/helper.py` (commit `6934d44` on the `MLFPGA` branch of `FABulous-OWAS`)
- **Reason**:
  - Kept the `FABulous` submodule pointed at the clean `main` branch (`677ff6f`) of `FPGA-Research/FABulous-OWAS`.
  - For reference, commit `6934d44` added the following 11 lines at the end of `get_pdn_obstructions()` in `fabulous/fabric_generator/gds_generator/helper.py`:
    ```python
    OBS = [
        ["TopMetal1", 0, 0, float(die_width), 4.96],
        ["TopMetal1", 0, 74.6, float(die_width), 86.52],
        ["TopMetal1", 0, 150.2, float(die_width), 162.12],
        ["TopMetal1", 0, 225.8, float(die_width), float(die_height)],
        ["TopMetal1", 0, 0, 11.4, float(die_height)],
        ["TopMetal1", 80.2, 0, 99.0, float(die_height)],
        ["TopMetal1", 155.8, 0, 174.6, float(die_height)],
        ["TopMetal1", 231.4, 0, 250.2, float(die_height)],
    ]
    return OBS
    ```
  - Note: Those hardcoded coordinates were tailored to a single tile height (`~230 µm`) and would need to be parameterized if used across supertiles of varying heights.

---

## 3. Checklist for Re-Running the Full Hardening Flow

1. **Re-harden the FABulous Tiles and Stitched `eFPGA` Macro** in `OWAS_Fabric`:
   - Using the golden `.csv`, `.v`, and `.FABulous/bitStreamSpec.bin` in `OWAS_Fabric` (without altering CSV wire ordering; adjust only ` *_io_pin_order.yaml` or `gds_config.yaml` if pin placement adjustments are needed), re-run the FABulous tile and fabric LibreLane flows to update:
     - `Tile/<TileName>/macro/final_views/`
     - `Fabric/macro/final_views/`
2. **Re-harden the NPU Container Macros (if RTL or floorplan changes)** in `OWAS_eFPGA_Subsystem/librelane`:
   ```bash
   make -C librelane act_bank_container
   make -C librelane psum_requant_container
   ```
3. **Re-harden the Top-Level `efpga_subsystem_top` Macro** in `OWAS_eFPGA_Subsystem/librelane`:
   ```bash
   make -C librelane efpga_subsystem_top
   make -C librelane zip
   ```

