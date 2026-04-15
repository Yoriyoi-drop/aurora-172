# AURORA-172 FPGA Prototyping Guide

> **Panduan lengkap untuk prototyping AURORA-172 di FPGA**

Dokumen ini menjelaskan cara melakukan prototyping arsitektur AURORA-172 di FPGA menggunakan Xilinx Versal atau Intel Agilex.

---

## 📋 Daftar Isi

1. [Overview](#overview)
2. [Target FPGA](#target-fpga)
3. [Struktur File FPGA](#struktur-file-fpga)
4. [Build untuk Xilinx Versal](#build-untuk-xilinx-versal)
5. [Build untuk Intel Agilex](#build-untuk-intel-agilex)
6. [Clock Domain Crossing](#clock-domain-crossing)
7. [Timing Constraints](#timing-constraints)
8. [Resource Utilization](#resource-utilization)
9. [Debug Infrastructure](#debug-infrastructure)
10. [Troubleshooting](#troubleshooting)

---

## 🎯 Overview

Phase 3 dari proyek AURORA-172 fokus pada **prototyping FPGA** untuk memvalidasi desain RTL sebelum tape-out ASIC. FPGA prototyping memungkinkan:

- ✅ Validasi fungsional di hardware nyata
- ✅ Benchmarking performa real
- ✅ Debugging dengan ILA (Integrated Logic Analyzer)
- ✅ Verifikasi timing constraints
- ✅ Identifikasi issues sebelum ASIC flow

### Arsitektur Clock Domain

AURORA-172 memiliki **5 clock domain berbeda** yang memerlukan CDC yang aman:

```
┌─────────────────────────────────────────────────────────┐
│              AURORA-172 Clock Domains                    │
├──────────────┬──────────┬───────────────────────────────┤
│ Domain       │ Freq     │ Cores                         │
├──────────────┼──────────┼───────────────────────────────┤
│ G-Core       │ 500 MHz  │ 16x Gaming Cores              │
│ H-Core       │ 250 MHz  │ 32x Hybrid Cores              │
│ A-Core       │ 125 MHz  │ 64x AI/Tensor Cores           │
│ Mem Fabric   │ 333 MHz  │ Memory Controller (172-bit)   │
│ Interconnect │ 250 MHz  │ Aurora Fabric Mesh            │
│ Debug        │ 50 MHz   │ ILA/Trace                     │
└──────────────┴──────────┴───────────────────────────────┘
```

---

## 🎛️ Target FPGA

### Xilinx Versal ACAP (Recommended)

| Parameter | Value |
|-----------|-------|
| **Part** | XCVE1802-2MPCCVC1760 |
| **LUTs** | ~2,000,000 |
| **FFs** | ~4,000,000 |
| **DSPs** | 3,600 |
| **BRAM** | 2,016 (36Kb each) |
| **HBM** | Up to 64GB (HBM variant) |
| **PCIe** | Gen5 x16 |

### Intel Agilex 7 (Alternative)

| Parameter | Value |
|-----------|-------|
| **Part** | AGIB027F29E1V |
| **LEs** | ~2,200,000 |
| **FFs** | ~2,600,000 |
| **DSPs** | 5,760 |
| **M20K** | 4,424 |
| **HBM2E** | Up to 32GB |
| **PCIe** | Gen5 x16 |

---

## 📁 Struktur File FPGA

```
fpga/
├── aurora_172_versal.xdc          # Xilinx Versal constraints (SDC)
├── aurora_172_agilex.sdc          # Intel Agilex constraints (SDC)
├── fpga_clock_distribution.sv     # Clock generation & distribution
├── fpga_io_wrapper.sv             # I/O wrapper untuk FPGA pins
├── cdc_lib.sv                     # Clock Domain Crossing library
├── aurora_172_fpga_top.sv         # FPGA top-level wrapper
├── build_vivado.tcl               # Vivado build script
├── README.md                      # This file
└── ip/                            # Generated IP cores (auto-generated)
    ├── clk_wizard.xci
    ├── mig_7series.xci
    └── pcie_dma.xci
```

---

## 🔨 Build untuk Xilinx Versal

### Prerequisites

```bash
# Install Xilinx Vivado 2024.1+
# Set environment variables
source /opt/Xilinx/Vivado/2024.1/settings64.sh
```

### Build Command

```bash
# GUI mode (untuk debugging)
vivado -source fpga/build_vivado.tcl

# Batch mode (untuk CI/CD)
vivado -mode batch -source fpga/build_vivado.tcl -nolog -nojournal

# Atau gunakan Makefile
make fpga_compile
make fpga_bitstream
```

### Build Output

```
build/fpga/
├── aurora_172.bit                 # FPGA bitstream
├── aurora_172.ltx                 # ILA debug probes
├── reports/
│   ├── timing_synth.rpt           # Timing report (synthesis)
│   ├── utilization_synth.rpt      # Resource usage (synthesis)
│   ├── power_synth.rpt            # Power estimation (synthesis)
│   ├── timing_impl.rpt            # Timing report (implementation)
│   ├── utilization_impl.rpt       # Resource usage (implementation)
│   ├── power_impl.rpt             # Power estimation (implementation)
│   ├── drc_impl.rpt               # Design Rule Check
│   └── cdc.rpt                    # Clock Domain Crossing analysis
└── aurora_172.runs/
    ├── synth_1/                   # Synthesis run directory
    └── impl_1/                    # Implementation run directory
```

### Load Bitstream

```bash
# Menggunakan Vivado Hardware Manager
vivado
# File > Open Hardware Manager > Open Target > Auto Connect
# Program Device > aurora_172.bit

# Atau menggunakan command line
program_hw_targets -hw_target [get_hw_targets]
current_hw_device [get_hw_devices xcve1802_*]
set_property PROGRAM.FILE aurora_172.bit [current_hw_device]
program_hw_devices [current_hw_device]
```

---

## 🔨 Build untuk Intel Agilex

### Prerequisites

```bash
# Install Intel Quartus Prime Pro 24.1+
source /opt/intel/quartus/init/quartus_init.sh
```

### Build Command

```bash
# GUI mode
quartus --64bit fpga/aurora_172_agilex.qpf

# Command line
quartus_sh --flow compile fpga/aurora_172_agilex.qpf

# Atau menggunakan Makefile
make fpga_compile_intel
```

---

## 🔀 Clock Domain Crossing

### CDC Library Modules

File `cdc_lib.sv` menyediakan beberapa modul CDC:

#### 1. **cdc_synchronizer** - 2-Flop Synchronizer

Untuk sinyal single-bit antar domain clock:

```systemverilog
cdc_synchronizer #(
    .RESET_VALUE(1'b0)
) sync_signal (
    .src_clk    (clk_source),
    .dst_clk    (clk_dest),
    .src_rst_n  (rst_n),
    .dst_rst_n  (rst_n),
    .src_data   (data_in),
    .dst_data   (data_out)
);
```

#### 2. **cdc_pulse_synchronizer** - Pulse Synchronizer

Untuk pulse satu-siklus (handshake):

```systemverilog
cdc_pulse_synchronizer sync_pulse (
    .src_clk    (clk_source),
    .dst_clk    (clk_dest),
    .src_rst_n  (rst_n),
    .dst_rst_n  (rst_n),
    .src_pulse  (pulse_in),
    .dst_pulse  (pulse_out),
    .dst_busy   ()
);
```

#### 3. **cdc_fifo** - Async FIFO

Untuk multi-bit data (recommended untuk bus >4 bit):

```systemverilog
cdc_fifo #(
    .DATA_WIDTH(64),
    .ADDR_WIDTH(4)  // 16-entry FIFO
) cdc_data (
    .wr_clk     (clk_write),
    .wr_rst_n   (rst_n),
    .wr_data    (data_in),
    .wr_en      (write_en),
    .wr_full    (full_flag),
    .rd_clk     (clk_read),
    .rd_rst_n   (rst_n),
    .rd_data    (data_out),
    .rd_valid   (valid_flag),
    .rd_en      (read_en)
);
```

#### 4. **cdc_handshake** - Handshake Synchronizer

Untuk transfer data terkontrol dengan ready/valid:

```systemverilog
cdc_handshake #(
    .DATA_WIDTH(128)
) cdc_cmd (
    .src_clk    (clk_source),
    .src_rst_n  (rst_n),
    .src_data   (cmd_data),
    .src_valid  (cmd_valid),
    .src_ready  (cmd_ready),
    .dst_clk    (clk_dest),
    .dst_rst_n  (rst_n),
    .dst_data   (cmd_out),
    .dst_valid  (valid_out),
    .dst_ready  (ready_in)
);
```

### CDC Best Practices

✅ **DO:**
- Gunakan `cdc_synchronizer` untuk single-bit control signals
- Gunakan `cdc_fifo` atau `cdc_handshake` untuk multi-bit data
- Selalu synchronize reset ke setiap clock domain
- Gunakan Gray code untuk FIFO pointers
- Tambahkan `ASYNC_REG = "TRUE"` attribute

❌ **DON'T:**
- Jangan langsung connect signal antar clock domain
- Jangan gunakan CDC untuk bus >8 bit tanpa FIFO
- Jangan skip reset synchronization
- Jangan rely pada timing analysis saja - verify di hardware

---

## ⏱️ Timing Constraints

### Clock Definitions

File constraints mendefinisikan semua clock domain:

```tcl
# Primary clock
create_clock -period 2.000 -name sys_clk [get_ports sys_clk_p]

# Generated clocks (dari PLL)
create_generated_clock -name g_core_clk \
    -source [get_ports sys_clk_p] \
    -divide_by 1 \
    [get_pins pll_0/outclk[0]]
```

### Clock Groups (CDC)

```tcl
# Mark clock domains as asynchronous
set_clock_groups -asynchronous \
    -group [get_clocks g_core_clk] \
    -group [get_clocks h_core_clk] \
    -group [get_clocks ai_core_clk]
```

### Multicycle Paths

```tcl
# DMA engine - 4 cycle latency OK
set_multicycle_path -setup 4 \
    -from [get_cells *dma_engine*/control*] \
    -to [get_cells *dma_engine*/status*]
```

### False Paths

```tcl
# Reset paths (not timing critical)
set_false_path -from [get_ports rst_n]

# Debug signals
set_false_path -from [get_cells *debug_ctrl*]
```

---

## 📊 Resource Utilization

### Estimasi (Xilinx Versal VP1802)

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| **LUT** | ~850,000 | 2,000,000 | 42.5% |
| **FF** | ~1,200,000 | 4,000,000 | 30.0% |
| **DSP** | ~2,800 | 3,600 | 77.8% |
| **BRAM** | ~1,400 | 2,016 | 69.4% |
| **URAM** | ~256 | 4,032 | 6.4% |

### Breakdown per Module

| Module | LUT | FF | DSP | BRAM |
|--------|-----|----|-----|------|
| G-Core (16x) | 240K | 320K | 512 | 256 |
| H-Core (32x) | 180K | 280K | 256 | 384 |
| A-Core (64x) | 280K | 420K | 1,800 | 512 |
| NPU (8x) | 80K | 100K | 200 | 128 |
| Mem Fabric | 40K | 50K | 16 | 64 |
| Interconnect | 20K | 25K | 8 | 32 |
| CDC/Debug | 10K | 5K | 8 | 24 |

---

## 🐛 Debug Infrastructure

### ILA (Integrated Logic Analyzer)

ILA probes ditandai dengan `MARK_DEBUG` attribute di XDC file:

```tcl
set_property MARK_DEBUG true [get_nets {g_core[0]/pc_reg[*]}]
set_property MARK_DEBUG true [get_nets {memory_fabric/mem_req_valid}]
```

### Trigger Setup

Recommended triggers untuk debugging:

1. **g_core_clk domain**: PC, ALU result, branch prediction
2. **mem_fabric_clk domain**: Memory requests/responses
3. **interconnect_clk domain**: Mesh packets

### VIO (Virtual I/O)

Virtual I/O untuk runtime control:

```tcl
# DVFS frequency selection
set_property MARK_DEBUG true [get_nets {dvfs_freq_sel[*]}]

# Power gating control
set_property MARK_DEBUG true [get_nets {power_gate_en[*]}]
```

---

## 🔧 Troubleshooting

### Synthesis Errors

**Error: `[Timing 38-282] The design failed to meet the timing requirements`**

**Solution:**
- Periksa critical paths di timing report
- Tambahkan pipeline stages
- Kurangi clock frequency
- Enable physical synthesis optimization

**Error: `[DRC 23-20] Rule violation (CDC-1) Clock Domain Crossing`**

**Solution:**
- Pastikan semua cross-domain signals menggunakan CDC library
- Check CDC report untuk unidentified paths
- Tambahkan synchronizer registers

### Implementation Errors

**Error: `[Place 30-574] Unable to perform placement`**

**Solution:**
- Kurangi core count (prototype dengan 4 G-Cores dulu)
- Increase SLR area assignments
- Enable logic lock regions

### Runtime Issues

**Issue: Metastability di CDC**

**Solution:**
- Verify synchronizer chain length (minimum 2 flops)
- Check MTBF calculation
- Tambahkan `ASYNC_REG` attribute

**Issue: Clock not locked**

**Solution:**
- Verify PLL/MMCM configuration
- Check input clock frequency
- Verify reset sequence

---

## 📝 Next Steps

Setelah FPGA prototyping berhasil:

1. ✅ Run benchmark workloads (gaming + AI)
2. ✅ Compare hasil dengan simulasi Verilator
3. ✅ Validate timing constraints
4. ✅ Fix any issues ditemukan
5. ➡️ Lanjut ke Phase 4: Advanced Optimization
6. ➡️ Lanjut ke Phase 5: ASIC Flow

---

## 📚 References

- [Xilinx Versal ACAP Architecture UG1000](https://docs.xilinx.com/u/versal-acap)
- [Vivado Design Suite User Guide UG895](https://docs.xilinx.com/u/ug895)
- [CDC Design Techniques Xilinx XAPP1028](https://docs.xilinx.com/u/xapp1028)
- [Intel Agilex 7 Data Sheet](https://www.intel.com/content/www/us/en/products/details/fpga/agilex-7.html)

---

**Last Updated**: 10 April 2026  
**Version**: Phase 3 - FPGA Prototyping
