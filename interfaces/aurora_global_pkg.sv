package aurora_global_pkg;

    // =========================================================================
    // Standard bus widths
    // =========================================================================
    parameter int AURORA_DATA_WIDTH          = 512;
    parameter int AURORA_ADDR_WIDTH          = 48;
    parameter int AURORA_INST_WIDTH          = 64;
    parameter int AURORA_L1_CACHE_SIZE       = 32768;

    // =========================================================================
    // Core counts
    // =========================================================================
    parameter int AURORA_NUM_G_CORES         = 4;
    parameter int AURORA_NUM_H_CORES         = 32;
    parameter int AURORA_NUM_A_CORES         = 64;
    parameter int AURORA_NUM_NPU_CLUSTERS    = 8;

    // =========================================================================
    // A-Core (AI/ML) parameters
    // =========================================================================
    parameter int AURORA_TILE_SIZE           = 8;
    parameter int AURORA_PRECISION           = 0;
    parameter int AURORA_RESULT_FIFO_DEPTH   = 16;
    parameter int AURORA_LINE_SIZE           = 64;

    // A-Core pipeline latencies (cycles)
    parameter int AURORA_A_PIPE_MATMUL       = 80;
    parameter int AURORA_A_PIPE_ATTENTION    = 48;
    parameter int AURORA_A_PIPE_CONV2D       = 72;
    parameter int AURORA_A_PIPE_POOLING      = 24;
    parameter int AURORA_A_PIPE_ACTIVATION   = 16;
    parameter int AURORA_A_PIPE_NORMALIZE    = 20;
    parameter int AURORA_A_PIPE_LOAD_WT      = 12;
    parameter int AURORA_A_PIPE_STORE_WT     = 12;

    // =========================================================================
    // G-Core (Graphics) pipeline latencies (cycles)
    // =========================================================================
    parameter int AURORA_G_PIPE_DRAW         = 64;
    parameter int AURORA_G_PIPE_TEXTURE      = 48;
    parameter int AURORA_G_PIPE_PHYSICS      = 40;
    parameter int AURORA_G_PIPE_COLLISION    = 32;
    parameter int AURORA_G_PIPE_RAYTRACE     = 96;
    parameter int AURORA_G_PIPE_FRAMEGEN     = 72;
    parameter int AURORA_G_PIPE_SHADING      = 56;
    parameter int AURORA_G_PIPE_BRANCH       = 12;

    // =========================================================================
    // H-Core (Host/CPU) pipeline latencies (cycles)
    // =========================================================================
    parameter int AURORA_H_PIPE_ALU          = 8;
    parameter int AURORA_H_PIPE_MUL          = 12;
    parameter int AURORA_H_PIPE_DIV          = 24;
    parameter int AURORA_H_PIPE_LOAD         = 10;
    parameter int AURORA_H_PIPE_STORE        = 10;
    parameter int AURORA_H_PIPE_BRANCH       = 8;

    // =========================================================================
    // RT Engine (Ray Tracing) pipeline latencies (cycles)
    // =========================================================================
    parameter int AURORA_RT_PIPE_TRACE       = 64;
    parameter int AURORA_RT_PIPE_CLOSEST     = 32;
    parameter int AURORA_RT_PIPE_ANY         = 28;
    parameter int AURORA_RT_PIPE_SHADE       = 48;

    // =========================================================================
    // Memory / Cache parameters
    // =========================================================================
    parameter int AURORA_CACHE_LINE_WIDTH    = 512;
    parameter int AURORA_ASSOCIATIVITY       = 8;

    // =========================================================================
    // Interconnect parameters
    // =========================================================================
    parameter int AURORA_BUFFER_DEPTH         = 4;
    parameter int AURORA_CREDIT_INITIAL       = 16;
    parameter int AURORA_CREDIT_RECOVERY_DELAY = 10000;

endpackage
