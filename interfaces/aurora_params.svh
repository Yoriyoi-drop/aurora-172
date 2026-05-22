`ifndef AURORA_PARAMS_SVH
`define AURORA_PARAMS_SVH

//==============================================================================
// AURORA-172 SystemVerilog Parameters
//==============================================================================
// Two usage modes:
//   1) `include "interfaces/aurora_params.svh"  -> use `AURORA_* macros
//   2) import aurora_global_pkg::*               -> use bare AURORA_* params
//
// The package is defined in interfaces/aurora_global_pkg.sv
//==============================================================================

// ---------------------------------------------------------------------------
// Standard bus widths
// ---------------------------------------------------------------------------
`define AURORA_DATA_WIDTH         512
`define AURORA_ADDR_WIDTH          48
`define AURORA_INST_WIDTH          64
`define AURORA_L1_CACHE_SIZE    32768

// ---------------------------------------------------------------------------
// Core counts
// ---------------------------------------------------------------------------
`define AURORA_NUM_G_CORES          4
`define AURORA_NUM_H_CORES         32
`define AURORA_NUM_A_CORES         64
`define AURORA_NUM_NPU_CLUSTERS     8

// ---------------------------------------------------------------------------
// A-Core (AI/ML) parameters
// ---------------------------------------------------------------------------
`define AURORA_TILE_SIZE            8
`define AURORA_PRECISION            0
`define AURORA_RESULT_FIFO_DEPTH   16
`define AURORA_LINE_SIZE           64

// A-Core pipeline latencies (cycles)
`define AURORA_A_PIPE_MATMUL       80
`define AURORA_A_PIPE_ATTENTION    48
`define AURORA_A_PIPE_CONV2D       72
`define AURORA_A_PIPE_POOLING      24
`define AURORA_A_PIPE_ACTIVATION   16
`define AURORA_A_PIPE_NORMALIZE    20
`define AURORA_A_PIPE_LOAD_WT      12
`define AURORA_A_PIPE_STORE_WT     12

// ---------------------------------------------------------------------------
// G-Core (Graphics) pipeline latencies (cycles)
// ---------------------------------------------------------------------------
`define AURORA_G_PIPE_DRAW         64
`define AURORA_G_PIPE_TEXTURE      48
`define AURORA_G_PIPE_PHYSICS      40
`define AURORA_G_PIPE_COLLISION    32
`define AURORA_G_PIPE_RAYTRACE     96
`define AURORA_G_PIPE_FRAMEGEN     72
`define AURORA_G_PIPE_SHADING      56
`define AURORA_G_PIPE_BRANCH       12

// ---------------------------------------------------------------------------
// H-Core (Host/CPU) pipeline latencies (cycles)
// ---------------------------------------------------------------------------
`define AURORA_H_PIPE_ALU           8
`define AURORA_H_PIPE_MUL          12
`define AURORA_H_PIPE_DIV          24
`define AURORA_H_PIPE_LOAD         10
`define AURORA_H_PIPE_STORE        10
`define AURORA_H_PIPE_BRANCH        8

// ---------------------------------------------------------------------------
// RT Engine (Ray Tracing) pipeline latencies (cycles)
// ---------------------------------------------------------------------------
`define AURORA_RT_PIPE_TRACE       64
`define AURORA_RT_PIPE_CLOSEST     32
`define AURORA_RT_PIPE_ANY         28
`define AURORA_RT_PIPE_SHADE       48

// ---------------------------------------------------------------------------
// Memory / Cache parameters
// ---------------------------------------------------------------------------
`define AURORA_CACHE_LINE_WIDTH    512
`define AURORA_ASSOCIATIVITY         8

// ---------------------------------------------------------------------------
// Interconnect parameters
// ---------------------------------------------------------------------------
`define AURORA_BUFFER_DEPTH          4
`define AURORA_CREDIT_INITIAL       16
`define AURORA_CREDIT_RECOVERY_DELAY 10000

// ---------------------------------------------------------------------------
// Debug / profiling flags (use with `ifdef)
// ---------------------------------------------------------------------------
`define AURORA_DEBUG_CORE
`define AURORA_DEBUG_PERF
`define AURORA_DEBUG_DDR4
`define DEBUG_SCHEDULER

// Set by most simulator tools; defined here for Verilator compatibility.
// Enables queue overflow assertions and other simulation-only checks.
`define AURORA_SIMULATION

`endif
