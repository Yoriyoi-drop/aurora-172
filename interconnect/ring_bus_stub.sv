`timescale 1ns / 1ps
// Stub for ring_bus module — replace with actual implementation
module ring_bus #(
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 40,
    parameter NUM_NODES  = 4,
    parameter BUFFER_DEPTH = 8
)(
    input  wire                     clk, rst_n,
    input  wire [ADDR_WIDTH-1:0]    node_req_addr  [0:NUM_NODES-1],
    input  wire [DATA_WIDTH-1:0]    node_req_data  [0:NUM_NODES-1],
    input  wire                     node_req_valid [0:NUM_NODES-1],
    input  wire [1:0]               node_req_qos   [0:NUM_NODES-1],
    output wire                     node_req_ready [0:NUM_NODES-1],
    output wire [DATA_WIDTH-1:0]    node_resp_data [0:NUM_NODES-1],
    output wire                     node_resp_valid[0:NUM_NODES-1],
    input  wire [NUM_NODES-1:0]     node_resp_ready,
    input  wire                     gaming_mode,
    input  wire [NUM_NODES-1:0]     node_priority,
    input  wire [NUM_NODES-1:0]     node_congested,
    output wire [31:0]              ring_total_packets,
    output wire [31:0]              ring_avg_latency,
    output wire [31:0]              ring_contention_count,
    output wire [31:0]              ring_aged_packets,
    output wire [31:0]              ring_dropped_packets,
    output wire [15:0]              ring_max_packet_age,
    output wire                     ring_deadlock_active,
    output wire [31:0]              ring_deadlock_recoveries,
    output wire                     ring_system_stalled,
    output wire [NUM_NODES-1:0]     node_activity_mask
);
    assign node_req_ready = {NUM_NODES{1'b1}};
    assign node_resp_data = '{default: '0};
    assign node_resp_valid = {NUM_NODES{1'b0}};
    assign ring_total_packets = 32'd0;
    assign ring_avg_latency = 32'd0;
    assign ring_contention_count = 32'd0;
    assign ring_aged_packets = 32'd0;
    assign ring_dropped_packets = 32'd0;
    assign ring_max_packet_age = 16'd0;
    assign ring_deadlock_active = 1'b0;
    assign ring_deadlock_recoveries = 32'd0;
    assign ring_system_stalled = 1'b0;
    assign node_activity_mask = {NUM_NODES{1'b0}};
endmodule
