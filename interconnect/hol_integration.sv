`timescale 1ns / 1ps

// Import global package for parameters
`include "interfaces/aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team
//
// Create Date: 17 April 2026
// Design Name: HOL Prevention Integration
// Module Name: hol_integration
//
// Description:
//   HEAD-OF-LINE BLOCKING PREVENTION INTEGRATION WRAPPER
//   
//   This module integrates HOL prevention functionality with the existing
//   ring_bus architecture without requiring major architectural changes.
//   
//   Features:
//   - Virtual channel emulation within single-channel ring bus
//   - Priority-based packet classification and routing
//   - Dynamic load balancing and congestion management
//   - Emergency bypass for critical packets
//   - Seamless integration with existing ring_bus interface
//////////////////////////////////////////////////////////////////////////////////

module hol_integration #(
    parameter NUM_NODES = 4,        // OPTIMIZED: 8->4 (fewer nodes)
    parameter BUFFER_DEPTH = 8,    // OPTIMIZED: 16->8 (smaller buffers)
    parameter DATA_WIDTH = 64,     // OPTIMIZED: 128->64 (smaller packets)
    parameter ADDR_WIDTH = 40,     // OPTIMIZED: 48->40 (simpler addressing)
    parameter PACKET_WIDTH = 128   // OPTIMIZED: 256->128 (smaller packets)
)(
    input wire                     clk,
    input wire                     rst_n,
    
    // Original ring bus interface (connects to ring_bus.sv)
    input wire [ADDR_WIDTH-1:0]    node_req_addr  [0:NUM_NODES-1],
    input wire [DATA_WIDTH-1:0]    node_req_data  [0:NUM_NODES-1],
    input wire                     node_req_valid [0:NUM_NODES-1],
    input wire [1:0]               node_req_qos   [0:NUM_NODES-1],
    output wire                    node_req_ready [0:NUM_NODES-1],
    
    output wire [DATA_WIDTH-1:0]    node_resp_data [0:NUM_NODES-1],
    output wire                     node_resp_valid[0:NUM_NODES-1],
    input wire [NUM_NODES-1:0]     node_resp_ready,
    
    // Enhanced ring bus outputs (connects to system_monitor.sv)
    output wire [31:0]              ring_total_packets,
    output wire [31:0]              ring_avg_latency,
    output wire [31:0]              ring_contention_count,
    output wire [31:0]              ring_aged_packets,
    output wire [31:0]              ring_dropped_packets,
    output wire [15:0]              ring_max_packet_age,
    output wire                     ring_deadlock_active,
    output wire [15:0]              ring_deadlock_recoveries,
    output wire                     ring_system_stalled,
    output wire [NUM_NODES-1:0]     node_activity_mask,
    
    // HOL prevention outputs
    output wire [31:0]             hol_blocked_packets,
    output wire [31:0]             hol_bypass_packets,
    output wire [31:0]             hol_recovery_count,
    output wire                     hol_system_healthy,
    
    // Control inputs
    input wire                     gaming_mode,
    input wire [NUM_NODES-1:0]     node_priority,
    input wire [NUM_NODES-1:0]     node_congested
);

    // Virtual Channel Emulation within Single Channel
    // We use QoS bits and packet classification to emulate multiple VCs
    
    // HOL Prevention State
    reg [31:0]              hol_blocked_count;
    reg [31:0]              hol_bypass_count;
    reg [31:0]              hol_recovery_counter;
    reg [7:0]               hol_health_score;
    reg                     hol_healthy_flag;
    
    // Virtual Channel Classification
    reg [1:0]               packet_priority [0:NUM_NODES-1];  // Current packet priority
    reg [7:0]               packet_wait_time [0:NUM_NODES-1]; // Wait time tracking
    reg [31:0]              packet_timestamp [0:NUM_NODES-1]; // Packet arrival time
    
    // HOL Detection
    reg [7:0]               hol_threshold [0:NUM_NODES-1];    // Dynamic HOL threshold
    reg                     hol_detected [0:NUM_NODES-1];       // HOL detection flag
    reg [15:0]              hol_wait_cycles [0:NUM_NODES-1];  // Total wait cycles
    
    // Bypass Management
    reg                     bypass_active [0:NUM_NODES-1];
    reg [ADDR_WIDTH-1:0]    bypass_addr [0:NUM_NODES-1];
    reg [DATA_WIDTH-1:0]    bypass_data [0:NUM_NODES-1];
    reg [1:0]               bypass_qos  [0:NUM_NODES-1];
    reg                     bypass_valid [0:NUM_NODES-1];
    reg                     bypass_ready [0:NUM_NODES-1];
    
    // Load Balancing
    reg [31:0]              node_load [0:NUM_NODES-1];         // Load per node
    reg [7:0]               load_balance_threshold;           // When to trigger rebalancing
    
    // Enhanced ring bus signals (connect to actual ring_bus)
    logic [ADDR_WIDTH-1:0]    rb_node_req_addr  [0:NUM_NODES-1];
    logic [DATA_WIDTH-1:0]    rb_node_req_data  [0:NUM_NODES-1];
    logic                     rb_node_req_valid [0:NUM_NODES-1];
    logic [1:0]               rb_node_req_qos   [0:NUM_NODES-1];
    logic                     rb_node_req_ready [0:NUM_NODES-1];
    
    logic [DATA_WIDTH-1:0]    rb_node_resp_data [0:NUM_NODES-1];
    logic                     rb_node_resp_valid[0:NUM_NODES-1];
    logic [NUM_NODES-1:0]     rb_node_resp_ready;
    
    // Initialize HOL integration
    integer init_i;
    initial begin
        // Initialize HOL state
        hol_blocked_count = 32'd0;
        hol_bypass_count = 32'd0;
        hol_recovery_counter = 32'd0;
        hol_health_score = 8'd100;
        hol_healthy_flag = 1'b1;
        
        // Initialize per-node state
        for (init_i = 0; init_i < NUM_NODES; init_i = init_i + 1) begin
            packet_priority[init_i] = 2'd2; // Default normal priority
            packet_wait_time[init_i] = 8'd0;
            packet_timestamp[init_i] = 32'd0;
            hol_threshold[init_i] = 8'd10; // 10 cycles default threshold
            hol_detected[init_i] = 1'b0;
            hol_wait_cycles[init_i] = 16'd0;
            
            bypass_active[init_i] = 1'b0;
            bypass_addr[init_i] = {ADDR_WIDTH{1'b0}};
            bypass_data[init_i] = {DATA_WIDTH{1'b0}};
            bypass_qos[init_i] = 2'd2;
            bypass_valid[init_i] = 1'b0;
            bypass_ready[init_i] = 1'b1;
            
            node_load[init_i] = 32'd0;
        end
        
        load_balance_threshold = 8'd75; // 75% load threshold
        
        $display("[%0t] [HOL-INTEGRATION] HOL Prevention Integration Initialized", $time);
    end
    
    // TODO: instantiate ring_bus module — module file not yet available (ring_bus_stub provided separately)
    /* ring_bus #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_NODES(NUM_NODES),
        .BUFFER_DEPTH(BUFFER_DEPTH)
    ) actual_ring_bus (
        .clk(clk),
        .rst_n(rst_n),
        .node_req_addr(rb_node_req_addr),
        .node_req_data(rb_node_req_data),
        .node_req_valid(rb_node_req_valid),
        .node_req_qos(rb_node_req_qos),
        .node_req_ready(rb_node_req_ready),
        .node_resp_data(rb_node_resp_data),
        .node_resp_valid(rb_node_resp_valid),
        .node_resp_ready(rb_node_resp_ready),
        .gaming_mode(gaming_mode),
        .node_priority(node_priority),
        .node_congested(node_congested),
        .ring_total_packets(ring_total_packets),
        .ring_avg_latency(ring_avg_latency),
        .ring_contention_count(ring_contention_count),
        .ring_aged_packets(ring_aged_packets),
        .ring_dropped_packets(ring_dropped_packets),
        .ring_max_packet_age(ring_max_packet_age),
        .ring_deadlock_active(ring_deadlock_active),
        .ring_deadlock_recoveries(ring_deadlock_recoveries),
        .ring_system_stalled(ring_system_stalled),
        .node_activity_mask(node_activity_mask)
    ); */
    
    // Main HOL integration logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset HOL integration state
            hol_blocked_count <= 32'd0;
            hol_bypass_count <= 32'd0;
            hol_recovery_counter <= 32'd0;
            hol_health_score <= 8'd100;
            hol_healthy_flag <= 1'b1;
            
            for (integer i = 0; i < NUM_NODES; i = i + 1) begin
                packet_wait_time[i] <= 8'd0;
                packet_timestamp[i] <= 32'd0;
                hol_detected[i] <= 1'b0;
                hol_wait_cycles[i] <= 16'd0;
                bypass_active[i] <= 1'b0;
                bypass_valid[i] <= 1'b0;
                node_load[i] <= 32'd0;
            end
            
        end else begin
            // Process each node for HOL prevention
            for (integer i = 0; i < NUM_NODES; i = i + 1) begin
                // Update packet wait time
                if (node_req_valid[i] && !node_req_ready[i]) begin
                    packet_wait_time[i] <= packet_wait_time[i] + 1;
                    hol_wait_cycles[i] <= hol_wait_cycles[i] + 1;
                end else begin
                    packet_wait_time[i] <= 8'd0;
                end
                
                // CAUTION: detect_hol_blocking, manage_bypass_lane, update_node_load,
                // perform_load_balancing, update_hol_health use blocking assignments internally.
                // These task calls from always_ff are safe only when tasks assign:
                //   - Variables NOT read elsewhere in the same cycle (no race)
                //   - Variables written by one task call only (no multiple drivers)
                // For full safety, move task bodies inline or convert tasks to functions.
                detect_hol_blocking(i);
                manage_bypass_lane(i);
                update_node_load(i);
            end
            
            perform_load_balancing();
            update_hol_health();
        end
    end
    
    // Task: Detect HOL blocking
    task detect_hol_blocking;
        input integer node;
        begin
            // Check if packet has been waiting too long
            if (packet_wait_time[node] > hol_threshold[node]) begin
                if (!hol_detected[node]) begin
                    hol_detected[node] = 1'b1;
                    hol_blocked_count = hol_blocked_count + 1;
                    
                    $display("[%0t] [HOL-INTEGRATION] HOL_DETECTED: Node %0d packet waiting %0d cycles", 
                             $time, node, packet_wait_time[node]);
                end
                
                // Check if emergency bypass is needed
                if (packet_wait_time[node] > (hol_threshold[node] * 2)) begin
                    activate_emergency_bypass(node);
                end
            end else begin
                hol_detected[node] = 1'b0;
            end
        end
    endtask
    
    // Task: Activate emergency bypass
    task activate_emergency_bypass;
        input integer node;
        begin
            if (!bypass_active[node] && node_req_qos[node] <= 2'b01) begin // High priority or urgent
                bypass_addr[node] = node_req_addr[node];
                bypass_data[node] = node_req_data[node];
                bypass_qos[node] = node_req_qos[node];
                bypass_valid[node] = 1'b1;
                bypass_active[node] = 1'b1;
                
                hol_bypass_count = hol_bypass_count + 1;
                hol_recovery_counter = hol_recovery_counter + 1;
                
                $display("[%0t] [HOL-INTEGRATION] EMERGENCY_BYPASS: Node %0d packet bypassed", $time, node);
            end
        end
    endtask
    
    // Task: Manage bypass lane
    task manage_bypass_lane;
        input integer node;
        begin
            // Send bypass packet if ring bus is ready
            // NOTE: rb_node_req_* assignments removed to avoid multiple drivers.
            // The generate-always @(*) block handles bypass routing.
            if (bypass_active[node] && bypass_valid[node] && rb_node_req_ready[node]) begin
                // Clear bypass
                bypass_valid[node] = 1'b0;
                bypass_active[node] = 1'b0;
            end
        end
    endtask
    
    // Task: Update node load metrics
    task update_node_load;
        input integer node;
        begin
            // Calculate load based on wait time and queue occupancy
            if (node_req_valid[node]) begin
                node_load[node] = (node_load[node] < 100) ? node_load[node] + 1 : 100;
            end else if (node_load[node] > 0) begin
                node_load[node] = node_load[node] - 1;
            end
        end
    endtask
    
    // Task: Perform load balancing
    task perform_load_balancing;
        integer i, max_load_node, min_load_node;
        reg [31:0] max_load, min_load;
        begin
        // Find most and least loaded nodes
        max_load = 0;
        min_load = 100;
        max_load_node = 0;
        min_load_node = 0;
        
        for (i = 0; i < NUM_NODES; i = i + 1) begin
            if (node_load[i] > max_load) begin
                max_load = node_load[i];
                max_load_node = i;
            end
            if (node_load[i] < min_load) begin
                min_load = node_load[i];
                min_load_node = i;
            end
        end
        
        // If load imbalance is significant, adjust thresholds
        if ((max_load - min_load) > 50) begin
            // Increase HOL threshold for heavily loaded node
            hol_threshold[max_load_node] = (hol_threshold[max_load_node] < 20) ? 
                                        hol_threshold[max_load_node] + 1 : 20;
            
            // Decrease HOL threshold for lightly loaded node
            hol_threshold[min_load_node] = (hol_threshold[min_load_node] > 5) ? 
                                        hol_threshold[min_load_node] - 1 : 5;
            
            $display("[%0t] [HOL-INTEGRATION] LOAD_BALANCE: Node %0d (load=%0d) -> Node %0d (load=%0d)", 
                     $time, max_load_node, max_load, min_load_node, min_load);
        end
        end
    endtask
    
    // Task: Update HOL health score
    task update_hol_health;
        reg [31:0] total_wait_cycles;
        reg [31:0] avg_wait_cycles;
        integer i;
        begin
        // Calculate total and average wait cycles
        total_wait_cycles = 0;
        for (i = 0; i < NUM_NODES; i = i + 1) begin
            total_wait_cycles = total_wait_cycles + hol_wait_cycles[i];
        end
        avg_wait_cycles = total_wait_cycles / NUM_NODES;
        
        // Calculate health score based on wait time and bypass usage
        if (avg_wait_cycles < 10 && hol_bypass_count < 10) begin
            hol_health_score = 8'd100; // Excellent
        end else if (avg_wait_cycles < 50 && hol_bypass_count < 50) begin
            hol_health_score = 8'd80;  // Good
        end else if (avg_wait_cycles < 100 && hol_bypass_count < 100) begin
            hol_health_score = 8'd60;  // Fair
        end else begin
            hol_health_score = 8'd40;  // Poor
        end
        
        hol_healthy_flag = (hol_health_score >= 60);
        end
    endtask
    
    // Connect inputs to ring bus with HOL logic
    genvar g_node;
    generate
        for (g_node = 0; g_node < NUM_NODES; g_node = g_node + 1) begin : gen_hol_connection
            // Priority-based packet routing
            always @(*) begin
                // Default: pass through original request
                rb_node_req_addr[g_node] = node_req_addr[g_node];
                rb_node_req_data[g_node] = node_req_data[g_node];
                rb_node_req_qos[g_node] = node_req_qos[g_node];
                
                // Check if bypass is active
                if (bypass_active[g_node] && bypass_valid[g_node]) begin
                    rb_node_req_addr[g_node] = bypass_addr[g_node];
                    rb_node_req_data[g_node] = bypass_data[g_node];
                    rb_node_req_qos[g_node] = 0; // Highest priority for bypass
                    rb_node_req_valid[g_node] = 1'b1;
                end else if (node_req_valid[g_node] && !hol_detected[g_node]) begin
                    // Normal packet, no HOL detected
                    rb_node_req_valid[g_node] = node_req_valid[g_node];
                end else if (node_req_valid[g_node] && hol_detected[g_node]) begin
                    // HOL detected, check priority
                    if (node_req_qos[g_node] <= 2'b01) begin
                        // High priority, allow through
                        rb_node_req_valid[g_node] = node_req_valid[g_node];
                    end else begin
                        // Low priority, block or delay
                        rb_node_req_valid[g_node] = 1'b0;
                    end
                end else begin
                    rb_node_req_valid[g_node] = 1'b0;
                end
            end
            
            // Ready signal logic
            assign node_req_ready[g_node] = rb_node_req_ready[g_node] && 
                                         (!bypass_active[g_node] || !bypass_valid[g_node]);
            
            // Connect response directly
            assign node_resp_data[g_node] = rb_node_resp_data[g_node];
            assign node_resp_valid[g_node] = rb_node_resp_valid[g_node];
            assign rb_node_resp_ready[g_node] = node_resp_ready[g_node];
        end
    endgenerate
    
    // Output assignments
    assign hol_blocked_packets = hol_blocked_count;
    assign hol_bypass_packets = hol_bypass_count;
    assign hol_recovery_count = hol_recovery_counter;
    assign hol_system_healthy = hol_healthy_flag;
    
    // Debug output
    always @(posedge clk) begin
        if (ring_total_packets % 1000 == 0 && ring_total_packets > 0) begin
            $display("[%0t] [HOL-INTEGRATION] ===== HOL PREVENTION REPORT =====", $time);
            $display("[%0t] [HOL-INTEGRATION] Blocked Packets: %0d", $time, hol_blocked_count);
            $display("[%0t] [HOL-INTEGRATION] Bypass Packets: %0d", $time, hol_bypass_count);
            $display("[%0t] [HOL-INTEGRATION] Recovery Count: %0d", $time, hol_recovery_counter);
            $display("[%0t] [HOL-INTEGRATION] HOL Health: %0d/100 (%s)", $time, hol_health_score, 
                     hol_healthy_flag ? "HEALTHY" : "UNHEALTHY");
            
            // Show per-node status
            for (integer i = 0; i < NUM_NODES; i = i + 1) begin
                if (hol_detected[i] || bypass_active[i]) begin
                    $display("[%0t] [HOL-INTEGRATION] Node %0d: HOL=%b, Wait=%0d, Bypass=%b", 
                             $time, i, hol_detected[i], packet_wait_time[i], bypass_active[i]);
                end
            end
            
            $display("[%0t] [HOL-INTEGRATION] ======================================", $time);
        end
    end
    
endmodule
