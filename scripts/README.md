# OWAS eFPGA Subsystem — Automation Scripts Guide (`scripts/`)

All build automation, code generation, formal verification, and bitstream compilation tools live in `scripts/`. Every Python and shell script supports `-h` / `--help` directly from the terminal.

---

## Quick Cheat-Sheet

| Goal | Command to Run (in WSL) |
| :--- | :--- |
| **Regenerate `VERILOG_MIRROR_GENERATED/`** (with Yosys SAT proofs & Icarus lints) | `source ~/custom_functions/custom_functions.sh && pyenv Yosys && ./scripts/generate_verilog_mirror.sh` |
| **Fast regenerate `VERILOG_MIRROR_GENERATED/`** (~2s, skips SAT proofs) | `./scripts/generate_verilog_mirror.sh -e none` |
| **Install/update bitstream tools in `tools/` & compile `flex` bitstream** | `python3 scripts/generate_bitstream.py --install-tools`<br>`python3 scripts/generate_bitstream.py` |
| **Run full-fabric bitstream simulation in Vivado `xsim`** | `python3 scripts/run_fabric_sim.py --quick` *(or omit `--quick` for full 5-layer suite)* |
| **Sync `MACROS/FABulous/eFPGA.v` blackbox after FABulous regen** | `python3 scripts/generate_blackbox_stub.py` |
| **Flatten a nested `.f` filelist into a single file** | `python3 scripts/flatten_filelists.py -f FILE_LISTS/efpga_subsystem.f -o <flat_out.f>` |
| **Strip Windows CRLF line endings from all `.f` files** | `python3 scripts/clean_filelists_crlf.py` |

---

## Scripts Reference

### 1. `generate_verilog_mirror.sh` — Verilog-2001 Mirror & Formal LEC Runner

Transpiles SystemVerilog sources (`RTL/`, `MACROS/`, `VIVADO/`, `SOFT_LOGIC/`, `TEST/`) into `VERILOG_MIRROR_GENERATED/` (excluding hardened physical macro views under `MACROS/*/views/`), symlinks `OWAS_Fabric`, and runs formal SAT equivalence checking plus post-generation Icarus Verilog lint checks across Simulation, ASIC, Macro, Soft-Logic, and Testbench filelists.

```bash
./scripts/generate_verilog_mirror.sh --help
```

| Flag | Description |
| :--- | :--- |
| `-e`, `--equiv <mode>` | `leaf` *(default)*: Yosys formal SAT proofs on leaf modules + structural audit fallback.<br>`none`: Fast transpilation only (skips formal verification and lints).<br>`full`: Full hierarchical formal equivalence checking. |
| `-d`, `--dir <path>` | Scope transpilation and verification to a single subdirectory (e.g. `-d SOFT_LOGIC/flex`). |
| `-h`, `--help` | Show help message and examples. |

---

### 2. `generate_bitstream.py` — Soft-Logic Bitstream Compiler

Maps, packs, routes, and generates bitstreams (`SOFT_LOGIC/build/<design>/<design>.bin` and `.hex`) for soft-logic controllers targeting the 9x16 `OWAS_Fabric` eFPGA fabric. Never downloads external tools unless `--install-tools` is explicitly passed.

```bash
python3 scripts/generate_bitstream.py --help
python3 scripts/generate_bitstream.py --install-tools
python3 scripts/generate_bitstream.py
```

---

### 3. `run_fabric_sim.py` — Full-Fabric Bitstream Simulation Runner

Compiles and runs a system testbench (`FILE_LISTS/tb/<tb>_fabric.f`) on the real `eFPGA_top` fabric in Vivado `xsim`, preloading `SOFT_LOGIC/build/flex/flex.hex` via `efpga_manager`. Supports `-q` / `--quick` for single-tile smoke verification (2,048 golden outputs in minutes instead of hours).

```bash
python3 scripts/run_fabric_sim.py --help
python3 scripts/run_fabric_sim.py --quick
python3 scripts/run_fabric_sim.py --tb tb_npu_flex_crossbar_stress
```

---

### 4. `generate_blackbox_stub.py` — Hard Macro Blackbox Stub Generator

Parses a structural/RTL Verilog or SystemVerilog module header and generates a synthesis/lint-ready `(* blackbox *)` Verilog stub with all parameters, ports, and deterministic output tie-offs.

```bash
python3 scripts/generate_blackbox_stub.py --help

# Default: updates MACROS/FABulous/eFPGA.v from OWAS_Fabric/Fabric/eFPGA.v
python3 scripts/generate_blackbox_stub.py

# Custom module:
python3 scripts/generate_blackbox_stub.py -i <src.v> -o <dst_blackbox.v>
```

---

### 5. `vivado_reimport_sources.tcl` & `disable_drc.tcl` — Vivado Project Setup & DRC Hook

Reimports `FILE_LISTS/vivado/efpga_subsystem_vivado.f` and `FILE_LISTS/libs/axi_lib.f` into Vivado `sources_1`, adds simulation testbenches to `sim_1`, configures Out-Of-Context (OOC) synthesis on the 11 active fabric tiles, and attaches `disable_drc.tcl` to prevent placer combinatorial loop stack overflows.

---

### 6. `flatten_filelists.py` — Recursive Filelist Flattener

Resolves nested `-f` / `-c` directives into a single deduplicated flat filelist.

```bash
python3 scripts/flatten_filelists.py --help
python3 scripts/flatten_filelists.py -f FILE_LISTS/efpga_subsystem.f -o FILE_LISTS/efpga_subsystem_global.f
```

---

### 7. `rebase_filelist.py` — Filelist Path Prefix Rebaser

Rebases path prefixes inside a `.f` filelist without touching the underlying hardware files.

```bash
python3 scripts/rebase_filelist.py --help
python3 scripts/rebase_filelist.py <filelist.f> <rebase_prefix> [output_file.f]
```

---

### 8. `clean_filelists_crlf.py` — Filelist Line-Ending Sanitizer

Converts Windows CRLF (`\r\n`) to Unix LF (`\n`) across `.f` and `.flist` files.

```bash
python3 scripts/clean_filelists_crlf.py --help
python3 scripts/clean_filelists_crlf.py
```

