# AURORA-172 Architecture Documentation

## Overview

AURORA-172 adalah arsitektur prosesor hibrida yang menggabungkan berbagai jenis core untuk mengoptimalkan workload gaming dan AI dalam satu chip.

## Design Philosophy

### Heterogeneous Computing

Tidak seperti CPU tradisional yang menggunakan core identik, AURORA-172 menggunakan pendekatan **heterogeneous unified processor**:

```
┌─────────────────────────────────────────────────────────┐
│                    AURORA-172 CHIP                       │
│                                                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐               │
│  │ G-Core x16│  │ H-Core x32│  │ A-Core x64│               │
│  │ (Gaming) │  │(General) │  │   (AI)    │               │
│  └──────────┘  └──────────┘  └──────────┘               │
│                                                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐               │
│  │  NPU x8  │  │ RT Engine│  │  Memory   │               │
│  │(Inference)│ │  (RT)    │  │  Fabric   │               │
│  └──────────┘  └──────────┘  └──────────┘               │
│                                                          │
│              Aurora Fabric (10 TB/s)                     │
└─────────────────────────────────────────────────────────┘
```

## Core Architectures

### 1. G-Core (Game Core)

**Tujuan**: Latency ultra-rendah untuk gaming

**Karakteristik**:
- Clock target: 6 GHz
- L1 Cache: 128KB per core
- Aggressive branch prediction dengan AI
- Zero-latency pipeline

**Instruction Set Extension**:
```systemverilog
OP_DRAW      = 8'h01  // Draw call acceleration
OP_TEXTURE   = 8'h02  // Texture sampling
OP_PHYSICS   = 8'h03  // Physics calculations
OP_COLLISION = 8'h04  // Collision detection
OP_RAYTRACE  = 8'h05  // Ray tracing
OP_FRAMEGEN  = 8'h06  // Frame generation
OP_SHADING   = 8'h07  // Shader computation
OP_BRANCH    = 8'h08  // AI-predicted branch
```

**Pipeline**:
```
IDLE → FETCH → DECODE → EXECUTE → MEMORY → WRITEBACK
```

### 2. H-Core (Hybrid Core)

**Tujuan**: General purpose & multitasking

**Karakteristik**:
- Out-of-order execution
- Reorder buffer (ROB) 64 entries
- Power-efficient design
- System management functions

**Pipeline**:
```
IDLE → FETCH → DECODE → EXECUTE → MEMORY → WRITEBACK → RETIRE
```

### 3. A-Core (AI Core)

**Tujuan**: Massive parallel tensor compute

**Karakteristik**:
- 16x16 matrix tile size
- Mixed precision: FP32/FP16/FP8/INT4
- Native tensor instructions
- Sparsity acceleration

**Instruction Set**:
```systemverilog
OP_MATMUL    = 8'h20  // Matrix multiplication
OP_ATTENTION = 8'h21  // Transformer attention
OP_CONV2D    = 8'h22  // 2D convolution
OP_POOLING   = 8'h23  // Pooling operations
OP_ACTIVATION= 8'h24  // Activation functions
OP_NORMALIZE = 8'h25  // Normalization
```

**Compute Flow**:
```
LOAD_A → LOAD_B → COMPUTE (MAC) → STORE
```

### 4. NPU Cluster

**Tujuan**: Ultra low-power AI inference

**Karakteristik**:
- 16 Processing Elements (PE) per cluster
- INT4/INT8 quantization support
- Real-time inference untuk NPC AI, voice, adaptive gameplay

**Inference Pipeline**:
```
LOAD_WEIGHT → LOAD_ACT → COMPUTE (MAC) → ACCUMULATE → STORE
```

### 5. RT Engine (Ray Tracing)

**Tujuan**: Native hardware ray tracing

**Karakteristik**:
- BVH traversal hardware
- Ray-triangle intersection
- AI denoising support
- Frame generation assist

**RT Pipeline**:
```
LOAD_RAYS → BVH_TRAVERSE → INTERSECT → SHADE → OUTPUT
```

## Memory Architecture

### 172-bit Unified Memory Bus

**Kenapa 172-bit?**
- Alignment untuk 128-bit SIMD + 44-bit ECC
- Bandwidth optimal untuk AI workloads
- Unique selling point vs competitors

**Cache Hierarchy**:

```
┌────────────────────────────────────────────┐
│           L4: HBM (64GB)                   │
│           Bandwidth: >2 TB/s               │
└────────────────────────────────────────────┘
                    ↕
┌────────────────────────────────────────────┐
│         L3: 256MB Shared                   │
│         Latency: ~50 cycles                │
└────────────────────────────────────────────┘
                    ↕
┌────────────────────────────────────────────┐
│         L2: 8MB per Cluster                │
│         Latency: ~20 cycles                │
└────────────────────────────────────────────┘
                    ↕
┌────────────────────────────────────────────┐
│         L1: 128KB per Core                 │
│         Latency: 3-4 cycles                │
└────────────────────────────────────────────┘
```

### Memory Access Pattern

```
Core Request
    ↓
L1 Cache Check (3-4 cycles)
    ↓ Hit/Miss
L2 Cache Check (20 cycles)
    ↓ Hit/Miss
L3 Cache Check (50 cycles)
    ↓ Hit/Miss
HBM Memory (100-200 cycles)
```

## Interconnect: Aurora Fabric

**Spesifikasi**:
- Bandwidth: 10 TB/s internal
- Latency: <1ns antar cluster
- Topology: Mesh network
- QoS support
- Deadlock-free routing

**Routing Algorithm**:
```systemverilog
// Simplified mesh routing
function automatic logic [6:0] get_route;
    input [ADDR_WIDTH-1:0] addr;
    begin
        get_route = addr[6:0];  // Hash address ke port
    end
endfunction
```

## Power Management

### AI-Based Power Scheduler

**Features**:
- Dynamic voltage scaling per core
- Thermal-aware compute shifting
- Power gating idle cores

**Power Modes**:
```
Mode 0: Gaming Mode (G-Core active, others idle)
Mode 1: AI Mode (A-Core + NPU active)
Mode 2: Mixed Mode (All cores active)
Mode 3: Power Saving (Minimal cores active)
```

## Target Process Technology

**Node**: 2nm / 1.8nm
**Transistor Count**: ~100B+ (estimasi)
**Die Size**: ~800 mm²
**Package**: Advanced chiplet with 3D stacking

## Performance Targets

### Gaming Performance
- **Draw Calls**: >1M per frame
- **Ray Tracing**: Real-time 4K@120fps
- **Frame Generation**: 2x-4x FPS boost

### AI Performance
- **TOPS**: >5000 (INT8)
- **Matrix Ops**: 16x16 tile per cycle
- **Inference Latency**: <1ms untuk model besar

### Memory Performance
- **Bandwidth**: >2 TB/s
- **Latency**: <100ns (L3 hit)
- **Efficiency**: >90% bandwidth utilization

## Design Flow

### 1. RTL Development
```
SystemVerilog (.sv)
    ↓
Lint Check (Verilator)
    ↓
Simulation (Testbench)
```

### 2. Verification
```
Testbench
    ↓
Functional Simulation
    ↓
Performance Validation
    ↓
Power Analysis
```

### 3. Synthesis (Future)
```
RTL (.sv)
    ↓
Logic Synthesis (Design Compiler)
    ↓
Place & Route (IC Compiler)
    ↓
GDSII Generation
    ↓
Tape-out
```

## Current Status

✅ **Phase 1 Complete**: RTL Design & Simulation
- All core modules implemented
- Memory fabric functional
- Testbench passing
- Verilator simulation working

🔄 **Next Steps**:
- Optimization & pipelining
- FPGA prototyping
- Advanced verification
- Performance benchmarking

## File Structure Reference

```
aurora-172/
├── top.sv                      # Top-level integration
├── sim_main.cpp                # Verilator wrapper
├── Makefile                    # Build system
├── README.md                   # Project overview
├── docs/
│   └── architecture.md         # This file
├── g_core/                     # Gaming cores
├── h_core/                     # Hybrid cores
├── a_core/                     # AI cores
├── npu/                        # NPU clusters
├── memory_fabric/              # Memory controller
├── interconnect/               # On-chip network
├── rt_engine/                  # Ray tracing
├── testbench/                  # Test infrastructure
└── scripts/                    # Build/synthesis scripts
```

---

*Last Updated: 10 April 2026*
*Version: 1.0.0*
