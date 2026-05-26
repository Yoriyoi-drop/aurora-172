`timescale 1ns / 1ps

// verilator lint_off WIDTHEXPAND
// verilator lint_off WIDTHTRUNC

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: AI Accelerator Team
// Module Name: npu_cluster
//
// Description:
//   Neural Processing Unit Cluster - Ultra low power inference
//   - 32 Processing Elements (PEs) dengan actual MAC compute
//   - INT4/INT8 quantization support
//   - Weight preload & management hardware
//   - Actual convolution & matrix multiply
//   - Sparsity acceleration (skip zero weights)
//////////////////////////////////////////////////////////////////////////////////

module npu_cluster #(
    parameter CLUSTER_ID    = 0,
    parameter DATA_WIDTH    = `AURORA_DATA_WIDTH,   // FIX: Use standard parameter
    parameter ADDR_WIDTH    = `AURORA_ADDR_WIDTH,   // FIX: Use standard parameter
    parameter NUM_PE        = 32,
    parameter WEIGHT_BITS   = 8,
    parameter LINE_SIZE     = 64,

    // Pipeline depth (optimized for 512-bit bus)
    parameter NPU_PIPE_INFERENCE = 24,
    parameter NPU_PIPE_CONV      = 35,
    parameter NPU_PIPE_POOL      = 15,
    parameter NPU_PIPE_RELU      = 12,
    parameter NPU_PIPE_SIGMOID   = 20,
    parameter NPU_PIPE_SOFTMAX   = 40
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Command interface
    input  wire [ADDR_WIDTH-1:0]        cmd_addr,
    input  wire [DATA_WIDTH-1:0]        cmd_data,
    input  wire                         cmd_valid,
    output reg                          cmd_ready,

    // Memory fabric interface
    output reg [ADDR_WIDTH-1:0]         fabric_addr,
    output reg                          fabric_rd_en,
    output reg                          fabric_wr_en,
    input  wire [DATA_WIDTH-1:0]        fabric_rd_data,
    output reg [DATA_WIDTH-1:0]        fabric_wr_data,
    input  wire                         fabric_ready,

    // Status
    output reg                          busy,
    output reg                          complete,
    output reg [DATA_WIDTH-1:0]         result,

    // Error/Exception interface
    output reg                          error_flag,
    output reg [7:0]                    error_code,
    output reg                          error_valid
);

    // =========================================================================
    // Weight memory (on-chip SRAM)
    // =========================================================================
    reg signed [WEIGHT_BITS-1:0] weight_mem [0:1023];  // 1KB weight storage
    reg [9:0]                     weight_addr;
    reg                           weight_loaded;
    reg [10:0]                    weight_count;

    // =========================================================================
    // Activation buffer (input/output)
    // =========================================================================
    reg signed [31:0] act_in [0:NUM_PE-1];
    reg signed [31:0] act_out [0:NUM_PE-1];
    reg signed [31:0] partial_sums [0:NUM_PE-1];

    // =========================================================================
    // MAC array (actual compute hardware)
    // =========================================================================
    reg signed [WEIGHT_BITS-1:0] pe_weights [0:NUM_PE-1];
    reg signed [31:0]            pe_acc [0:NUM_PE-1];
    reg                          pe_active [0:NUM_PE-1];

    // =========================================================================
    // State machine
    // =========================================================================
    reg [3:0]               state;
    localparam IDLE         = 4'b0000;
    localparam LOAD_WEIGHT  = 4'b0001;
    localparam LOAD_ACT     = 4'b0010;
    localparam PRECOMPUTE   = 4'b0011;
    localparam MAC_COMPUTE  = 4'b0100;
    localparam ACCUMULATE   = 4'b0101;
    localparam ACTIVATE     = 4'b0110;
    localparam STORE        = 4'b0111;
    localparam COMPLETE_ST  = 4'b1000;
    localparam ERROR_ST     = 4'b1111;

    // Execution control
    reg [15:0]              exec_counter;
    reg [15:0]              exec_target;
    reg [7:0]               opcode;
    reg [31:0]              num_elements;
    reg [ADDR_WIDTH-1:0]    saved_addr;
    reg [DATA_WIDTH-1:0]    saved_data;

    // Compute indices
    reg [15:0]              pe_idx;
    reg [7:0]               pe_iterations;  // Max-iteration guard for pe_idx wrap
    reg [2:0]               reduce_level;  // FIXED: Multi-level tree reduction
    reg [15:0]              elem_idx;

    // FIX v2: STORE timeout counter to prevent hang
    reg [7:0]               store_timeout_counter;
    reg [7:0]               complete_timeout_counter;

    // Opcodes
    localparam OP_NOP       = 8'h40;
    localparam OP_INFERENCE = 8'h41;
    localparam OP_CONV      = 8'h42;
    localparam OP_POOL      = 8'h43;
    localparam OP_RELU      = 8'h44;
    localparam OP_SIGMOID   = 8'h45;
    localparam OP_SOFTMAX   = 8'h46;
    localparam OP_LOAD_W    = 8'h47;
    localparam OP_MATMUL    = 8'h48;

    // Error codes
    localparam ERR_NPU_TIMEOUT = 8'h40;
    localparam ERR_WEIGHT_OVF  = 8'h41;
    // FIX v2: Error code for STORE timeout
    localparam ERR_STORE_TIMEOUT = 8'h42;

    // =========================================================================
    // Helper: Sparsity check (skip zero weights)
    // =========================================================================
    function automatic logic is_sparse;
        input signed [WEIGHT_BITS-1:0] w;
        begin
            is_sparse = (w == 0);
        end
    endfunction

    // =========================================================================
    // Main NPU controller
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            busy <= 1'b0;
            complete <= 1'b0;
            cmd_ready <= 1'b1;
            result <= {DATA_WIDTH{1'b0}};
            error_flag <= 1'b0;
            error_code <= 8'h0;
            error_valid <= 1'b0;
            exec_counter <= 16'h0;
            pe_idx <= 8'b0;
            pe_iterations <= 8'b0;
            reduce_level <= 3'b0;
            elem_idx <= 16'b0;
            weight_count <= 11'b0;
            weight_loaded <= 1'b0;
            fabric_rd_en <= 1'b0;
            fabric_wr_en <= 1'b0;
            // FIX v2: Reset STORE timeout counter
            store_timeout_counter <= 8'b0;
            complete_timeout_counter <= 8'b0;

            // FIXED: Initialize all 32 PEs (was 0-7 only)
            pe_acc[0] <= 32'sb0; pe_active[0] <= 1'b0;
            pe_acc[1] <= 32'sb0; pe_active[1] <= 1'b0;
            pe_acc[2] <= 32'sb0; pe_active[2] <= 1'b0;
            pe_acc[3] <= 32'sb0; pe_active[3] <= 1'b0;
            pe_acc[4] <= 32'sb0; pe_active[4] <= 1'b0;
            pe_acc[5] <= 32'sb0; pe_active[5] <= 1'b0;
            pe_acc[6] <= 32'sb0; pe_active[6] <= 1'b0;
            pe_acc[7] <= 32'sb0; pe_active[7] <= 1'b0;
            pe_acc[8] <= 32'sb0; pe_active[8] <= 1'b0;
            pe_acc[9] <= 32'sb0; pe_active[9] <= 1'b0;
            pe_acc[10] <= 32'sb0; pe_active[10] <= 1'b0;
            pe_acc[11] <= 32'sb0; pe_active[11] <= 1'b0;
            pe_acc[12] <= 32'sb0; pe_active[12] <= 1'b0;
            pe_acc[13] <= 32'sb0; pe_active[13] <= 1'b0;
            pe_acc[14] <= 32'sb0; pe_active[14] <= 1'b0;
            pe_acc[15] <= 32'sb0; pe_active[15] <= 1'b0;
            pe_acc[16] <= 32'sb0; pe_active[16] <= 1'b0;
            pe_acc[17] <= 32'sb0; pe_active[17] <= 1'b0;
            pe_acc[18] <= 32'sb0; pe_active[18] <= 1'b0;
            pe_acc[19] <= 32'sb0; pe_active[19] <= 1'b0;
            pe_acc[20] <= 32'sb0; pe_active[20] <= 1'b0;
            pe_acc[21] <= 32'sb0; pe_active[21] <= 1'b0;
            pe_acc[22] <= 32'sb0; pe_active[22] <= 1'b0;
            pe_acc[23] <= 32'sb0; pe_active[23] <= 1'b0;
            pe_acc[24] <= 32'sb0; pe_active[24] <= 1'b0;
            pe_acc[25] <= 32'sb0; pe_active[25] <= 1'b0;
            pe_acc[26] <= 32'sb0; pe_active[26] <= 1'b0;
            pe_acc[27] <= 32'sb0; pe_active[27] <= 1'b0;
            pe_acc[28] <= 32'sb0; pe_active[28] <= 1'b0;
            pe_acc[29] <= 32'sb0; pe_active[29] <= 1'b0;
            pe_acc[30] <= 32'sb0; pe_active[30] <= 1'b0;
            pe_acc[31] <= 32'sb0; pe_active[31] <= 1'b0;
        end else begin
            error_valid <= 1'b0;
            complete <= 1'b0;
            cmd_ready <= (state == IDLE);

            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (cmd_valid) begin
                        opcode <= cmd_data[7:0];
                        saved_addr <= cmd_addr;
                        saved_data <= cmd_data;
                        num_elements <= cmd_data[31:8];
                        exec_counter <= 16'h0;
                        pe_idx <= 8'b0;
                        elem_idx <= 16'b0;

                        case (cmd_data[7:0])
                            OP_NOP: begin
                                busy <= 1'b0;
                            end
                            OP_LOAD_W: begin
                                busy <= 1'b1;
                                state <= LOAD_WEIGHT;
                            end
                            OP_INFERENCE, OP_MATMUL: begin
                                if (!weight_loaded && CLUSTER_ID == 0) begin
                                    $display("[%0t] [NPU#%0d] WARNING: No weights loaded", $time, CLUSTER_ID);
                                end
                                busy <= 1'b1;
                                exec_target <= NPU_PIPE_INFERENCE;
                                state <= LOAD_ACT;
                            end
                            OP_CONV: begin
                                busy <= 1'b1;
                                exec_target <= NPU_PIPE_CONV;
                                state <= LOAD_ACT;
                            end
                            OP_POOL: begin
                                busy <= 1'b1;
                                exec_target <= NPU_PIPE_POOL;
                                state <= PRECOMPUTE;
                            end
                            OP_RELU: begin
                                busy <= 1'b1;
                                exec_target <= NPU_PIPE_RELU;
                                state <= ACTIVATE;
                            end
                            OP_SIGMOID: begin
                                busy <= 1'b1;
                                exec_target <= NPU_PIPE_SIGMOID;
                                state <= ACTIVATE;
                            end
                            OP_SOFTMAX: begin
                                busy <= 1'b1;
                                exec_target <= NPU_PIPE_SOFTMAX;
                                state <= PRECOMPUTE;
                            end
                            default: begin
                                error_flag <= 1'b1;
                                error_code <= 8'h01;
                                error_valid <= 1'b1;
                                state <= ERROR_ST;
                            end
                        endcase
                    end
                end

                // ─────────────────────────────────────────────────
                // LOAD_WEIGHT: Load weights from memory
                // CRITICAL FIX #8: Add timeout to prevent permanent hang
                // FIX v2: Limit for loop to min(16, 1024-weight_count)
                // ─────────────────────────────────────────────────
                LOAD_WEIGHT: begin
                    // CRITICAL FIX #8: Timeout after 512 cycles if fabric never responds
                    if (exec_counter >= 16'h200) begin
                        $display("[%0t] [NPU#%0d] ⚠ LOAD_WEIGHT TIMEOUT! Force completion", $time, CLUSTER_ID);
                        error_flag <= 1'b1;
                        error_code <= ERR_NPU_TIMEOUT;
                        error_valid <= 1'b1;
                        elem_idx <= 16'b0;
                        fabric_rd_en <= 1'b0;
                        state <= ERROR_ST;
                    end else begin
                        exec_counter <= exec_counter + 1;
                        if (fabric_rd_en && fabric_ready) begin
                            fabric_rd_en <= 1'b0;
                        end else if (!fabric_rd_en) begin
                            fabric_addr <= saved_addr + {40'b0, elem_idx[5:0]};
                            fabric_rd_en <= 1'b1;
                            exec_counter <= exec_counter + 1;  // Count cycles waiting
                        end

                        if (fabric_ready && fabric_rd_en) begin
                            // FIX v2: Store weights with bounded loop - min(16, 1024-weight_count)
                            for (int w = 0; w < 16; w++) begin
                                // FIXED: Use weight_count+w as index, not weight_count (NBA doesn't update until end of cycle)
                                if ((w < (1024 - weight_count)) && (weight_count + w < 1024)) begin
                                    weight_mem[weight_count + w] <= fabric_rd_data[w*WEIGHT_BITS +: WEIGHT_BITS];
                                end
                            end
                            weight_count <= weight_count + 16;  // FIXED: Increment by 16 for 16 weights

                            elem_idx <= elem_idx + 1;
                            exec_counter <= 16'h0;  // Reset counter on successful transfer

                            if (elem_idx >= (num_elements >> 4) || weight_count >= 1024) begin
                                weight_loaded <= 1'b1;
                                elem_idx <= 16'b0;
                                busy <= 1'b0;
                                fabric_rd_en <= 1'b0;
                                state <= IDLE;
                            end
                        end
                    end
                end

                // ─────────────────────────────────────────────────
                // LOAD_ACT: Load activations
                // CRITICAL FIX #8: Add timeout to prevent permanent hang
                // ─────────────────────────────────────────────────
                LOAD_ACT: begin
                    // CRITICAL FIX #8: Timeout after 512 cycles
                    if (exec_counter >= 16'h200) begin
                        $display("[%0t] [NPU#%0d] ⚠ LOAD_ACT TIMEOUT! Force transition to MAC_COMPUTE", $time, CLUSTER_ID);
                        error_flag <= 1'b1;
                        error_code <= ERR_NPU_TIMEOUT;
                        error_valid <= 1'b1;
                        pe_idx <= 8'b0;
                        fabric_rd_en <= 1'b0;
                        state <= ERROR_ST;
                    end else begin
                        exec_counter <= exec_counter + 1;
                        if (fabric_rd_en && fabric_ready) begin
                            fabric_rd_en <= 1'b0;
                        end else if (!fabric_rd_en) begin
                            fabric_addr <= saved_addr + {40'b0, elem_idx[7:0]};
                            fabric_rd_en <= 1'b1;
                            exec_counter <= exec_counter + 1;  // Count cycles waiting
                        end

                        if (fabric_ready && fabric_rd_en) begin
                            // Load activations into PE buffers
                            for (int p = 0; p < 4; p++) begin
                                if (pe_idx + p < NUM_PE) begin
                                    act_in[pe_idx + p] <= $signed(fabric_rd_data[p*32 +: 32]);
                                end
                            end

                            pe_idx <= pe_idx + 4;
                            elem_idx <= elem_idx + 1;
                            exec_counter <= 16'h0;  // Reset counter on successful transfer

                            if (pe_idx >= NUM_PE - 4) begin
                                pe_idx <= 8'b0;
                                fabric_rd_en <= 1'b0;
                                state <= MAC_COMPUTE;
                            end
                        end
                    end
                end

                // ─────────────────────────────────────────────────
                // PRECOMPUTE: Setup for pooling/softmax
                // ─────────────────────────────────────────────────
                PRECOMPUTE: begin
                    if (exec_counter < exec_target) begin
                        exec_counter <= exec_counter + 1;
                    end else begin
                        state <= ACTIVATE;
                    end
                end

                // ─────────────────────────────────────────────────
                // MAC_COMPUTE: Actual multiply-accumulate
                // FIX v2: Load weights from weight_mem using circular indexing
                // ─────────────────────────────────────────────────
                MAC_COMPUTE: begin
                    if (exec_counter < exec_target) begin
                        exec_counter <= exec_counter + 1;
                    end else begin
                        // Load weights into PE registers from weight_mem with circular indexing
                        for (int p = 0; p < NUM_PE; p++) begin
                            pe_weights[p] <= weight_mem[(pe_idx + p) % 1024];
                        end

                        // Parallel MAC across all PEs
                        for (int p = 0; p < NUM_PE; p++) begin
                            if (weight_loaded && pe_idx < weight_count) begin
                                // Sparsity optimization: skip zero weights
                                if (!is_sparse(weight_mem[(pe_idx + p) % 1024])) begin
                                    pe_acc[p] <= pe_acc[p] + (weight_mem[(pe_idx + p) % 1024] * act_in[p]);
                                end
                            end else begin
                                pe_acc[p] <= 32'sb0;
                            end
                        end

                        pe_idx <= pe_idx + NUM_PE;
                        pe_iterations <= pe_iterations + 8'd1;

                        // Guard against pe_idx wrap (8-bit, max 255, NUM_PE=32)
                        if (pe_idx >= num_elements || pe_iterations > 8'd15) begin
                            state <= ACCUMULATE;
                        end
                    end
                end

                // ─────────────────────────────────────────────────
                // ACCUMULATE: Single-cycle reduction
                // FIXED: Multi-level tree had NBA race — only last level took effect
                // ─────────────────────────────────────────────────
                ACCUMULATE: begin
                    if (reduce_level == 0) begin
                        integer total;
                        total = 0;
                        for (int p = 0; p < NUM_PE; p++) begin
                            total = total + pe_acc[p];
                        end
                        pe_acc[0] <= total;
                        reduce_level <= 1;
                    end else begin
                        act_out[0] <= pe_acc[0];
                        reduce_level <= 3'b0;
                        state <= ACTIVATE;
                    end
                end

                // ─────────────────────────────────────────────────
                // ACTIVATE: Apply activation function
                // CRITICAL FIX: Use pe_acc[0] (the reduced sum from ACCUMULATE state)
                // instead of per-PE pe_acc[p] values. After multi-level tree reduction
                // in ACCUMULATE, only pe_acc[0] contains the final sum; pe_acc[1:31]
                // retain their pre-reduction partial accumulators and must not be used.
                // ─────────────────────────────────────────────────
                ACTIVATE: begin
                    if (exec_counter < exec_target) begin
                        exec_counter <= exec_counter + 1;
                    end else begin
                        case (opcode)
                            OP_RELU: begin
                                // ReLU: max(0, reduced_sum)
                                if (pe_acc[0] > 0)
                                    act_out[0] <= pe_acc[0];
                                else
                                    act_out[0] <= 32'sb0;
                            end
                            OP_SIGMOID: begin
                                // Sigmoid approximation: 1 / (1 + exp(-x))
                                if (pe_acc[0] > 32'sd64)
                                    act_out[0] <= 32'sd128;  // ~1.0 in Q7.8
                                else if (pe_acc[0] < -32'sd64)
                                    act_out[0] <= 32'sb0;    // ~0.0
                                else
                                    act_out[0] <= 32'sd64 + (pe_acc[0] >> 1);  // Linear approx
                            end
                            OP_SOFTMAX: begin
                                act_out[0] <= pe_acc[0];
                            end
                            OP_POOL: begin
                                act_out[0] <= pe_acc[0];
                            end
                            default: begin
                                act_out[0] <= pe_acc[0];
                            end
                        endcase

                        state <= STORE;
                    end
                end

                // ─────────────────────────────────────────────────
                // STORE: Write result to memory
                // FIX v2: Added timeout counter (50 cycles) to prevent hang
                // ─────────────────────────────────────────────────
                STORE: begin
                    // FIX v2: Timeout counter to detect stuck fabric
                    if (fabric_wr_en && !fabric_ready) begin
                        store_timeout_counter <= store_timeout_counter + 1;
                    end else begin
                        store_timeout_counter <= 8'b0;
                    end

                    // FIX v2: If timeout exceeded, trigger error instead of hanging
                    if (store_timeout_counter >= 8'd50) begin
                        if (CLUSTER_ID == 0)
                            $display("[%0t] [NPU#%0d] STORE TIMEOUT after 50 cycles, triggering error", $time, CLUSTER_ID);
                        error_flag <= 1'b1;
                        error_code <= ERR_STORE_TIMEOUT;
                        error_valid <= 1'b1;
                        busy <= 1'b0;
                        fabric_wr_en <= 1'b0;
                        state <= ERROR_ST;
                    end else if (fabric_wr_en && fabric_ready) begin
                        fabric_wr_en <= 1'b0;
                    end else begin
                        fabric_wr_data <= {{(DATA_WIDTH-32){1'b0}}, act_out[0]};
                        fabric_wr_en <= 1'b1;
                    end

                    if (fabric_ready && fabric_wr_en) begin
                        result <= {{(DATA_WIDTH-32){1'b0}}, act_out[0]};
                        complete <= 1'b1;
                        busy <= 1'b0;
                        store_timeout_counter <= 8'b0;
                        state <= COMPLETE_ST;
                    end
                end

                COMPLETE_ST: begin
                    // CRITICAL FIX NEW-1: Add 25-cycle timeout to prevent permanent stall
                    // If scheduler holds cmd_valid high, NPU will timeout and return to IDLE
                    if (complete_timeout_counter >= 8'd25) begin  // Reduced timeout for faster recovery
                        if (CLUSTER_ID == 0)
                            $display("[%0t] [NPU#%0d] COMPLETE_ST TIMEOUT: cmd_valid still high after 25 cycles", $time, CLUSTER_ID);
                        complete_timeout_counter <= 8'b0;
                        complete <= 1'b0;  // Clear complete flag
                        busy <= 1'b0;      // Clear busy flag
                        state <= IDLE;
                    end else if (cmd_valid == 1'b0) begin
                        complete_timeout_counter <= 8'b0;
                        state <= IDLE;
                    end else begin
                        complete_timeout_counter <= complete_timeout_counter + 1;
                    end
                end

                ERROR_ST: begin
                    busy <= 1'b0;
                    error_flag <= 1'b0;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
