# OWAS eFPGA Subsystem — Filelist Directory (`FILE_LISTS/`)

To keep the root directory clean, **only top-level runnable entry points** sit at the top of each flow folder. Modular building-block fragments (included via `-f` by parent lists) are tucked inside `internal/`.

---

## The 5 Primary Filelists (3 Flows + 2 Tier-1 Containers)

| Flow / Target | Filelist Path | Description |
| :--- | :--- | :--- |
| **1. Simulation Flow** | `FILE_LISTS/efpga_subsystem.f` | Behavioral simulation (`target_config_pkg.sv`, behavioral `cg_cell.sv` & `sram_bank.sv`, full `OWAS_Fabric` tiles & fabric). |
| **2. Vivado Emulation Flow** | `FILE_LISTS/vivado/efpga_subsystem_vivado.f` | Xilinx FPGA emulation (`VIVADO/target_config_pkg.sv` with `TARGET_USE_LADDER_CLOCKS = 0`, `BUFGCE` clock gate, inferred BRAM). |
| **3. Tier-2 ASIC Macro Flow** | `FILE_LISTS/asic/efpga_subsystem_asic.f` | Full `efpga_subsystem_top` ASIC synthesis (`sg13cmos5l_lgcp_1` clock gate, `eFPGA` tile-grid blackbox + soft `eFPGA_top` config shell, Tier-1 container blackboxes). |
| **4. Tier-1 Act Bank Macro** | `FILE_LISTS/asic/act_bank_container_asic.f` | Standalone `act_bank_container` ASIC macro (`RM_IHPSG13_1P_512x8_c3_bm_bist`). |
| **5. Tier-1 Psum + Requant Macro** | `FILE_LISTS/asic/psum_requant_container_asic.f` | Standalone `psum_requant_container` ASIC macro (`RM_IHPSG13_1P_256x32_c2_bm_bist` + `npu_requantizer_lane`). |

### Additional Standalone / Unit Test Filelists:
* **Standalone NPU Complex (Simulation)**: `FILE_LISTS/npu.f`
* **Regression & Benchmark Testbenches**: `FILE_LISTS/tb/tb_*.f`

---

## Directory Layout

```text
FILE_LISTS/
├── README.md                              # This quick-reference guide
├── efpga_subsystem.f                      # Flow 1: Simulation
├── npu.f                                  # Standalone NPU Complex (Simulation)
├── vivado/
│   ├── efpga_subsystem_vivado.f           # Flow 2: Vivado Emulation
│   └── internal/
│       └── npu_vivado.f
├── asic/
│   ├── efpga_subsystem_asic.f             # Flow 3: Tier-2 ASIC Macro (efpga_subsystem_top)
│   ├── act_bank_container_asic.f          # Flow 4: Tier-1 Activation Bank Container Macro
│   ├── psum_requant_container_asic.f      # Flow 5: Tier-1 Psum + Requantizer Container Macro
│   └── internal/
│       ├── fabulous_asic.f
│       └── npu_asic.f
├── tb/                                    # Regression & benchmark testbench filelists
├── libs/                                  # AXI register slice library filelist (axi_lib.f)
└── internal/                              # Modular sub-block fragments included via -f
```
