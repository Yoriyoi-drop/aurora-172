`timescale 1ns / 1ps

// Import global package for parameters
`include "interfaces/aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team
//
// Create Date: 17 April 2026
// Design Name: Head-of-Line Blocking Prevention
// Module Name: hol_prevention
//
// Description:
//   HEAD-OF-LINE (HOL) BLOCKING PREVENTION SYSTEM
//   
//   Features:
//   - Multiple virtual channels (VCs) for traffic separation
//   - Priority-based forwarding with bypass lanes
//   - Dynamic VC allocation and load balancing
//   - HOL detection and automatic traffic rerouting
//   - Emergency bypass for critical packets
//////////////////////////////////////////////////////////////////////////////////

module hol_prevention #(
    parameter NUM_NODES = 4,        // OPTIMIZED: 8->4 (fewer nodes)
    parameter BUFFER_DEPTH = 8,    // OPTIMIZED: 16->8 (smaller buffers)
    parameter NUM_VCS = 4,         // FIXED: was 2 but code uses 4 VCs (URGENT, HIGH, NORMAL, LOW)
    parameter DATA_WIDTH = 64,     // OPTIMIZED: 128->64 (smaller packets)
    parameter ADDR_WIDTH = 40,     // OPTIMIZED: 48->40 (simpler addressing)
    parameter PACKET_WIDTH = 128   // OPTIMIZED: 256->128 (smaller packets)
)(
    input wire                     clk,
    input wire                     rst_n,
    
    // Packet inputs (classified by priority)
    input wire [ADDR_WIDTH-1:0]    packet_addr    [0:NUM_NODES-1],
    input wire [DATA_WIDTH-1:0]    packet_data    [0:NUM_NODES-1],
    input wire [1:0]               packet_qos     [0:NUM_NODES-1],  // QoS for VC selection
    input wire                     packet_valid   [0:NUM_NODES-1],
    input wire [1:0]               packet_dir     [0:NUM_NODES-1],  // Direction
    output wire                    packet_ready   [0:NUM_NODES-1],
    
    // Ring bus interface
    output wire [ADDR_WIDTH-1:0]    ring_out_addr  [0:NUM_NODES-1][0:NUM_VCS-1],
    output wire [DATA_WIDTH-1:0]    ring_out_data  [0:NUM_NODES-1][0:NUM_VCS-1],
    output wire                     ring_out_valid [0:NUM_NODES-1][0:NUM_VCS-1],
    input wire                      ring_out_ready [0:NUM_NODES-1][0:NUM_VCS-1],
    
    input wire [ADDR_WIDTH-1:0]    ring_in_addr   [0:NUM_NODES-1][0:NUM_VCS-1],
    input wire [DATA_WIDTH-1:0]    ring_in_data   [0:NUM_NODES-1][0:NUM_VCS-1],
    input wire                     ring_in_valid  [0:NUM_NODES-1][0:NUM_VCS-1],
    output wire                    ring_in_ready  [0:NUM_NODES-1][0:NUM_VCS-1],
    
    // Monitoring and control
    output wire [31:0]             hol_blocked_packets,
    output wire [31:0]             hol_bypass_packets,
    output wire [31:0]             vc_utilization [0:NUM_VCS-1],
    output wire [31:0]             hol_recovery_count,
    output wire                     hol_system_healthy
);

    // Virtual Channel Types
    localparam VC_URGENT   = 2'd0;   // Critical system packets
    localparam VC_HIGH     = 2'd1;   // High priority traffic
    localparam VC_NORMAL   = 2'd2;   // Normal traffic
    localparam VC_LOW      = 2'd3;   // Background traffic
    
    // HOL Prevention States
    localparam HOL_NORMAL  = 2'b00;
    localparam HOL_WARNING = 2'b01;
    localparam HOL_CRITICAL = 2'b10;
    localparam HOL_EMERGENCY = 2'b11;
    
    // Virtual Channel Buffers
    reg [ADDR_WIDTH-1:0]    vc_buffer_addr  [0:NUM_NODES-1][0:NUM_VCS-1][0:BUFFER_DEPTH-1];
    reg [DATA_WIDTH-1:0]    vc_buffer_data  [0:NUM_NODES-1][0:NUM_VCS-1][0:BUFFER_DEPTH-1];
    reg [1:0]               vc_buffer_qos   [0:NUM_NODES-1][0:NUM_VCS-1][0:BUFFER_DEPTH-1];
    reg [1:0]               vc_buffer_dir   [0:NUM_NODES-1][0:NUM_VCS-1][0:BUFFER_DEPTH-1];
    reg                     vc_buffer_valid [0:NUM_NODES-1][0:NUM_VCS-1][0:BUFFER_DEPTH-1];
    reg [$clog2(BUFFER_DEPTH)-1:0] vc_head [0:NUM_NODES-1][0:NUM_VCS-1];
    reg [$clog2(BUFFER_DEPTH)-1:0] vc_tail [0:NUM_NODES-1][0:NUM_VCS-1];
    
    // HOL Detection and Prevention
    reg [1:0]               hol_state [0:NUM_NODES-1];        // HOL state per node
    reg [31:0]              hol_blocked_count [0:NUM_NODES-1]; // Blocked packets per node
    reg [31:0]              hol_wait_time [0:NUM_NODES-1][0:NUM_VCS-1]; // Wait time per VC
    reg [7:0]               hol_threshold;                      // Dynamic HOL threshold
    reg [31:0]              total_hol_blocks;                   // Total HOL blocks
    reg [31:0]              total_hol_bypasses;                 // Total bypass operations
    reg [31:0]              hol_recoveries;                     // HOL recovery count
    
    // Dynamic VC Allocation
    reg [1:0]               vc_mapping [0:NUM_NODES-1][0:3];   // QoS to VC mapping
    reg [31:0]              vc_load [0:NUM_VCS-1];              // Load per VC
    reg [7:0]               vc_priority_boost [0:NUM_VCS-1];    // Dynamic priority boost
    reg                     rebalance_active;                   // VC rebalancing in progress
    
    // Bypass Lanes for Critical Traffic
    reg                     bypass_active [0:NUM_NODES-1];     // Bypass lane active
    reg [ADDR_WIDTH-1:0]    bypass_addr [0:NUM_NODES-1];
    reg [DATA_WIDTH-1:0]    bypass_data [0:NUM_NODES-1];
    reg [1:0]               bypass_qos  [0:NUM_NODES-1];
    reg [1:0]               bypass_dir  [0:NUM_NODES-1];
    reg                     bypass_valid [0:NUM_NODES-1];
    reg                     bypass_ready [0:NUM_NODES-1];
    
    // Packet Age and TTL for HOL Detection
    reg [15:0]              packet_age [0:NUM_NODES-1][0:NUM_VCS-1][0:BUFFER_DEPTH-1];
    reg [7:0]               packet_ttl [0:NUM_NODES-1][0:NUM_VCS-1][0:BUFFER_DEPTH-1];
    reg [15:0]              max_wait_threshold;                // Maximum wait time
    
    // System Health Monitoring
    reg [31:0]              vc_util [0:NUM_VCS-1];              // VC utilization counters
    reg [7:0]               system_health;                     // Overall system health
    reg                     hol_system_healthy_reg;             // System health flag
    
    // Synthesis-safe initialization is handled in the always_ff reset block below.
    // Parameter validation at elaboration time:
    generate
        if (NUM_NODES < 1)
            $error("[HOL-PREVENTION] NUM_NODES must be >= 1");
        if (BUFFER_DEPTH < 2)
            $error("[HOL-PREVENTION] BUFFER_DEPTH must be >= 2");
    endgenerate
    
    // Main HOL Prevention Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all HOL prevention state
            for (integer i = 0; i < NUM_NODES; i = i + 1) begin
                hol_state[i] <= HOL_NORMAL;
                hol_blocked_count[i] <= 32'd0;
                bypass_active[i] <= 1'b0;
                bypass_valid[i] <= 1'b0;
                
                for (integer j = 0; j < NUM_VCS; j = j + 1) begin
                    vc_head[i][j] <= 0;
                    vc_tail[i][j] <= 0;
                    vc_load[j] <= 32'd0;
                    
                    for (integer k = 0; k < BUFFER_DEPTH; k = k + 1) begin
                        vc_buffer_valid[i][j][k] <= 1'b0;
                        packet_age[i][j][k] <= 16'd0;
                        packet_ttl[i][j][k] <= 8'd255;
                    end
                end
            end
            
            total_hol_blocks <= 32'd0;
            total_hol_bypasses <= 32'd0;
            hol_recoveries <= 32'd0;
            system_health <= 8'd100;
            hol_system_healthy_reg <= 1'b1;
            
        end else begin
            // STEP 1: Packet Classification and VC Assignment
            classify_and_assign_packets();
            
            // STEP 2: HOL Detection and Monitoring
            detect_hol_blocking();
            
            // STEP 3: Dynamic VC Rebalancing
            if (rebalance_needed()) begin
                rebalance_virtual_channels();
            end
            
            // STEP 4: Bypass Lane Management
            manage_bypass_lanes();
            
            // STEP 5: Packet Age and TTL Management
            update_packet_aging();
            
            // STEP 6: System Health Assessment
            assess_system_health();
        end
    end
    
    // Task: Classify packets and assign to appropriate VCs
    task classify_and_assign_packets;
        integer i, vc_idx;
        begin
            for (i = 0; i < NUM_NODES; i = i + 1) begin
                if (packet_valid[i] && packet_ready[i]) begin
                    // Map QoS to Virtual Channel
                    case (packet_qos[i])
                        2'b00: vc_idx = vc_mapping[i][0]; // Urgent
                        2'b01: vc_idx = vc_mapping[i][1]; // High
                        2'b10: vc_idx = vc_mapping[i][2]; // Normal
                        2'b11: vc_idx = vc_mapping[i][3]; // Low
                        default: vc_idx = VC_NORMAL;
                    endcase
                    
                    // Check if target VC has space
                    if (vc_head[i][vc_idx] != ((vc_tail[i][vc_idx] + 1) % BUFFER_DEPTH)) begin
                        // Assign packet to VC
                        integer buffer_idx = vc_head[i][vc_idx];
                        vc_buffer_addr[i][vc_idx][buffer_idx] <= packet_addr[i];
                        vc_buffer_data[i][vc_idx][buffer_idx] <= packet_data[i];
                        vc_buffer_qos[i][vc_idx][buffer_idx] <= packet_qos[i];
                        vc_buffer_dir[i][vc_idx][buffer_idx] <= packet_dir[i];
                        vc_buffer_valid[i][vc_idx][buffer_idx] <= 1'b1;
                        
                        // Initialize packet age and TTL
                        packet_age[i][vc_idx][buffer_idx] <= 16'd0;
                        packet_ttl[i][vc_idx][buffer_idx] <= 8'd255;
                        
                        // Update VC head pointer and load
                        vc_head[i][vc_idx] <= (vc_head[i][vc_idx] == BUFFER_DEPTH-1) ? 0 : vc_head[i][vc_idx] + 1;
                        vc_load[vc_idx] <= vc_load[vc_idx] + 1;
                        
                    end else begin
                        // VC full - try to find alternative VC or use bypass
                        if (packet_qos[i] <= 2'b01) begin // High priority or urgent
                            // Try to use bypass lane
                            if (!bypass_active[i]) begin
                                bypass_addr[i] <= packet_addr[i];
                                bypass_data[i] <= packet_data[i];
                                bypass_qos[i] <= packet_qos[i];
                                bypass_dir[i] <= packet_dir[i];
                                bypass_valid[i] <= 1'b1;
                                bypass_active[i] <= 1'b1;
                                total_hol_bypasses <= total_hol_bypasses + 1;
                            end
                        end else begin
                            // Low priority packet - drop or queue in alternative VC
                            hol_blocked_count[i] <= hol_blocked_count[i] + 1;
                            total_hol_blocks <= total_hol_blocks + 1;
                        end
                    end
                end
            end
        end
    endtask
    
    // Task: Detect Head-of-Line Blocking
    task detect_hol_blocking;
        integer i, j, head_packet_age;
        begin
            for (i = 0; i < NUM_NODES; i = i + 1) begin
                hol_state[i] <= HOL_NORMAL;
                
                // Check each VC for HOL blocking
                for (j = 0; j < NUM_VCS; j = j + 1) begin
                    if (vc_head[i][j] != vc_tail[i][j]) begin
                        // Get head packet age
                        integer tail_idx = vc_tail[i][j];
                        head_packet_age = packet_age[i][j][tail_idx];
                        
                        // Update wait time for head packet
                        hol_wait_time[i][j] <= hol_wait_time[i][j] + 1;
                        
                        // Check for HOL blocking conditions
                        if (head_packet_age > hol_threshold) begin
                            if (hol_state[i] == HOL_NORMAL) begin
                                hol_state[i] <= HOL_WARNING;
                            end else if (head_packet_age > (hol_threshold * 2)) begin
                                hol_state[i] <= HOL_CRITICAL;
                                
                                // Critical HOL: attempt recovery
                                if (head_packet_age > max_wait_threshold) begin
                                    recover_from_hol(i, j);
                                end
                            end
                        end
                    end
                end
                
                // Update system state based on worst HOL condition
                if (hol_state[i] == HOL_CRITICAL && total_hol_blocks > (BUFFER_DEPTH * NUM_NODES / 4)) begin
                    hol_state[i] <= HOL_EMERGENCY;
                    activate_emergency_bypass(i);
                end
            end
        end
    endtask
    
    // Task: Recover from HOL blocking
    task recover_from_hol;
        input integer node;
        input integer vc;
        integer tail_idx, next_vc;
        begin
        tail_idx = vc_tail[node][vc];
        
        // Find less loaded VC to move packet to
        next_vc = find_least_loaded_vc(node);
        
        if (next_vc != vc && vc_head[node][next_vc] != ((vc_tail[node][next_vc] + 1) % BUFFER_DEPTH)) begin
            // Move packet to different VC
            integer new_buffer_idx = vc_head[node][next_vc];
            vc_buffer_addr[node][next_vc][new_buffer_idx] = vc_buffer_addr[node][vc][tail_idx];
            vc_buffer_data[node][next_vc][new_buffer_idx] = vc_buffer_data[node][vc][tail_idx];
            vc_buffer_qos[node][next_vc][new_buffer_idx] = vc_buffer_qos[node][vc][tail_idx];
            vc_buffer_dir[node][next_vc][new_buffer_idx] = vc_buffer_dir[node][vc][tail_idx];
            vc_buffer_valid[node][next_vc][new_buffer_idx] = 1'b1;
            packet_age[node][next_vc][new_buffer_idx] = packet_age[node][vc][tail_idx];
            packet_ttl[node][next_vc][new_buffer_idx] = packet_ttl[node][vc][tail_idx];
            
            // Update target VC
            vc_head[node][next_vc] = (vc_head[node][next_vc] == BUFFER_DEPTH-1) ? 0 : vc_head[node][next_vc] + 1;
            vc_load[next_vc] = vc_load[next_vc] + 1;
            
            // Clear source packet
            vc_buffer_valid[node][vc][tail_idx] = 1'b0;
            vc_tail[node][vc] = (vc_tail[node][vc] == BUFFER_DEPTH-1) ? 0 : vc_tail[node][vc] + 1;
            vc_load[vc] = vc_load[vc] - 1;
            
            hol_recoveries = hol_recoveries + 1;
            $display("[%0t] [HOL-PREVENTION] HOL_RECOVERY: Node %0d packet moved from VC%0d to VC%0d", 
                     $time, node, vc, next_vc);
        end
        end
    endtask
    
    // Function: Find least loaded VC
    function automatic integer find_least_loaded_vc;
        input integer node;
        integer min_load, best_vc, i;
        begin
            min_load = BUFFER_DEPTH;
            best_vc = VC_NORMAL;
            
            for (i = 0; i < NUM_VCS; i = i + 1) begin
                if (vc_load[i] < min_load) begin
                    min_load = vc_load[i];
                    best_vc = i;
                end
            end
            
            find_least_loaded_vc = best_vc;
        end
    endfunction
    
    // Function: Check if VC rebalancing is needed
    function automatic bit rebalance_needed;
        integer max_load, min_load, i;
        begin
            max_load = 0;
            min_load = BUFFER_DEPTH;
            
            for (i = 0; i < NUM_VCS; i = i + 1) begin
                if (vc_load[i] > max_load) max_load = vc_load[i];
                if (vc_load[i] < min_load) min_load = vc_load[i];
            end
            
            rebalance_needed = (max_load - min_load) > (BUFFER_DEPTH / 2);
        end
    endfunction
    
    // Task: Rebalance virtual channels
    task rebalance_virtual_channels;
        integer i, j, overloaded_vc, underloaded_vc;
        begin
        rebalance_active = 1'b1;
        
        // Find most and least loaded VCs
        overloaded_vc = 0;
        underloaded_vc = 0;
        
        for (i = 1; i < NUM_VCS; i = i + 1) begin
            if (vc_load[i] > vc_load[overloaded_vc]) overloaded_vc = i;
            if (vc_load[i] < vc_load[underloaded_vc]) underloaded_vc = i;
        end
        
        // Move packets from overloaded to underloaded VC
        if (vc_load[overloaded_vc] - vc_load[underloaded_vc] > (BUFFER_DEPTH / 4)) begin
            for (i = 0; i < NUM_NODES; i = i + 1) begin
                if (vc_head[i][overloaded_vc] != vc_tail[i][overloaded_vc] && 
                    vc_head[i][underloaded_vc] != ((vc_tail[i][underloaded_vc] + 1) % BUFFER_DEPTH)) begin
                    
                    // Move one packet
                    integer src_tail = vc_tail[i][overloaded_vc];
                    integer dst_head = vc_head[i][underloaded_vc];
                    
                    vc_buffer_addr[i][underloaded_vc][dst_head] = vc_buffer_addr[i][overloaded_vc][src_tail];
                    vc_buffer_data[i][underloaded_vc][dst_head] = vc_buffer_data[i][overloaded_vc][src_tail];
                    vc_buffer_qos[i][underloaded_vc][dst_head] = vc_buffer_qos[i][overloaded_vc][src_tail];
                    vc_buffer_dir[i][underloaded_vc][dst_head] = vc_buffer_dir[i][overloaded_vc][src_tail];
                    vc_buffer_valid[i][underloaded_vc][dst_head] = 1'b1;
                    
                    // Update pointers and loads
                    vc_tail[i][overloaded_vc] = (vc_tail[i][overloaded_vc] == BUFFER_DEPTH-1) ? 0 : vc_tail[i][overloaded_vc] + 1;
                    vc_head[i][underloaded_vc] = (vc_head[i][underloaded_vc] == BUFFER_DEPTH-1) ? 0 : vc_head[i][underloaded_vc] + 1;
                    vc_load[overloaded_vc] = vc_load[overloaded_vc] - 1;
                    vc_load[underloaded_vc] = vc_load[underloaded_vc] + 1;
                    
                    $display("[%0t] [HOL-PREVENTION] VC_REBALANCE: Node %0d packet VC%0d->VC%0d", 
                             $time, i, overloaded_vc, underloaded_vc);
                end
            end
        end
        
        rebalance_active = 1'b0;
        end
    endtask
    
    // Task: Manage bypass lanes
    task manage_bypass_lanes;
        integer i;
        begin
            for (i = 0; i < NUM_NODES; i = i + 1) begin
                if (bypass_active[i] && bypass_valid[i]) begin
                    // Try to send bypass packet directly
                    // This would connect to ring bus bypass logic
                    if (ring_out_ready[i][VC_URGENT]) begin
                        ring_out_addr[i][VC_URGENT] <= bypass_addr[i];
                        ring_out_data[i][VC_URGENT] <= bypass_data[i];
                        ring_out_valid[i][VC_URGENT] <= 1'b1;
                        
                        // Clear bypass
                        bypass_valid[i] <= 1'b0;
                        bypass_active[i] <= 1'b0;
                    end
                end
            end
        end
    endtask
    
    // Task: Update packet aging
    task update_packet_aging;
        integer i, j, k;
        begin
            for (i = 0; i < NUM_NODES; i = i + 1) begin
                for (j = 0; j < NUM_VCS; j = j + 1) begin
                    for (k = 0; k < BUFFER_DEPTH; k = k + 1) begin
                        if (vc_buffer_valid[i][j][k]) begin
                            packet_age[i][j][k] <= packet_age[i][j][k] + 1;
                            if (packet_ttl[i][j][k] > 0) begin
                                packet_ttl[i][j][k] <= packet_ttl[i][j][k] - 1;
                            end
                            
                            // Drop packet if TTL expires
                            if (packet_ttl[i][j][k] == 0) begin
                                vc_buffer_valid[i][j][k] <= 1'b0;
                                vc_load[j] <= vc_load[j] - 1;
                                $display("[%0t] [HOL-PREVENTION] TTL_DROP: Node %0d VC%0d packet expired", $time, i, j);
                            end
                        end
                    end
                end
            end
        end
    endtask
    
    // Task: Assess system health
    task assess_system_health;
        integer total_utilization, avg_utilization, max_wait, i, j;
        begin
            // Calculate VC utilization
            for (i = 0; i < NUM_VCS; i = i + 1) begin
                vc_util[i] <= (vc_load[i] * 100) / (BUFFER_DEPTH * NUM_NODES);
            end
            
            // Calculate overall system health
            total_utilization = 0;
            max_wait = 0;
            
            for (i = 0; i < NUM_NODES; i = i + 1) begin
                for (j = 0; j < NUM_VCS; j = j + 1) begin
                    if (hol_wait_time[i][j] > max_wait) begin
                        max_wait = hol_wait_time[i][j];
                    end
                end
            end
            
            for (i = 0; i < NUM_VCS; i = i + 1) begin
                total_utilization = total_utilization + vc_util[i];
            end
            
            avg_utilization = total_utilization / NUM_VCS;
            
            // Health scoring (0-100)
            if (avg_utilization < 70 && max_wait < 50) begin
                system_health <= 8'd100; // Excellent
            end else if (avg_utilization < 85 && max_wait < 100) begin
                system_health <= 8'd80;  // Good
            end else if (avg_utilization < 95 && max_wait < 200) begin
                system_health <= 8'd60;  // Fair
            end else begin
                system_health <= 8'd40;  // Poor
            end
            
            hol_system_healthy_reg <= (system_health >= 60);
        end
    endtask
    
    // Task: Activate emergency bypass
    task activate_emergency_bypass;
        input integer node;
        integer i, j;
        begin
            $display("[%0t] [HOL-PREVENTION] EMERGENCY_BYPASS: Node %0d activating emergency bypass", $time, node);
            
            // Move all high-priority packets to bypass
            for (j = 0; j < NUM_VCS; j = j + 1) begin
                if (vc_head[node][j] != vc_tail[node][j]) begin
                    integer tail_idx = vc_tail[node][j];
                    
                    if (vc_buffer_qos[node][j][tail_idx] <= 2'b01) begin // High priority or urgent
                        if (!bypass_active[node]) begin
                            bypass_addr[node] <= vc_buffer_addr[node][j][tail_idx];
                            bypass_data[node] <= vc_buffer_data[node][j][tail_idx];
                            bypass_qos[node] <= vc_buffer_qos[node][j][tail_idx];
                            bypass_dir[node] <= vc_buffer_dir[node][j][tail_idx];
                            bypass_valid[node] <= 1'b1;
                            bypass_active[node] <= 1'b1;
                            
                            // Clear from VC
                            vc_buffer_valid[node][j][tail_idx] <= 1'b0;
                            vc_tail[node][j] <= (vc_tail[node][j] == BUFFER_DEPTH-1) ? 0 : vc_tail[node][j] + 1;
                            vc_load[j] <= vc_load[j] - 1;
                            
                            total_hol_bypasses <= total_hol_bypasses + 1;
                        end
                    end
                end
            end
        end
    endtask
    
    // Output assignments
    assign hol_blocked_packets = total_hol_blocks;
    assign hol_bypass_packets = total_hol_bypasses;
    assign hol_recovery_count = hol_recoveries;
    assign hol_system_healthy = hol_system_healthy_reg;
    
    genvar g_vc;
    generate
        for (g_vc = 0; g_vc < NUM_VCS; g_vc = g_vc + 1) begin : gen_vc_outputs
            assign vc_utilization[g_vc] = vc_util[g_vc];
        end
    endgenerate
    
    // Packet ready signals (simplified - based on overall VC availability)
    genvar g_node;
    generate
        for (g_node = 0; g_node < NUM_NODES; g_node = g_node + 1) begin : gen_ready_signals
            wire any_vc_available;
            integer vc_check;
            
            // Check if any VC has space
            assign any_vc_available = (vc_head[g_node][VC_URGENT] != ((vc_tail[g_node][VC_URGENT] + 1) % BUFFER_DEPTH)) ||
                                   (vc_head[g_node][VC_HIGH] != ((vc_tail[g_node][VC_HIGH] + 1) % BUFFER_DEPTH)) ||
                                   (vc_head[g_node][VC_NORMAL] != ((vc_tail[g_node][VC_NORMAL] + 1) % BUFFER_DEPTH)) ||
                                   (vc_head[g_node][VC_LOW] != ((vc_tail[g_node][VC_LOW] + 1) % BUFFER_DEPTH));
            
            assign packet_ready[g_node] = any_vc_available || !bypass_active[g_node];
        end
    endgenerate
    
endmodule
