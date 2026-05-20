`ifndef AURORA_CONSTANTS_SVH
`define AURORA_CONSTANTS_SVH

// Core count parameters (only if not already defined by aurora_params.svh)
`ifndef AURORA_NUM_G_CORES
`define AURORA_NUM_G_CORES         4
`endif
`ifndef AURORA_NUM_H_CORES
`define AURORA_NUM_H_CORES         2
`endif
`ifndef AURORA_NUM_A_CORES
`define AURORA_NUM_A_CORES         2
`endif
`ifndef AURORA_NUM_NPU_CLUSTERS
`define AURORA_NUM_NPU_CLUSTERS    1
`endif

// Core resources
`ifndef AURORA_RESULT_FIFO_DEPTH
`define AURORA_RESULT_FIFO_DEPTH   16
`endif

// Interconnect
`ifndef AURORA_CREDIT_INITIAL
`define AURORA_CREDIT_INITIAL      8'd8
`endif

`endif
