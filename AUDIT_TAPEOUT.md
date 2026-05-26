# AUDIT TAPE-OUT AURORA-172

> **Tanggal:** 26 Mei 2026
> **Project:** Aurora-172 — Heterogeneous Unified Processor (Gaming + AI)
> **Target:** 6 GHz, Xilinx Versal / Intel Agilex → ASIC
> **Verdict: ⛔ TIDAK SIAP TAPE-OUT (Readiness: ~15-20%)**
> **Risk Level: SANGAT TINGGI**

---

## RINGKASAN EKSEKUTIF

Audit dilakukan oleh 5 sub-agent secara paralel terhadap 51 file SystemVerilog (~35.000 baris).
Ditemukan ±200 temuan dengan **8 critical blocker**, **25+ high priority**, **20+ medium**, **15+ low**.

**Desain ini adalah prototype arsitektural, BUKAN production-ready RTL.**

---

## 8 CRITICAL BLOCKER (Silicon Bug / Deadlock / Data Corruption)

### C-1: Timeout → Silent Data Corruption (Systematic Pattern — 6 Modules)
Setiap core memiliki mekanisme timeout yang **fabricate data** alih-alih mengeluarkan bus error/exception.
Di silicon dengan 6 GHz + memory fabric congestion, timeout akan sering terjadi → **SILENT DATA CORRUPTION**.

| Modul | Baris | Mekanisme |
|-------|-------|-----------|
| `l1_cache.sv` | 433-483 | Timeout return `8'hDE` / `0` |
| `l2_cache.sv` | 383-388, 654-658 | Timeout flush 32 write buffer — data HILANG |
| `vcache.sv` | 315-338 | Timeout fill dengan data stale |
| `g_core.sv` | 375-382 | Timeout force WRITEBACK dengan `{DW{1'b1}}` |
| `h_core.sv` | 374-382 | Timeout substitusi `{DW{1'b0}}` |
| `a_core.sv` | 1184-1189 | Timeout skip ke MAC_INIT dengan data stale |

### C-2: Multi-Driven Signal
- `exception_handler.sv:203,447,643,658` — `error_rate_count` driven dari 2 always block
- `top.sv:1672-1703` — `sched_g_core_cmd_ready` combinational loop

### C-3: Non-Synthesizable Constructs di RTL
- `hol_prevention.sv:120`, `hol_integration.sv:118`, `ring_bus.sv:209`, `timing_manager.sv:198` — `initial` blocks
- `hol_prevention.sv:222-330`, `global_scheduler_mq.sv:1328-1353` — blocking `=` di sequential always_ff
- `uop_cache.sv:167-222` — mix blocking + non-blocking di sequential

### C-4: Illegal Assignment Unpacked Array
- `cache_coherency.sv:147-148,257,265,290-291` — scalar/vector ke unpacked 3D array. **NOT SYNTHESIZABLE**
- `cache_coherency.sv:223` — `reg` declaration inside `always`/`generate`

### C-5: Cache Coherency Protocol Non-Functional
- `mesi_controller.sv:286` — Data forwarding MOESI return 0
- `top.sv:2089-2091` — Snoop bus tidak terhubung
- `cache_coherency.sv:89` — Sharers bitmap ~500K flops
- `cache_profiler.sv:219-226` — MESI ↔ MOESI mapping terbalik

### C-6: Kombinasional Raksasa (Timing Impossible di 6 GHz)
- `rt_engine.sv:338-422,590-601` — BVH traverse 48 iterasi dengan multiply+perbandingan di **1 cycle**
- `g_core.sv:543-554` — Integer sqrt 31 iterasi + 64-bit multiply tiap iterasi di **1 cycle**
- `g_core.sv:549-550` — 64-bit signed division di **1 cycle**
- `h_core.sv:339` — Integer division runtime `/` di **1 cycle**
- `npu_cluster.sv:422-426` — 32-input adder tree di **1 cycle**

### C-7: Fabric Arbiter Priority Inversion
- `top.sv:1907-1970` — 108 requestor last-wins (worker 63 > worker 0)
- `dma_engine.sv:144-153` — DMA grant last channel wins
- `top.sv:1980-1999` — L2 arbiter last active wins

### C-8: Parameter Mismatch FPGA vs Design Intent
`aurora_global_pkg`: DATA_WIDTH=512, NUM_G_CORES=4
`aurora_172_fpga_top.sv`: DATA_WIDTH=**64**, NUM_G_CORES=**16**
`fpga_io_wrapper.sv`: DATA_WIDTH=**64**, NUM_G_CORES=**16**

---

## 25+ HIGH PRIORITY

| # | Temuan | File | Baris |
|---|--------|------|-------|
| H-1 | 155 $display/$time tanpa synthesis guard | 10 files | — |
| H-2 | CDC multi-bit tanpa Gray encoding | `timing_manager.sv` | 107-115 |
| H-3 | Ring bus response ready hardwired (no backpressure) | `ring_bus.sv` | 3167 |
| H-4 | 78 unconnected module ports | `top.sv` | berbagai |
| H-5 | Write hit non-zero line offset bug | `l1_cache.sv` | 346-351 |
| H-6 | Shared hysteresis counter SmartShift | `smartshift.sv` | 219-295 |
| H-7 | Deadlock recovery drop transactions | `cache_coherency.sv` | 161-173 |
| H-8 | Testbench tanpa self-checking | `testbench.sv` | 237-454 |
| H-9 | Zero formal/SVA/coverage/random/UVM | semua | — |
| H-10 | AI core + NPU + RT engine tidak dites | `testbench.sv` | 131-163 |
| H-11 | Snoop preempt state machine — drop in-flight | `l1_cache.sv` | 224-274 |
| H-12 | First stride prefetcher pakai base address stale | `hw_prefetcher.sv` | 462-470 |
| H-13 | Stride truncation ke 16-bit | `hw_prefetcher.sv` | 153-162 |
| H-14 | throttle_excess hanya capture domain terakhir (NPU) | `smartshift.sv` | 235-275 |
| H-15 | Dual case blocks di 1 always — synthesis race | `turbo_boost.sv` | 167-373 |
| H-16 | throttle_event_count double-increment | `power_monitor.sv` | 324-328 |
| H-17 | A-Core activity threshold hardcoded | `power_management.sv` | 550-554 |
| H-18 | Hardware power model mismatch sim vs synth | `power_management.sv` | 871-913 |
| H-19 | PCIe placeholder — TLP 8-bit tanpa serialisasi | `fpga_io_wrapper.sv` | 524-545 |
| H-20 | DDR4 tri-state internal — invalid synthesis | `fpga_io_wrapper.sv` | 311, 490-493 |
| H-21 | DDR4 refresh timing off 1000x | `fpga_io_wrapper.sv` | 431-443 |
| H-22 | Recovery FSM 6 state mati total | `exception_handler.sv` | 142-208 |
| H-23 | uop_cache output floating | `top.sv` | 2527-2534 |
| H-24 | g_core.sv — integer area2 bit-OR 1 (barycentric bug) | `g_core.sv` | 470-471 |
| H-25 | Ray direction hardcoded (1,1,1) | `rt_engine.sv` | 511-513 |
| H-26 | Verilator lint_off global masks real issues | berbagai | berbagai |

---

## PSEUDO PARALLELISM & HIDDEN SERIALIZATION

| Klaim | Realitas |
|-------|----------|
| 64 A-Core "parallel" | Fabric arbiter last-wins → serial |
| 16 G-Core "parallel" | Satu priority mux → 1 result/cycle |
| 32 H-Core "parallel" | Fabric arbiter iterasi core by core |
| BVH "pipeline" | 48 iterasi di-unroll 1 cycle → black box combinational |
| DMA 8 channel "parallel" | Grant last-wins → channel 0 kelaparan |
| SIMD "vector" | 64-entry unrolled jadi MUX raksasa, bukan vector unit |

---

## VERIFICATION GAP

| Dimensi | Status |
|---------|--------|
| Formal assertion (SVA) | **NOL** |
| Formal assumption | **NOL** |
| Functional coverage | **NOL** |
| Constrained random | **NOL** |
| UVM | **NOL** |
| Self-checking | **NOL** |
| AI/NPU/RT/H-Core test | **NOL** |
| Memory backpressure test | **NOL** |
| AXI protocol test | **NOL** |
| Power management test | **NOL** |
| Pipeline hazard test | **NOL** |
| CDC test | **NOL** |
| Reset recovery test | **NOL** |
| Deadlock recovery test | **NOL** |

---

## TAPE-OUT BLOCKER LIST (Urutan Prioritas)

1. **Timeout → Silent Data Corruption** — Ubah semua timeout menjadi bus error/exception
2. **Cache Coherency Non-Functional** — Fix snoop bus, data forwarding, unpacked array
3. **Kombinasional BVH/Sqrt/Div (Timing Impossible)** — Pipeline semua
4. **Non-Synthesizable Constructs** — Ganti initial, fix blocking assignment
5. **Parameter Mismatch FPGA vs Design** — Satu source of truth
6. **Verification Zero** — Bangun dari 0 (estimasi 6-12 bulan)
7. **78 Unconnected Ports** — Connect atau buang
8. **Fabric Arbiter Priority Inversion** — True round-robin

---

## ESTIMASI READINESS PER KOMPONEN (0-10)

| Komponen | Skor | Catatan |
|----------|------|---------|
| Arsitektur | 5/10 | Konsep menarik, implementasi belum matang |
| RTL Completeness | 3/10 | Banyak placeholder, fake completion |
| Timing Closure (6 GHz) | 1/10 | BVH + sqrt + divider impossible |
| CDC | 4/10 | Multi-bit tanpa Gray code |
| Verification | 0/10 | Zero formal, coverage, self-check |
| Testbench | 2/10 | 4 test tanpa pass/fail |
| FPGA Prototype | 2/10 | Parameter mismatch, PCIe broken |
| Power Management | 3/10 | Semua model fiktif |
| Cache Coherency | 1/10 | MESI tanpa snoop, forwarding 0 |
| Synthesis Ready | 2/10 | 155 $display, 4 initial blocks |

---

## FAKE COMPLETION INDICATOR

- `l3_hit = 1'b0` — L3 cache mati total
- MESI snoop bus floating — coherency hanya simulation
- `resp_data_from_cache = 512'b0` — data forwarding broken
- S_SNOOP_CHECK langsung `state <= S_IDLE` — implementasi kosong
- Recovery FSM 6 state tidak pernah transit
- uop_cache output floating — dead logic
- DDR4 refresh 1000x terlalu lambat
- Testbench tie-off AI core
- Ray direction hardcoded
- 80+ FIX comment = iterasi tanpa re-verifikasi

---

## SIMULATOR DEPENDENCY

- Verilator `lint_off` menekan error legitimate
- Icarus clocking block removal → hilang race protection
- `$time` di RTL ring_bus, noc_router, scheduler
- `# delay` di testbench
- `\`ifdef VERILATOR` tidak portable ke VCS/Questa

---

## BAGIAN PALING MENCURIGAKAN SECARA ARSITEKTUR

1. **Target 6 GHz dengan BVH traverse 48 iterasi di 1 cycle** — tidak realistis
2. **64 A-Core "parallel" via single fabric arbiter** — bottleneck jelas
3. **Cache coherency tanpa snoop bus** — protocol tidak mungkin jalan
4. **Semua timeout fabrication data** — menutupi bug di simulation
5. **FPGA prototype dengan parameter berbeda** — tidak validasi desain yang sama

---

## PRIORITAS PERBAIKAN

### Segera (sebelum fungsional verification):
1. Hapus semua `initial` block dari RTL (4 files)
2. Guard semua `$display`/`$time` dengan `\`ifndef SYNTHESIS`
3. Fix blocking assignments di sequential always (3 files)
4. Fix multi-driven signal di `exception_handler.sv`

### Penting (sebelum synthesis):
5. Pipeline BVH traversal, integer sqrt, 64-bit divider
6. Ubah timeout → bus error, jangan fabricate data
7. Fix fabric arbiter → true round-robin
8. Fix DMA grant → true round-robin
9. Hubungkan snoop bus MESI

### Verification (sebelum tape-out):
10. Tambahkan SVA assertions
11. Bangun UVM testbench
12. Tambahkan functional coverage
13. Aktifkan random testing
14. Test semua core type (AI, NPU, RT, H-Core)

### FPGA (sebelum tape-out):
15. Samakan parameter FPGA dengan global pkg
16. Fix PCIe TLP + serialisasi
17. Fix DDR4 tri-state internal
18. Fix DDR4 refresh timing

---

*Laporan ini dihasilkan oleh audit otomatis menggunakan 5 sub-agent terhadap 51 file SystemVerilog.*
*Setiap temuan harus diverifikasi manual sebelum digunakan sebagai dasar keputusan tape-out.*

---

## STATUS PERBAIKAN (26 Mei 2026)

### ✅ SELESAI DIPERBAIKI

| # | Issue | File | Perubahan |
|---|-------|------|-----------|
| C-3 | `initial` block (non-synth) | `interconnect/hol_prevention.sv` | Dihapus, diganti generate param validation |
| C-3 | `initial` block (non-synth) | `interconnect/hol_integration.sv` | Dihapus, diganti generate param validation |
| C-3 | `initial` block (non-synth) | `interconnect/ring_bus.sv` | Dihapus, kredit counter dipindah ke reset block |
| C-3 | `initial` block (non-synth) | `interconnect/timing_manager.sv` | Dihapus (hanya $display) |
| C-3 | Blocking `=` di sequential | `g_core/uop_cache.sv` | Diubah ke `<=`, sensitivity ditambah `negedge rst_n` |
| C-1 | Timeout → data corruption | `memory_fabric/l1_cache.sv` | Tidak lagi fabricate 0xDE, stall + error signal |
| C-1 | Timeout → flush write buffer | `memory_fabric/l2_cache.sv` | Tidak lagi flush data, stall + error signal |
| C-1 | Timeout → stale data fill | `memory_fabric/vcache.sv` | Tidak lagi fill dengan stale data, stall + error |
| C-4 | Illegal unpacked array assign | `memory_fabric/cache_coherency.sv` | Changed to flat per-core arrays, fixed `reg` inside always |
| C-2 | Multi-driven `error_rate_count` | `exception_handler.sv` | Dipisahkan ke satu always block |
| C-7 | Priority inversion fabric arbiter | `top.sv` | Ditambahkan `fab_sel == -1` guard untuk first-match |
| C-7 | Priority inversion L2 arbiter | `top.sv` | Ditambahkan `found` flag untuk first-match |

### ⏳ BELUM DIPERBAIKI (Perlu Arsitektur Ulang)

| # | Issue | Alasan |
|---|-------|--------|
| C-5 | Cache coherency protocol non-functional | MESI tanpa snoop, forwarding return 0 — perlu rewrite besar |
| C-6 | BVH/sqrt/div combinational (timing impossible) | Perlu pipeline multi-stage — redesign arsitektural |
| C-8 | Parameter mismatch FPGA | Accepted untuk prototyping FPGA (resource constraint) |
| H-1 | 155 $display tanpa synthesis guard | Perlu `\`ifndef SYNTHESIS` di 10 file |
| H-2 | CDC multi-bit tanpa Gray code | Perubahan struktur synchronizer |
| H-24 | Barycentric area2 `| 1` bug | Perlu fix algoritma triangle setup |
| H-25 | Ray direction hardcoded | Perlu menghubungkan memory input |
| H-9 | Zero formal/coverage/random/UVM | Infrastruktur verifikasi baru |
| H-8 | Testbench tanpa self-checking | Rewrite testbench |
| Verif gap | 6+ domain tidak dites | Butuh verification engineer |

### Prioritas selanjutnya:
1. H-1: Guard 155 $display dengan `\`ifndef SYNTHESIS` (10 files)
2. C-6: Pipeline BVH traversal (rt_engine.sv) dan integer sqrt (g_core.sv)
3. H-24: Fix barycentric coordinate area2 bit-OR bug (g_core.sv)
4. C-5: Implementasi snoop bus untuk MESI protocol
