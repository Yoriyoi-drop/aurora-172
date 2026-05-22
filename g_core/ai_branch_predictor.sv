`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: AI Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 AI Branch Predictor
// Module Name: ai_branch_predictor
//
// Description:
//   Advanced AI-based Branch Predictor untuk G-Core
//   Fitur:
//   - 2-level adaptive predictor dengan neural network sederhana
//   - Pattern history table (PHT) dengan 1024 entries
//   - Branch target buffer (BTB) untuk address prediction
//   - Return address stack (RAS) untuk function calls
//   - Global/local history correlation
//
// Target: >95% prediction accuracy untuk gaming workloads
//////////////////////////////////////////////////////////////////////////////////

module ai_branch_predictor #(
    parameter PHT_BITS      = 10,       // 1024 entries
    parameter HISTORY_LEN   = 16,       // Global history length
    parameter BTB_SIZE      = 256,      // Branch target buffer size
    parameter RAS_SIZE      = 16,       // Return address stack depth
    parameter WEIGHT_BITS   = 8         // Neural network weight precision
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Branch instruction info
    input  wire [47:0]                  branch_pc,
    input  wire                         branch_is_call,
    input  wire                         branch_is_return,
    input  wire                         branch_is_indirect,

    // Actual outcome (for training)
    input  wire                         branch_taken_actual,
    input  wire [47:0]                  branch_target_actual,

    // Prediction output
    output reg                          prediction_taken,
    output reg [47:0]                   prediction_target,

    // Training signal
    input  wire                         train_enable,

    // Statistics
    output reg [31:0]                   total_branches,
    output reg [31:0]                   correct_predictions,
    output wire [7:0]                   prediction_accuracy
);

    // =========================================================================
    // Pattern History Table (PHT) - Neural network weights
    // =========================================================================
    // FIX v2: PHT now has HISTORY_LEN weights per entry instead of a single weight.
    // Changed from: reg signed [WEIGHT_BITS-1:0] pht [0:(1<<PHT_BITS)-1];
    reg signed [WEIGHT_BITS-1:0] pht [0:(1<<PHT_BITS)-1][0:HISTORY_LEN-1];

    // Global history register
    reg [HISTORY_LEN-1:0] global_history;

    // Local history per branch
    reg [HISTORY_LEN-1:0] local_history [0:255];

    // =========================================================================
    // Branch Target Buffer (BTB) - 2-WAY SET ASSOCIATIVE
    // =========================================================================
    reg [47:0]          btb_target [0:BTB_SIZE-1][0:1];  // 2-way
    reg                 btb_valid [0:BTB_SIZE-1][0:1];
    reg [15:0]          btb_tag [0:BTB_SIZE-1][0:1];     // Full PC[15:0] tag
    reg [7:0]           btb_lru [0:BTB_SIZE-1];          // LRU per set

    wire [7:0] btb_set_index;
    assign btb_set_index = branch_pc[9:2];  // Use bits 9:2 for set indexing

    // =========================================================================
    // Return Address Stack (RAS)
    // =========================================================================
    reg [47:0]          ras [0:RAS_SIZE-1];
    reg [3:0]           ras_top_ptr;  // Points to next free entry

    // =========================================================================
    // Index calculation
    // =========================================================================
    wire [PHT_BITS-1:0] pht_index;
    assign pht_index = branch_pc[PHT_BITS-1:0] ^ global_history ^ local_history[branch_pc[7:0]];

    wire [7:0] btb_index;
    assign btb_index = branch_pc[7:0];

    // =========================================================================
    // Prediction logic with 2-WAY BTB
    // =========================================================================
    always @(*) begin
        // Default: not taken, next instruction
        prediction_taken = 1'b0;
        prediction_target = branch_pc + 4;

        // Check BTB first - 2-WAY SET ASSOCIATIVE
        begin
            integer way;
            reg [7:0] set_idx;

            set_idx = branch_pc[9:2];

            for (way = 0; way < 2; way = way + 1) begin
                if (btb_valid[set_idx][way] && btb_tag[set_idx][way] == branch_pc[15:0]) begin
                    // BTB HIT - proper tag match
                    prediction_target = btb_target[set_idx][way];
                    prediction_taken = 1'b1;
                end
            end
        end

        // Handle return instructions specially
        if (branch_is_return && ras_top_ptr > 0) begin
            prediction_taken = 1'b1;
            prediction_target = ras[ras_top_ptr - 1];
        end

        // Neural network prediction (if no BTB hit)
        if (!prediction_taken) begin
            // Sum weighted history
            integer sum;
            integer i;
            sum = 0;
            for (i = 0; i < HISTORY_LEN; i = i + 1) begin
                if (global_history[i]) begin
                    // FIX v2: Use pht[pht_index][i] instead of pht[pht_index][i % WEIGHT_BITS]
                    sum = sum + pht[pht_index][i];
                end else begin
                    // FIX v2: Use pht[pht_index][i] instead of pht[pht_index][i % WEIGHT_BITS]
                    sum = sum - pht[pht_index][i];
                end
            end

            // Threshold decision
            prediction_taken = (sum > 0) ? 1'b1 : 1'b0;
        end
    end

    // =========================================================================
    // Training/Update logic
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all weights to zero - OPTIMIZED: Use single loop for faster reset
            for (int i = 0; i < (1<<PHT_BITS) * HISTORY_LEN; i++) begin
                pht[i>>4][i&15] <= {WEIGHT_BITS{1'b0}};
            end

            global_history <= {HISTORY_LEN{1'b0}};
            ras_top_ptr <= 4'b0;
            total_branches <= 32'b0;
            correct_predictions <= 32'b0;

            // FIX v2: Reset BTB as 2-way set associative
            for (int i = 0; i < BTB_SIZE; i++) begin
                btb_valid[i][0] <= 1'b0;
                btb_valid[i][1] <= 1'b0;
            end
        end else begin
            // Update statistics (only when training/processing an actual branch)
            if (train_enable) begin
                total_branches <= total_branches + 1;
                if (prediction_taken == branch_taken_actual) begin
                    correct_predictions <= correct_predictions + 1;
                end
            end

            // Training mode: update weights
            if (train_enable) begin
                // Perceptron learning rule
                if ((branch_taken_actual && prediction_taken == 1'b0) ||
                    (!branch_taken_actual && prediction_taken == 1'b1)) begin
                    // Misprediction: update weights with saturation
                    integer sign;
                    integer i;
                    logic signed [WEIGHT_BITS-1:0] new_weight;
                    sign = branch_taken_actual ? 1 : -1;

                    for (i = 0; i < HISTORY_LEN; i = i + 1) begin
                        if (global_history[i]) begin
                            // FIX v2: Use pht[pht_index][i] instead of pht[pht_index][i % WEIGHT_BITS]
                            new_weight = pht[pht_index][i] + sign;
                        end else begin
                            // FIX v2: Use pht[pht_index][i] instead of pht[pht_index][i % WEIGHT_BITS]
                            new_weight = pht[pht_index][i] - sign;
                        end

                        // FIX v2: Saturate to prevent overflow/underflow
                        if (new_weight > ((1 << (WEIGHT_BITS-1)) - 1))
                            new_weight = (1 << (WEIGHT_BITS-1)) - 1;
                        else if (new_weight < -((1 << (WEIGHT_BITS-1)) - 1))
                            new_weight = -((1 << (WEIGHT_BITS-1)) - 1);

                        // FIX v2: Use pht[pht_index][i] instead of pht[pht_index][i % WEIGHT_BITS]
                        pht[pht_index][i] <= new_weight;
                    end
                end

                // Update global history
                global_history <= {global_history[HISTORY_LEN-2:0], branch_taken_actual};

                // Update local history
                local_history[branch_pc[7:0]] <= {local_history[branch_pc[7:0]][HISTORY_LEN-2:0], branch_taken_actual};

                // FIX v2: BTB update uses proper 2-way set associative logic.
                // Use btb_set_index (PC[9:2]) to find the set, then find a valid way
                // with matching tag, or use LRU way if the set is full.
                if (branch_taken_actual) begin
                    reg [7:0] btb_set;
                    integer way;
                    integer lru_way;
                    reg found;

                    btb_set = btb_set_index;
                    found = 1'b0;

                    // First: look for an existing matching entry (tag hit)
                    for (way = 0; way < 2; way = way + 1) begin
                        if (btb_valid[btb_set][way] && btb_tag[btb_set][way] == branch_pc[15:0]) begin
                            btb_target[btb_set][way] <= branch_target_actual;
                            btb_lru[btb_set] <= way[7:0];  // Update LRU
                            found = 1'b1;
                        end
                    end

                    // If no tag match, find an invalid way or use LRU
                    if (!found) begin
                        lru_way = btb_lru[btb_set];
                        // Try to find an invalid way first
                        for (way = 0; way < 2; way = way + 1) begin
                            if (!btb_valid[btb_set][way]) begin
                                lru_way = way;
                                found = 1'b1;
                            end
                        end
                        // If all valid, use LRU way
                        if (!found) begin
                            lru_way = btb_lru[btb_set];
                        end

                        btb_target[btb_set][lru_way] <= branch_target_actual;
                        btb_valid[btb_set][lru_way]  <= 1'b1;
                        btb_tag[btb_set][lru_way]    <= branch_pc[15:0];
                        btb_lru[btb_set] <= {7'b0, ~lru_way[0]};  // Toggle LRU (2-bit for 2-way)
                    end
                end

                // Handle call instructions - push to RAS
                if (branch_is_call) begin
                    ras[ras_top_ptr] <= branch_pc + 4;
                    if (ras_top_ptr < RAS_SIZE - 1) begin
                        ras_top_ptr <= ras_top_ptr + 1;
                    end
                end

                // Handle return instructions - pop from RAS
                if (branch_is_return && ras_top_ptr > 0) begin
                    ras_top_ptr <= ras_top_ptr - 1;
                end
            end
        end
    end

    // =========================================================================
    // Accuracy calculation
    // =========================================================================
    function [7:0] calc_accuracy;
        reg [31:0] temp_result;
        begin
            if (total_branches == 0) begin
                calc_accuracy = 8'd0;
            end else begin
                // FIX: Prevent overflow in multiplication
                temp_result = (correct_predictions * 255) / total_branches;
                // FIX: Clamp to 8-bit range
                calc_accuracy = (temp_result > 255) ? 8'd255 : temp_result[7:0];
            end
        end
    endfunction

    // Variable to store calculated accuracy
    reg [7:0] calc_accuracy_result;
    
    // Always calculate accuracy when inputs change
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            calc_accuracy_result <= 8'd0;
        end else begin
            calc_accuracy_result <= calc_accuracy();
        end
    end

    assign prediction_accuracy = calc_accuracy_result;

endmodule
