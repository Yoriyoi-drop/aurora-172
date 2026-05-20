`timescale 1ns / 1ps

// Import global package for parameters
`include "interfaces/aurora_params.svh"
import aurora_global_pkg::*;

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team
//
// Create Date: 17 April 2026
// Design Name: Timing Drift Management
// Module Name: timing_manager
//
// Description:
//   TIMING DRIFT MANAGEMENT AND SYNCHRONIZATION SYSTEM
//   
//   Features:
//   - Clock domain crossing protection
//   - Stable handshake protocols
//   - Deterministic timing path management
//   - Timing drift detection and correction
//   - Synchronization across multiple clock domains
//   - Metastability detection and prevention
//////////////////////////////////////////////////////////////////////////////////

module timing_manager #(
    parameter NUM_NODES = 4,        // OPTIMIZED: 8->4 (fewer nodes)
    parameter BUFFER_DEPTH = 8,    // OPTIMIZED: 16->8 (smaller buffers)
    parameter DATA_WIDTH = AURORA_DATA_WIDTH,     // From package
    parameter ADDR_WIDTH = AURORA_ADDR_WIDTH,     // From package
    parameter CLOCK_DOMAINS = 2,   // OPTIMIZED: 3->2 (fewer domains)
    parameter SYNC_STAGES = 2,     // FIXED: was 1 (minimum for CDC is 2 stages)
    parameter DRIFT_THRESHOLD = 50  // OPTIMIZED: 100->50 (earlier detection)
)(
    input wire                     clk,
    input wire                     rst_n,
    
    // Multiple clock domains for different subsystems
    input wire                     core_clk,           // Core processing clock
    input wire                     interconnect_clk,   // Interconnect clock
    input wire                     memory_clk,         // Memory system clock
    
    // Clock domain crossing signals
    input wire [DATA_WIDTH-1:0]    core_to_ic_data    [0:NUM_NODES-1],
    input wire                     core_to_ic_valid   [0:NUM_NODES-1],
    output wire                    core_to_ic_ready   [0:NUM_NODES-1],
    
    output wire [DATA_WIDTH-1:0]    ic_to_core_data    [0:NUM_NODES-1],
    output wire                    ic_to_core_valid   [0:NUM_NODES-1],
    input wire                     ic_to_core_ready   [0:NUM_NODES-1],
    
    input wire [ADDR_WIDTH-1:0]    ic_to_mem_addr    [0:NUM_NODES-1],
    input wire [DATA_WIDTH-1:0]    ic_to_mem_data    [0:NUM_NODES-1],
    input wire                     ic_to_mem_valid   [0:NUM_NODES-1],
    output wire                    ic_to_mem_ready   [0:NUM_NODES-1],
    
    output wire [DATA_WIDTH-1:0]    mem_to_ic_data    [0:NUM_NODES-1],
    output wire                    mem_to_ic_valid   [0:NUM_NODES-1],
    input wire                     mem_to_ic_ready   [0:NUM_NODES-1],
    
    // Timing drift detection outputs
    output wire [31:0]             timing_drift_detected,
    output wire [31:0]             metastability_events,
    output wire [31:0]             synchronization_errors,
    output wire [7:0]              timing_health_score,
    output wire                    timing_system_healthy,
    
    // Timing metrics
    output wire [31:0]             avg_setup_time,
    output wire [31:0]             avg_hold_time,
    output wire [31:0]             max_skew_detected,
    output wire [31:0]             clock_jitter_measured,
    
    // Control and monitoring
    output wire [31:0]             domain_crossing_count,
    output wire [31:0]             resynchronization_count,
    output wire [31:0]             timing_correction_count
);

    // Timing states and synchronization
    localparam SYNC_IDLE = 2'b00;
    localparam SYNC_CAPTURE = 2'b01;
    localparam SYNC_TRANSFER = 2'b10;
    localparam SYNC_COMPLETE = 2'b11;
    
    // Clock domain crossing registers
    reg [DATA_WIDTH-1:0]    core_to_ic_sync [0:NUM_NODES-1][0:SYNC_STAGES-1];
    reg                     core_to_ic_valid_sync [0:NUM_NODES-1][0:SYNC_STAGES-1];
    reg [DATA_WIDTH-1:0]    ic_to_core_sync [0:NUM_NODES-1][0:SYNC_STAGES-1];
    reg                     ic_to_core_valid_sync [0:NUM_NODES-1][0:SYNC_STAGES-1];
    reg [DATA_WIDTH-1:0]    ic_to_mem_sync [0:NUM_NODES-1][0:SYNC_STAGES-1];
    reg                     ic_to_mem_valid_sync [0:NUM_NODES-1][0:SYNC_STAGES-1];
    reg [DATA_WIDTH-1:0]    mem_to_ic_sync [0:NUM_NODES-1][0:SYNC_STAGES-1];
    reg                     mem_to_ic_valid_sync [0:NUM_NODES-1][0:SYNC_STAGES-1];
    
    // Synchronization state machines
    reg [1:0]               core_to_ic_state [0:NUM_NODES-1];
    reg [1:0]               ic_to_core_state [0:NUM_NODES-1];
    reg [1:0]               ic_to_mem_state [0:NUM_NODES-1];
    reg [1:0]               mem_to_ic_state [0:NUM_NODES-1];
    
    // Timing drift detection
    reg [31:0]              core_timestamp [0:NUM_NODES-1];
    reg [31:0]              ic_timestamp [0:NUM_NODES-1];
    reg [31:0]              mem_timestamp [0:NUM_NODES-1];
    reg [31:0]              last_sync_time [0:NUM_NODES-1];
    reg [31:0]              timing_drift [0:NUM_NODES-1];
    reg [31:0]              max_drift_seen;
    reg [31:0]              drift_accumulator;
    
    // Metastability detection
    reg [31:0]              metastability_count;
    reg [31:0]              metastability_history [0:255]; // Circular buffer
    reg [7:0]               metastability_pointer;
    reg                     metastability_detected;
    
    // Clock skew and jitter measurement
    reg [31:0]              clock_edge_time [0:CLOCK_DOMAINS-1];
    reg [31:0]              period_measurement [0:CLOCK_DOMAINS-1];
    reg [31:0]              jitter_accumulator [0:CLOCK_DOMAINS-1];
    reg [31:0]              max_jitter_seen [0:CLOCK_DOMAINS-1];
    reg [31:0]              skew_between_domains [0:CLOCK_DOMAINS-1][0:CLOCK_DOMAINS-1];
    
    // Timing health metrics
    reg [31:0]              setup_time_samples [0:NUM_NODES-1];
    reg [31:0]              hold_time_samples [0:NUM_NODES-1];
    reg [31:0]              total_setup_time;
    reg [31:0]              total_hold_time;
    reg [31:0]              max_skew_measurement;
    reg [31:0]              total_jitter_measurement;
    reg [7:0]               timing_health;
    reg                     timing_healthy;
    
    // Synchronization counters
    reg [31:0]              domain_crossings;
    reg [31:0]              resynchronizations;
    reg [31:0]              timing_corrections;
    reg [31:0]              sync_errors;
    
    // Clock domain crossing control
    reg                     enable_crossing;
    reg [7:0]               sync_threshold;
    reg [31:0]              sync_timeout;
    
    // Initialize timing manager
    integer init_i, init_j, init_k;
    initial begin
        // Initialize synchronization registers
        for (init_i = 0; init_i < NUM_NODES; init_i = init_i + 1) begin
            for (init_j = 0; init_j < SYNC_STAGES; init_j = init_j + 1) begin
                core_to_ic_sync[init_i][init_j] = {DATA_WIDTH{1'b0}};
                core_to_ic_valid_sync[init_i][init_j] = 1'b0;
                ic_to_core_sync[init_i][init_j] = {DATA_WIDTH{1'b0}};
                ic_to_core_valid_sync[init_i][init_j] = 1'b0;
                ic_to_mem_sync[init_i][init_j] = {DATA_WIDTH{1'b0}};
                ic_to_mem_valid_sync[init_i][init_j] = 1'b0;
                mem_to_ic_sync[init_i][init_j] = {DATA_WIDTH{1'b0}};
                mem_to_ic_valid_sync[init_i][init_j] = 1'b0;
            end
            
            // Initialize state machines
            core_to_ic_state[init_i] = SYNC_IDLE;
            ic_to_core_state[init_i] = SYNC_IDLE;
            ic_to_mem_state[init_i] = SYNC_IDLE;
            mem_to_ic_state[init_i] = SYNC_IDLE;
            
            // Initialize timing tracking
            core_timestamp[init_i] = 32'd0;
            ic_timestamp[init_i] = 32'd0;
            mem_timestamp[init_i] = 32'd0;
            last_sync_time[init_i] = 32'd0;
            timing_drift[init_i] = 32'd0;
            
            // Initialize timing metrics
            setup_time_samples[init_i] = 32'd0;
            hold_time_samples[init_i] = 32'd0;
        end
        
        // Initialize global timing state
        max_drift_seen = 32'd0;
        drift_accumulator = 32'd0;
        metastability_count = 32'd0;
        metastability_pointer = 8'd0;
        metastability_detected = 1'b0;
        
        // Initialize clock measurements
        for (init_i = 0; init_i < CLOCK_DOMAINS; init_i = init_i + 1) begin
            clock_edge_time[init_i] = 32'd0;
            period_measurement[init_i] = 32'd0;
            jitter_accumulator[init_i] = 32'd0;
            max_jitter_seen[init_i] = 32'd0;
            
            for (init_j = 0; init_j < CLOCK_DOMAINS; init_j = init_j + 1) begin
                skew_between_domains[init_i][init_j] = 32'd0;
            end
        end
        
        // Initialize health metrics
        total_setup_time = 32'd0;
        total_hold_time = 32'd0;
        max_skew_measurement = 32'd0;
        total_jitter_measurement = 32'd0;
        timing_health = 8'd100;
        timing_healthy = 1'b1;
        
        // Initialize counters
        domain_crossings = 32'd0;
        resynchronizations = 32'd0;
        timing_corrections = 32'd0;
        sync_errors = 32'd0;
        
        // Initialize control
        enable_crossing = 1'b1;
        sync_threshold = 8'd5;
        sync_timeout = 32'd1000;
        
        // Initialize metastability history
        for (init_i = 0; init_i < 256; init_i = init_i + 1) begin
            metastability_history[init_i] = 32'd0;
        end
        
        $display("[%0t] [TIMING-MANAGER] Timing Drift Management System Initialized", $time);
    end
    
    // Core clock domain processing
    always @(posedge core_clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset core domain state
            for (integer i = 0; i < NUM_NODES; i = i + 1) begin
                core_timestamp[i] = 32'd0;
                core_to_ic_state[i] = SYNC_IDLE;
                for (integer j = 0; j < SYNC_STAGES; j = j + 1) begin
                    core_to_ic_sync[i][j] = {DATA_WIDTH{1'b0}};
                    core_to_ic_valid_sync[i][j] = 1'b0;
                end
            end
        end else begin
            // Update core timestamp
            for (integer i = 0; i < NUM_NODES; i = i + 1) begin
                core_timestamp[i] = core_timestamp[i] + 1;
                
                // Process clock domain crossing to interconnect
                process_core_to_ic_crossing(i);
            end
        end
    end
    
    // Interconnect clock domain processing
    always @(posedge interconnect_clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset interconnect domain state
            for (integer i = 0; i < NUM_NODES; i = i + 1) begin
                ic_timestamp[i] = 32'd0;
                ic_to_core_state[i] = SYNC_IDLE;
                ic_to_mem_state[i] = SYNC_IDLE;
                for (integer j = 0; j < SYNC_STAGES; j = j + 1) begin
                    ic_to_core_sync[i][j] = {DATA_WIDTH{1'b0}};
                    ic_to_core_valid_sync[i][j] = 1'b0;
                    ic_to_mem_sync[i][j] = {DATA_WIDTH{1'b0}};
                    ic_to_mem_valid_sync[i][j] = 1'b0;
                end
            end
        end else begin
            // Update interconnect timestamp
            for (integer i = 0; i < NUM_NODES; i = i + 1) begin
                ic_timestamp[i] = ic_timestamp[i] + 1;
                
                // Process clock domain crossing from core
                process_ic_from_core_crossing(i);
                
                // Process clock domain crossing to core
                process_ic_to_core_crossing(i);
                
                // Process clock domain crossing to memory
                process_ic_to_mem_crossing(i);
                
                // Process clock domain crossing from memory
                process_ic_from_mem_crossing(i);
                
                // Check timing drift
                check_timing_drift(i);
            end
        end
    end
    
    // Memory clock domain processing
    always @(posedge memory_clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset memory domain state
            for (integer i = 0; i < NUM_NODES; i = i + 1) begin
                mem_timestamp[i] = 32'd0;
                mem_to_ic_state[i] = SYNC_IDLE;
                for (integer j = 0; j < SYNC_STAGES; j = j + 1) begin
                    mem_to_ic_sync[i][j] = {DATA_WIDTH{1'b0}};
                    mem_to_ic_valid_sync[i][j] = 1'b0;
                end
            end
        end else begin
            // Update memory timestamp
            for (integer i = 0; i < NUM_NODES; i = i + 1) begin
                mem_timestamp[i] = mem_timestamp[i] + 1;
                
                // Process clock domain crossing from interconnect
                process_mem_from_ic_crossing(i);
            end
        end
    end
    
    // Task: Process core to interconnect crossing
    task process_core_to_ic_crossing;
        input integer node;
        begin
            case (core_to_ic_state[node])
                SYNC_IDLE: begin
                    if (core_to_ic_valid[node] && enable_crossing) begin
                        core_to_ic_state[node] = SYNC_CAPTURE;
                        core_to_ic_sync[node][0] = core_to_ic_data[node];
                        core_to_ic_valid_sync[node][0] = core_to_ic_valid[node];
                        domain_crossings = domain_crossings + 1;
                    end
                end
                
                SYNC_CAPTURE: begin
                    // First synchronization stage
                    core_to_ic_sync[node][1] = core_to_ic_sync[node][0];
                    core_to_ic_valid_sync[node][1] = core_to_ic_valid_sync[node][0];
                    core_to_ic_state[node] = SYNC_TRANSFER;
                end
                
                SYNC_TRANSFER: begin
                    // Check for metastability
                    if (detect_metastability(core_to_ic_sync[node][1], core_to_ic_sync[node][0])) begin
                        metastability_count = metastability_count + 1;
                        metastability_detected = 1'b1;
                        log_metastability(node, 0, core_to_ic_sync[node][1], core_to_ic_sync[node][0]);
                        core_to_ic_state[node] = SYNC_IDLE; // Reset on error
                    end else begin
                        core_to_ic_state[node] = SYNC_COMPLETE;
                    end
                end
                
                SYNC_COMPLETE: begin
                    // Transfer complete, ready for next
                    core_to_ic_state[node] = SYNC_IDLE;
                end
            endcase
        end
    endtask
    
    // Task: Process interconnect from core crossing
    task process_ic_from_core_crossing;
        input integer node;
        begin
            // Receive synchronized data from core domain
            if (core_to_ic_valid_sync[node][SYNC_STAGES-1]) begin
                // Data is ready for processing in interconnect domain
                // Additional timing checks can be performed here
                last_sync_time[node] = ic_timestamp[node];
            end
        end
    endtask
    
    // Task: Process interconnect to core crossing
    task process_ic_to_core_crossing;
        input integer node;
        begin
            case (ic_to_core_state[node])
                SYNC_IDLE: begin
                    if (ic_to_core_valid[node] && enable_crossing) begin
                        ic_to_core_state[node] = SYNC_CAPTURE;
                        ic_to_core_sync[node][0] = ic_to_core_data[node];
                        ic_to_core_valid_sync[node][0] = ic_to_core_valid[node];
                        domain_crossings = domain_crossings + 1;
                    end
                end
                
                SYNC_CAPTURE: begin
                    ic_to_core_sync[node][1] = ic_to_core_sync[node][0];
                    ic_to_core_valid_sync[node][1] = ic_to_core_valid_sync[node][0];
                    ic_to_core_state[node] = SYNC_TRANSFER;
                end
                
                SYNC_TRANSFER: begin
                    if (detect_metastability(ic_to_core_sync[node][1], ic_to_core_sync[node][0])) begin
                        metastability_count = metastability_count + 1;
                        metastability_detected = 1'b1;
                        log_metastability(node, 1, ic_to_core_sync[node][1], ic_to_core_sync[node][0]);
                        ic_to_core_state[node] = SYNC_IDLE;
                    end else begin
                        ic_to_core_state[node] = SYNC_COMPLETE;
                    end
                end
                
                SYNC_COMPLETE: begin
                    ic_to_core_state[node] = SYNC_IDLE;
                end
            endcase
        end
    endtask
    
    // Task: Process interconnect to memory crossing
    task process_ic_to_mem_crossing;
        input integer node;
        begin
            case (ic_to_mem_state[node])
                SYNC_IDLE: begin
                    if (ic_to_mem_valid[node] && enable_crossing) begin
                        ic_to_mem_state[node] = SYNC_CAPTURE;
                        ic_to_mem_sync[node][0] = ic_to_mem_data[node];
                        ic_to_mem_valid_sync[node][0] = ic_to_mem_valid[node];
                        domain_crossings = domain_crossings + 1;
                    end
                end
                
                SYNC_CAPTURE: begin
                    ic_to_mem_sync[node][1] = ic_to_mem_sync[node][0];
                    ic_to_mem_valid_sync[node][1] = ic_to_mem_valid_sync[node][0];
                    ic_to_mem_state[node] = SYNC_TRANSFER;
                end
                
                SYNC_TRANSFER: begin
                    if (detect_metastability(ic_to_mem_sync[node][1], ic_to_mem_sync[node][0])) begin
                        metastability_count = metastability_count + 1;
                        metastability_detected = 1'b1;
                        log_metastability(node, 2, ic_to_mem_sync[node][1], ic_to_mem_sync[node][0]);
                        ic_to_mem_state[node] = SYNC_IDLE;
                    end else begin
                        ic_to_mem_state[node] = SYNC_COMPLETE;
                    end
                end
                
                SYNC_COMPLETE: begin
                    ic_to_mem_state[node] = SYNC_IDLE;
                end
            endcase
        end
    endtask
    
    // Task: Process interconnect from memory crossing
    task process_ic_from_mem_crossing;
        input integer node;
        begin
            // Receive synchronized data from memory domain
            if (mem_to_ic_state[node] == SYNC_COMPLETE) begin
                // Data is ready for processing in interconnect domain
                last_sync_time[node] = ic_timestamp[node];
            end
        end
    endtask
    
    // Task: Process memory from interconnect crossing
    task process_mem_from_ic_crossing;
        input integer node;
        begin
            case (mem_to_ic_state[node])
                SYNC_IDLE: begin
                    if (mem_to_ic_valid[node] && enable_crossing) begin
                        mem_to_ic_state[node] = SYNC_CAPTURE;
                        mem_to_ic_sync[node][0] = mem_to_ic_data[node];
                        mem_to_ic_valid_sync[node][0] = mem_to_ic_valid[node];
                        domain_crossings = domain_crossings + 1;
                    end
                end
                
                SYNC_CAPTURE: begin
                    mem_to_ic_sync[node][1] = mem_to_ic_sync[node][0];
                    mem_to_ic_valid_sync[node][1] = mem_to_ic_valid_sync[node][0];
                    mem_to_ic_state[node] = SYNC_TRANSFER;
                end
                
                SYNC_TRANSFER: begin
                    if (detect_metastability(mem_to_ic_sync[node][1], mem_to_ic_sync[node][0])) begin
                        metastability_count = metastability_count + 1;
                        metastability_detected = 1'b1;
                        log_metastability(node, 3, mem_to_ic_sync[node][1], mem_to_ic_sync[node][0]);
                        mem_to_ic_state[node] = SYNC_IDLE;
                    end else begin
                        mem_to_ic_state[node] = SYNC_COMPLETE;
                    end
                end
                
                SYNC_COMPLETE: begin
                    mem_to_ic_state[node] = SYNC_IDLE;
                end
            endcase
        end
    endtask
    
    // Task: Check timing drift
    task check_timing_drift;
        input integer node;
        reg [31:0] core_time, ic_time, mem_time;
        reg [31:0] max_diff, min_diff;
        begin
            core_time = core_timestamp[node];
            ic_time = ic_timestamp[node];
            mem_time = mem_timestamp[node];
            
            // Calculate drift between domains
            timing_drift[node] = calculate_drift(core_time, ic_time);
            
            // Update maximum drift seen
            if (timing_drift[node] > max_drift_seen) begin
                max_drift_seen = timing_drift[node];
            end
            
            // Accumulate drift for health scoring
            drift_accumulator = drift_accumulator + timing_drift[node];
            
            // Check if drift exceeds threshold
            if (timing_drift[node] > DRIFT_THRESHOLD) begin
                // Trigger resynchronization
                perform_resynchronization(node);
                sync_errors = sync_errors + 1;
            end
        end
    endtask
    
    // Function: Calculate drift between timestamps
    function automatic [31:0] calculate_drift;
        input [31:0] time1;
        input [31:0] time2;
        reg [31:0] diff;
        begin
            if (time1 > time2) begin
                diff = time1 - time2;
            end else begin
                diff = time2 - time1;
            end
            calculate_drift = diff;
        end
    endfunction
    
    // Function: Detect metastability
    function automatic bit detect_metastability;
        input [DATA_WIDTH-1:0] data1;
        input [DATA_WIDTH-1:0] data2;
        reg [DATA_WIDTH-1:0] xor_result;
        integer bit_count;
        begin
            xor_result = data1 ^ data2;
            bit_count = 0;
            
            // Count differing bits
            for (integer i = 0; i < DATA_WIDTH; i = i + 1) begin
                if (xor_result[i]) begin
                    bit_count = bit_count + 1;
                end
            end
            
            // Consider metastable if too many bits differ
            detect_metastability = (bit_count > (DATA_WIDTH / 4));
        end
    endfunction
    
    // Task: Perform resynchronization
    task perform_resynchronization;
        input integer node;
        begin
            resynchronizations = resynchronizations + 1;
            timing_corrections = timing_corrections + 1;
            
            // Reset synchronization state machines
            core_to_ic_state[node] = SYNC_IDLE;
            ic_to_core_state[node] = SYNC_IDLE;
            ic_to_mem_state[node] = SYNC_IDLE;
            mem_to_ic_state[node] = SYNC_IDLE;
            
            // Clear synchronization registers
            for (integer i = 0; i < SYNC_STAGES; i = i + 1) begin
                core_to_ic_sync[node][i] = {DATA_WIDTH{1'b0}};
                core_to_ic_valid_sync[node][i] = 1'b0;
                ic_to_core_sync[node][i] = {DATA_WIDTH{1'b0}};
                ic_to_core_valid_sync[node][i] = 1'b0;
                ic_to_mem_sync[node][i] = {DATA_WIDTH{1'b0}};
                ic_to_mem_valid_sync[node][i] = 1'b0;
                mem_to_ic_sync[node][i] = {DATA_WIDTH{1'b0}};
                mem_to_ic_valid_sync[node][i] = 1'b0;
            end
            
            $display("[%0t] [TIMING-MANAGER] RESYNCHRONIZATION: Node %0d due to timing drift", $time, node);
        end
    endtask
    
    // Task: Log metastability event
    task log_metastability;
        input integer node;
        input [1:0] domain;
        input [DATA_WIDTH-1:0] data1;
        input [DATA_WIDTH-1:0] data2;
        reg [47:0] log_entry;
        begin
            // Pack metastability information into log entry
            log_entry = {domain, 6'b000000, node[7:0], data1[15:0], data2[15:0]};
            
            // Store in circular buffer
            metastability_history[metastability_pointer] = log_entry;
            metastability_pointer = metastability_pointer + 1;
            
            $display("[%0t] [TIMING-MANAGER] METASTABILITY: Node=%0d, Domain=%0d", $time, node, domain);
        end
    endtask
    
    // Update timing health metrics
    always @(posedge interconnect_clk) begin
        if (rst_n) begin
            // Calculate average setup and hold times
            total_setup_time = 32'd0;
            total_hold_time = 32'd0;
            
            for (integer i = 0; i < NUM_NODES; i = i + 1) begin
                total_setup_time = total_setup_time + setup_time_samples[i];
                total_hold_time = total_hold_time + hold_time_samples[i];
            end
            
            // Calculate average jitter
            total_jitter_measurement = 32'd0;
            for (integer i = 0; i < CLOCK_DOMAINS; i = i + 1) begin
                total_jitter_measurement = total_jitter_measurement + max_jitter_seen[i];
            end
            
            // Update timing health score
            update_timing_health();
        end
    end
    
    // Task: Update timing health
    task update_timing_health;
        reg [31:0] avg_drift, avg_jitter, error_rate;
        begin
            // Calculate average drift
            avg_drift = (max_drift_seen > 0) ? (drift_accumulator / NUM_NODES) : 32'd0;
            
            // Calculate average jitter
            avg_jitter = (total_jitter_measurement > 0) ? (total_jitter_measurement / CLOCK_DOMAINS) : 32'd0;
            
            // Calculate error rate
            if (domain_crossings > 0) begin
                error_rate = (sync_errors * 100) / domain_crossings;
            end else begin
                error_rate = 32'd0;
            end
            
            // Calculate health score (0-100)
            if (avg_drift < 10 && avg_jitter < 5 && error_rate < 1) begin
                timing_health = 8'd100; // Excellent
            end else if (avg_drift < 50 && avg_jitter < 20 && error_rate < 5) begin
                timing_health = 8'd80;  // Good
            end else if (avg_drift < 100 && avg_jitter < 50 && error_rate < 10) begin
                timing_health = 8'd60;  // Fair
            end else begin
                timing_health = 8'd40;  // Poor
            end
            
            timing_healthy = (timing_health >= 60);
        end
    endtask
    
    // Output assignments
    assign timing_drift_detected = max_drift_seen;
    assign metastability_events = metastability_count;
    assign synchronization_errors = sync_errors;
    assign timing_health_score = timing_health;
    assign timing_system_healthy = timing_healthy;
    
    assign avg_setup_time = (total_setup_time > 0) ? (total_setup_time / NUM_NODES) : 32'd0;
    assign avg_hold_time = (total_hold_time > 0) ? (total_hold_time / NUM_NODES) : 32'd0;
    assign max_skew_detected = max_skew_measurement;
    assign clock_jitter_measured = (total_jitter_measurement > 0) ? 
                                 (total_jitter_measurement / CLOCK_DOMAINS) : 32'd0;
    
    assign domain_crossing_count = domain_crossings;
    assign resynchronization_count = resynchronizations;
    assign timing_correction_count = timing_corrections;
    
    // Connect synchronized data to outputs
    genvar g_node;
    generate
        for (g_node = 0; g_node < NUM_NODES; g_node = g_node + 1) begin : gen_timing_outputs
            // Core to interconnect outputs
            assign core_to_ic_ready[g_node] = (core_to_ic_state[g_node] == SYNC_IDLE);
            
            // Interconnect to core outputs
            assign ic_to_core_data[g_node] = ic_to_core_sync[g_node][SYNC_STAGES-1];
            assign ic_to_core_valid[g_node] = ic_to_core_valid_sync[g_node][SYNC_STAGES-1];
            
            // Interconnect to memory outputs
            assign ic_to_mem_ready[g_node] = (ic_to_mem_state[g_node] == SYNC_IDLE);
            
            // Memory to interconnect outputs
            assign mem_to_ic_data[g_node] = mem_to_ic_sync[g_node][SYNC_STAGES-1];
            assign mem_to_ic_valid[g_node] = mem_to_ic_valid_sync[g_node][SYNC_STAGES-1];
        end
    endgenerate
    
    // Debug output
    always @(posedge clk) begin
        if (domain_crossings % 10000 == 0 && domain_crossings > 0) begin
            $display("[%0t] [TIMING-MANAGER] ===== TIMING HEALTH REPORT =====", $time);
            $display("[%0t] [TIMING-MANAGER] Domain Crossings: %0d", $time, domain_crossings);
            $display("[%0t] [TIMING-MANAGER] Max Drift: %0d cycles", $time, max_drift_seen);
            $display("[%0t] [TIMING-MANAGER] Metastability Events: %0d", $time, metastability_count);
            $display("[%0t] [TIMING-MANAGER] Synchronization Errors: %0d", $time, sync_errors);
            $display("[%0t] [TIMING-MANAGER] Timing Health: %0d/100 (%s)", $time, timing_health, 
                     timing_healthy ? "HEALTHY" : "UNHEALTHY");
            $display("[%0t] [TIMING-MANAGER] Clock Jitter: %0d ps", $time, clock_jitter_measured);
            $display("[%0t] [TIMING-MANAGER] ======================================", $time);
        end
    end
    
endmodule
