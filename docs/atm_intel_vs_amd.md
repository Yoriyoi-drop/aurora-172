# ATM: Intel vs AMD → AURORA-172

> **Amati → Tiru → Modifikasi**  
> Fitur unik Intel yang tidak dimiliki AMD, dan fitur unik AMD yang tidak dimiliki Intel

---

## 📊 COMPARISON MATRIX

| Fitur | Intel Only ✅ | AMD Only ✅ | Both ✅ |
|-------|:-------------:|:-----------:|:-------:|
| **Heterogeneous Core** | P-Core + E-Core (Alder Lake+) | Zen 5c + Zen 5 (limited) | - |
| **3D Stacked Cache** | ❌ | 3D V-Cache (96MB L3) | - |
| **Ring Bus** | Client CPU | ❌ | - |
| **Chiplet Infinity Fabric** | ❌ | CCD/CCX + SDF | - |
| **μop Cache** | 1.5K entries | ❌ (decode langsung) | - |
| **Hardware Prefetcher** | 4-stream adaptive | Data streamer | Both (beda impl) |
| **Turbo Boost** | Time-limited turbo | Precision Boost (thermal-based) | Both (beda approach) |
| **Speed Shift (HWP)** | HW-controlled P-states | ❌ (OS-controlled) | - |
| **SGX Enclave** | Encrypted execution | ❌ | - |
| **TME Encryption** | Memory encryption | ❌ | - |
| **MESIF Coherency** | Forward state | MOESI (Owned state) | - |
| **Adaptive Routing** | Mesh QoS | ❌ (deterministic) | - |
| **CET Security** | ROP/JOP mitigation | ❌ | - |
| **RAPL Power Limit** | Energy counter + limit | ❌ (no hardware counter) | - |
| **SmartShift Power** | ❌ | GPU↔CPU power sharing | - |
| **SmartAccess Memory** | ❌ | GPU direct CPU access | - |

---

## 🔵 INTEL EXCLUSIVE (AMD Tidak Punya)

### 1. **μop Cache (Micro-op Cache)**
**Apa itu:** Cache hasil decode instruction → micro-ops, hindari decode ulang

```
INTEL APPROACH:
┌─────────────────────────────────────────────┐
│  Instruction Fetch → Decoder → μop Cache    │
│                              ↓              │
│                     Cache μops (1.5K)        │
│                              ↓              │
│                     Skip decode next time     │
│                                              │
│  Benefit: 25-40% power savings di frontend   │
└─────────────────────────────────────────────┘

AMD APPROACH (NO μop Cache):
┌─────────────────────────────────────────────┐
│  Instruction Fetch → Decoder → Execute      │
│  Selalu decode dari awal                    │
│  Power lebih tinggi di frontend             │
└─────────────────────────────────────────────┘

→ AURORA: IMPLEMENTASI μop Cache untuk gaming!
  Gaming instruction sering repeat (draw calls)
  Cache decoded ops → skip decode berulang
```

**File baru:** `g_core/uop_cache.sv`

---

### 2. **Turbo Boost (Time-Limited)**
**Apa itu:** Boost frequency di atas TDP, tapi dengan timer (tau = 28 detik default)

```
INTEL TURBO BOOST:
┌─────────────────────────────────────────────┐
│  Base Clock:     3.0 GHz                    │
│  Turbo Max:      5.8 GHz (+93%)             │
│  Tau (timer):    28 seconds                 │
│  Limit:          TDP + 20%                  │
│                                              │
│  [0-28 sec]  → Full turbo (5.8 GHz)         │
│  [28+ sec]   → Drop ke TDP limit (4.5 GHz)  │
│  [Cooldown]  → Thermal turun, turbo lagi    │
└─────────────────────────────────────────────┘

AMD PRECISION BOOST (BERBEDA):
┌─────────────────────────────────────────────┐
│  No time limit!                             │
│  Boost berdasarkan:                         │
│  - Temperature headroom                     │
│  - Current draw (Ampere)                    │
│  - Power limit (PPT)                        │
│  Sustained boost selama thermal cukup       │
└─────────────────────────────────────────────┘

→ AURORA: HYBRID APPROACH
  Gaming: Intel time-limited (burst turbo)
  AI: AMD sustained (thermal-based, unlimited)
  Mixed: Adaptive per workload
```

**File baru:** `memory_fabric/turbo_boost.sv`

---

### 3. **Speed Shift (Hardware P-States / HWP)**
**Apa itu:** Hardware kontrol frequency scaling (bukan OS), latency <1ms

```
INTEL HWP:
┌─────────────────────────────────────────────┐
│  OS set policy → Hardware autonomous        │
│  Hardware monitor:                          │
│  - CPU utilization                          │
│  - Temperature                              │
│  - Workload pattern                          │
│  → Adjust P-state dalam <1ms               │
│                                              │
│  Intel EPP (Energy Performance Preference):  │
│  0x00 = Max Performance                     │
│  0xFF = Max Power Savings                   │
└─────────────────────────────────────────────┘

AMD (OS-CONTROLLED):
┌─────────────────────────────────────────────┐
│  OS governor kontrol frequency              │
│  Latency lebih tinggi (10-50ms)             │
│  CPPC (Collaborative Power Control):        │
│  OS request → AMD adjust (tidak full auto)  │
└─────────────────────────────────────────────┘

→ AURORA: SCHEDULER-INTEGRATED HWP
  Scheduler tahu workload type → set frequency
  Tidak perlu OS, hardware autonomous
  Response time <10 cycles
```

---

### 4. **MESIF Cache Coherency**
**Apa itu:** MESI + **Forward** state untuk snoop optimization

```
INTEL MESIF:
┌─────────────────────────────────────────────┐
│  M (Modified):   Dirty, exclusive           │
│  E (Exclusive):  Clean, exclusive           │
│  S (Shared):     Clean, shared              │
│  I (Invalid):    Invalid                    │
│  F (Forward):    Shared tapi BISA forward   │
│                    → Snoop langsung ke F     │
│                    → Hindari memory access   │
└─────────────────────────────────────────────┘

AMD MOESI:
┌─────────────────────────────────────────────┐
│  M (Modified):   Dirty, exclusive           │
│  O (Owned):      Dirty, shared (sumber)     │
│  E (Exclusive):  Clean, exclusive           │
│  S (Shared):     Clean, shared              │
│  I (Invalid):    Invalid                    │
│                                              │
│  Owned = cache yang bertanggung jawab       │
│  forward data ke snoop request              │
└─────────────────────────────────────────────┘

PERBEDAAN:
- Intel F: Shared, bisa forward (clean)
- AMD O: Shared, wajib forward (dirty)
- Intel: Lebih efisien untuk read-heavy
- AMD: Lebih baik untuk write-heavy

→ AURORA: MESIX (Extended)
  Tambah state "Gaming" (G) → priority access
  Tambah state "AI" (A) → bulk transfer mode
  MESI + G + A = 6 states
```

**Modifikasi:** `memory_fabric/mesi_controller.sv`

---

### 5. **CET (Control-flow Enforcement Technology)**
**Apa itu:** Hardware mitigation untuk ROP/JOP attacks (security)

```
INTEL CET:
┌─────────────────────────────────────────────┐
│  ENDBRANCH: Valid branch target marker      │
│  SHSTK: Shadow Stack (return address copy)  │
│                                              │
│  Detect ROP: Return address ≠ Shadow stack  │
│  Detect JOP: Jump target tanpa ENDBRANCH    │
│                                              │
│  Benefit: Block 99% code reuse attacks      │
└─────────────────────────────────────────────┘

AMD: ❌ Tidak ada equivalent (software only)

→ AURORA: GAMING ANTI-CHEAT
  ENDBRANCH → Valid game instruction marker
  SHADOW STACK → Game state integrity check
  Block cheat engines yang inject code
```

---

### 6. **RAPL (Running Average Power Limit)**
**Apa itu:** Hardware power monitoring + enforcement

```
INTEL RAPL:
┌─────────────────────────────────────────────┐
│  Energy Counter: 64-bit (15.3μJ resolusi)  │
│  Power Domain:                              │
│  - Package (entire CPU)                     │
│  - PP0 (cores)                              │
│  - PP1 (uncore/gpu)                         │
│  - DRAM                                     │
│                                              │
│  Power Limit:                               │
│  - PL1 (long-term, TDP)                     │
│  - PL2 (short-term, turbo)                  │
│  → Auto throttle kalau exceed limit         │
└─────────────────────────────────────────────┘

AMD: ❌ Tidak ada hardware energy counter
  Hanya power reporting (tidak精确)

→ AURORA: COMPREHENSIVE POWER ACCOUNTING
  Per-core energy counter (64-bit)
  Per-domain: G-Core, A-Core, H-Core, NPU, Memory
  Power limit enforcement (PL1 + PL2)
```

**File baru:** `memory_fabric/power_monitor.sv`

---

## 🔴 AMD EXCLUSIVE (Intel Tidak Punya)

### 1. **3D V-Cache (Stacked L3)**
**Apa itu:** L3 cache di-stack vertikal (TSV) → 3x kapasitas

```
AMD 3D V-CACHE:
┌─────────────────────────────────────────────┐
│  L3 Base:     32MB (planar)                 │
│  L3 Stacked:  64MB (3D V-Cache)             │
│  Total:       96MB per CCD                  │
│                                              │
│  TSV (Through-Silicon Via):                 │
│  - 24,000+ connections                      │
│  - Latency: ~7 cycles (vs ~4 base L3)       │
│  - Bandwidth: 2 TB/s                        │
│                                              │
│  Gaming benefit: +15% FPS (avg)             │
│  Cache miss rate turun 40%                  │
└─────────────────────────────────────────────┘

INTEL: ❌ Tidak ada 3D cache (planar only)

→ AURORA: AI-GAMING HYBRID CACHE
  L3 Gaming: Stacked (high capacity)
  L3 AI:      Planar (low latency)
  Dynamic switch per workload
  
  Implementasi RTL (no TSV di sim):
  Model V-Cache sebagai "extended L3"
  Latency: 7 cycles (vs 4 base)
  Capacity: 3x normal
```

**File baru:** `memory_fabric/vcache.sv`

---

### 2. **Infinity Fabric (Chiplet Interconnect)**
**Apa itu:** Modular chiplet design dengan fabric interconnect

```
AMD CHIPLET DESIGN:
┌─────────────────────────────────────────────┐
│  CCD (Core Complex Die):                    │
│  - 8 cores per CCD (CCX)                    │
│  - 7nm / 5nm (compute optimized)            │
│  - Multiple CCDs per package                │
│                                              │
│  IOD (I/O Die):                              │
│  - 12nm / 6nm (I/O optimized)               │
│  - Memory controller                        │
│  - PCIe, USB, etc                           │
│                                              │
│  Infinity Fabric:                            │
│  - SDF (Scalable Data Fabric)               │
│  - 112 GB/s bi-directional (per link)       │
│  - Cache coherent antar CCD                 │
│  - Ring bus di dalam CCD                    │
│  - Point-to-point antar CCD via IOD         │
└─────────────────────────────────────────────┘

INTEL: ❌ Monolithic design (satu die besar)
  Kecuali Ponte Vecchio (GPU chiplet)

→ AURORA: CHIPLET-INSPIRED ARCHITECTURE
  G-Core Chiplet: 16 cores (gaming optimized)
  A-Core Chiplet: 32 cores (AI compute)
  H-Core Chiplet: 32 cores (general)
  NPU Chiplet:    4 clusters (inference)
  
  Inter-chiplet: Aurora Fabric (mesh)
  Intra-chiplet: Ring bus (low latency)
```

---

### 3. **SmartShift (CPU↔GPU Power Sharing)**
**Apa itu:** Dynamic power redistribution CPU ↔ GPU

```
AMD SMARTSHIFT:
┌─────────────────────────────────────────────┐
│  Scenario 1: Gaming (GPU-bound)             │
│  → CPU power turun (25W → 15W)              │
│  → GPU power naik (80W → 90W)               │
│  → FPS naik 10-15%                          │
│                                              │
│  Scenario 2: Compute (CPU-bound)            │
│  → GPU power turun                          │
│  → CPU power naik                           │
│  → Render time turun 12%                    │
│                                              │
│  Response time: <1ms                        │
│  Total TDP tetap (100W)                     │
└─────────────────────────────────────────────┘

INTEL: ❌ Tidak ada (CPU dan GPU terpisah)

→ AURORA: CORE-TO-CORE POWER SHIFT
  G-Core ↔ A-Core power sharing
  
  Gaming mode:
  G-Core: 100W → 120W (+20%)
  A-Core: 50W  → 30W (-40%)
  
  AI mode:
  G-Core: 100W → 60W (-40%)
  A-Core: 100W → 140W (+40%)
  
  Total TDP tetap, redistribution only
```

**File baru:** `memory_fabric/smartshift.sv`

---

### 4. **SmartAccess Memory (GPU Direct CPU Access)**
**Apa itu:** CPU akses full GPU VRAM (bukan hanya 256MB BAR)

```
AMD SAM:
┌─────────────────────────────────────────────┐
│  Traditional: CPU akses GPU VRAM terbatas   │
│  → BAR size limit: 256MB                    │
│  → CPU harus paging untuk VRAM besar        │
│                                              │
│  SAM Enabled:                                │
│  → CPU akses full VRAM (64GB HBM)           │
│  → Zero-copy memory access                  │
│  → Latency turun 5-10%                      │
│  → FPS naik 5-12% (gaming)                  │
└─────────────────────────────────────────────┘

INTEL: ❌ Limited (Resizable BAR ada tapi beda)

→ AURORA: UNIFIED MEMORY (sudah ada!)
  Sudah: 172-bit unified memory bus
  Tapi bisa ditingkatkan:
  - Direct path G-Core → VRAM (bypass fabric)
  - Direct path A-Core → VRAM (bypass fabric)
  - Hardware zero-copy semantics
```

---

### 5. **Precision Boost (Thermal-Based, Unlimited)**
**Apa itu:** Boost tanpa time limit, selama thermal headroom

```
AMD PRECISION BOOST:
┌─────────────────────────────────────────────┐
│  Tidak ada timer (unlike Intel tau=28s)     │
│  Boost berdasarkan:                         │
│  - Temperature (target 95°C max)            │
│  - Current (Ampere limit)                   │
│  - Power (PPT limit)                        │
│                                              │
│  Jika thermal cukup → boost selamanya       │
│  Tidak ada forced downgrade setelah X sec   │
│                                              │
│  PBO (Precision Boost Overdrive):           │
│  → Unlock limits untuk enthusiasts          │
│  → +200MHz sustained (liquid cooling)       │
└─────────────────────────────────────────────┘

INTEL: Time-limited (28 sec tau)

→ AURORA: HYBRID BOOST
  Gaming: Time-limited (burst, Intel-style)
  AI: Sustained (thermal-based, AMD-style)
  Mixed: Adaptive (AI predict optimal)
```

---

### 6. **MOESI Coherency (Owned State)**
**Apa itu:** Cache coherency dengan **Owned** state untuk write-heavy workloads

```
AMD MOESI:
┌─────────────────────────────────────────────┐
│  O (Owned): Cache line dirty + shared       │
│           → Owner bertanggung jawab         │
│           → Snoop request → Owner respond  │
│           → Tidak perlu writeback ke memory │
│                                              │
│  Benefit untuk write-heavy:                 │
│  - Hindari writeback berulang ke memory     │
│  - Owner "push" data ke requester           │
│  - Lebih efisien untuk AI training           │
└─────────────────────────────────────────────┘

INTEL MESIF: F state (clean forwarder)

→ AURORA: MOESIX-GA
  Combine best of both:
  M-O-E-S-I dari AMD
  Tambah: G (Gaming priority)
  Tambah: A (AI bulk transfer)
  Total: 7 states!
```

---

## 🏆 PILIHAN TERBAIK UNTUK AURORA-172

### **TIER 1: CRITICAL** (Wajib implement)

| # | Fitur | Dari | Alasan | Impact |
|---|-------|------|--------|--------|
| 1 | **SmartShift Power** | AMD | Perfect untuk gaming+AI hybrid | 🔥🔥🔥🔥🔥 |
| 2 | **3D V-Cache Model** | AMD | Gaming cache hit rate | 🔥🔥🔥🔥🔥 |
| 3 | **Turbo Boost Hybrid** | Intel+AMD | Burst + sustained boost | 🔥🔥🔥🔥🔥 |
| 4 | **μop Cache** | Intel | Gaming instruction repeat | 🔥🔥🔥🔥 |

### **TIER 2: HIGH PRIORITY** (Sangat recommended)

| # | Fitur | Dari | Alasan | Impact |
|---|-------|------|--------|--------|
| 5 | **RAPL Power Monitor** | Intel | Power accounting critical | 🔥🔥🔥🔥 |
| 6 | **Hardware Prefetcher** | Intel | Cache miss reduction | 🔥🔥🔥🔥 |
| 7 | **MOESIX-GA Coherency** | AMD+Intel | Better write-heavy perf | 🔥🔥🔥 |
| 8 | **Speed Shift (HWP)** | Intel | Fast DVFS response | 🔥🔥🔥 |

### **TIER 3: MEDIUM** (Nice to have)

| # | Fitur | Dari | Alasan | Impact |
|---|-------|------|--------|--------|
| 9 | **CET Anti-Cheat** | Intel | Gaming security | 🔥🔥🔥 |
| 10 | **Ring Bus (Gaming)** | AMD | Low latency gaming | 🔥🔥🔥 |
| 11 | **Chiplet Architecture** | AMD | Scalability | 🔥🔥 |
| 12 | **Virtual Channels** | Intel | Deadlock avoidance | 🔥🔥🔥 |

---

## 📋 IMPLEMENTATION PLAN

### **Phase 5.1: SmartShift Power** (CRITICAL)
**File:** `memory_fabric/smartshift.sv`
**Konsep:**
```
Input:
  - gaming_power_demand (dari G-Core scheduler)
  - ai_power_demand (dari A-Core scheduler)
  - total_tdp_limit (user configurable)

Output:
  - g_core_power_budget
  - a_core_power_budget
  - h_core_power_budget
  - npu_power_budget

Algorithm:
  IF gaming_mode AND gpu_bound:
    g_core_budget = base + (h_core_surplus * 0.6)
    a_core_budget = base - (base * 0.3)
    h_core_budget = base - (base * 0.2)
  
  IF ai_mode:
    a_core_budget = base + (g_core_surplus * 0.7)
    g_core_budget = base - (base * 0.4)
```

### **Phase 5.2: V-Cache Model** (GAMING BOOST)
**File:** `memory_fabric/vcache.sv`
**Konsep:**
```
L3 Base: 64MB (planar, latency 4 cycles)
L3 V-Cache: 192MB (stacked, latency 7 cycles)

Access pattern:
  IF gaming workload:
    prefer V-Cache (high capacity)
    tag working set → keep in V-Cache
  IF AI workload:
    prefer L3 Base (low latency)
    bulk transfers → base L3
```

### **Phase 5.3: Turbo Boost Hybrid** (PERF BOOST)
**File:** `memory_fabric/turbo_boost.sv`
**Konsep:**
```
Gaming Turbo (Intel-style):
  - Base: 6.0 GHz
  - Turbo: 6.5 GHz (+8%)
  - Tau: 28000 cycles (28ms)
  - PL2: +20% TDP

AI Turbo (AMD-style):
  - Base: 4.0 GHz
  - Turbo: 4.5 GHz (+12%)
  - No time limit
  - Limited by thermal only

Hybrid:
  - AI predict workload switch
  - Pre-adjust turbo before transition
```

### **Phase 5.4: μop Cache** (FRONTEND EFFICIENCY)
**File:** `g_core/uop_cache.sv`
**Konsep:**
```
Cache decoded gaming instructions:
  OP_DRAW, OP_TEXTURE, OP_SHADING
  
Capacity: 512 entries (1/3 Intel size, cukup untuk gaming)
Associativity: 8-way

Hit: Skip decode → langsung execute
Miss: Decode → cache result → execute

Benefit: Gaming draw calls sering repeat → hit rate >80%
```

---

## 🎯 FINAL RECOMMENDATION

**Implementasi urutan ini (best ROI):**

1. ✅ **SmartShift** - Impact terbesar untuk hybrid compute
2. ✅ **Turbo Boost Hybrid** - Immediate performance boost
3. ✅ **μop Cache** - Reduce frontend power + latency
4. ✅ **V-Cache Model** - Gaming cache hit rate
5. ✅ **RAPL Monitor** - Power accountability

**Estimasi benefit:**
- Gaming FPS: +15-25%
- AI throughput: +10-20%
- Power efficiency: -20-30%
- Cache hit rate: +30-40%

---

## 📚 REFERENCES

- Intel Architecture: Golden Cove, Raptor Lake, Alder Lake
- AMD Architecture: Zen 4, Zen 5, 3D V-Cache
- Intel 12th-14th Gen Whitepapers
- AMD Zen 4/5 Hot Chips Presentations
- Chips & Cheese: Zen 5 Deep Dive
- AMD EPYC Architecture Whitepaper

---

*Created: 11 April 2026*
*Version: 1.0 - ATM Intel vs AMD Complete*
