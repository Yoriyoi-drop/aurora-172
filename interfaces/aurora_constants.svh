`ifndef AURORA_CONSTANTS_SVH
`define AURORA_CONSTANTS_SVH

// Core count parameters (only if not already defined by aurora_params.svh)
`ifndef AURORA_NUM_G_CORES
`define AURORA_NUM_G_CORES         4
`endif
`ifndef AURORA_NUM_H_CORES
`define AURORA_NUM_H_CORES         32
`endif
`ifndef AURORA_NUM_A_CORES
`define AURORA_NUM_A_CORES         64
`endif
`ifndef AURORA_NUM_NPU_CLUSTERS
`define AURORA_NUM_NPU_CLUSTERS    8
`endif

// Core resources
`ifndef AURORA_RESULT_FIFO_DEPTH
`define AURORA_RESULT_FIFO_DEPTH   16
`endif

// NOTE: AURORA_CREDIT_INITIAL is defined in aurora_params.svh (source of truth)
// All core parameters should be kept in sync with aurora_params.svh

`endif
