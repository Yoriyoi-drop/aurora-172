`timescale 1ns / 1ps

// Import global package for parameters
// Import global package for parameters
`include "interfaces/aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 FPGA Top-Level
// Module Name: aurora_172_fpga_top
//
// Description:
//   FPGA top-level wrapper untuk AURORA-172 heterogeneous processor
//   Mengintegrasikan:
//   - Clock distribution network
//   - I/O wrapper dengan pin FPGA
//   - Clock domain crossing (CDC) synchronizers
//   - Debug infrastructure (ILA/VIO)
//   - AURORA-172 core complex
//
// Target Board: Xilinx Versal VP1802 Development Kit
// Tool: Vivado 2024.1+
//////////////////////////////////////////////////////////////////////////////////

module aurora_172_fpga_top (
    // =========================================================================
    // External clock and reset
    // =========================================================================
    input  wire                         sys_clk_p,
    input  wire                         sys_clk_n,
    input  wire                         sys_rst_n,

    // =========================================================================
    // Simplified DDR4 Memory Interface
    // =========================================================================
    output wire [16:0]                  ddr4_addr,
    output wire [2:0]                   ddr4_ba,
    output wire                         ddr4_cs_n,
    output wire                         ddr4_ras_n,
    output wire                         ddr4_cas_n,
    output wire                         ddr4_we_n,
    output wire                         ddr4_reset_n,
    output wire                         ddr4_cke,
    output wire                         ddr4_act_n,
    inout  wire [31:0]                  ddr4_dq,      // OPTIMIZED: 72->32 bits
    inout wire [3:0]                    ddr4_dqs_p,    // OPTIMIZED: 9->4 bits
    inout wire [3:0]                    ddr4_dqs_n,    // OPTIMIZED: 9->4 bits

    // =========================================================================
    // PCIe Gen5 Interface
    // =========================================================================
    output wire [15:0]                  pcie_tx_p,
    output wire [15:0]                  pcie_tx_n,
    input  wire [15:0]                  pcie_rx_p,
    input  wire [15:0]                  pcie_rx_n,
    input  wire                         pcie_perst_n,
    input  wire                         pcie_clk_p,
    input  wire                         pcie_clk_n,

    // =========================================================================
    // Debug JTAG Interface
    // =========================================================================
    input  wire                         jtag_tck,
    input  wire                         jtag_tms,
    input  wire                         jtag_tdi,
    output wire                         jtag_tdo,
    input  wire                         jtag_trst_n,

    // =========================================================================
    // UART Console
    // =========================================================================
    output wire                         uart_tx,
    input  wire                         uart_rx,

    // =========================================================================
    // GPIO / Status LEDs
    // =========================================================================
    output wire [7:0]                   led_status,
    input  wire                         gpio_int_n,

    // =========================================================================
    // Test Mode
    // =========================================================================
    input  wire                         test_mode_en
);

//-----------------------------------------------------------------------------
// Internal clock domains
//-----------------------------------------------------------------------------
wire g_core_clk;
wire h_core_clk;
wire ai_core_clk;
wire mem_fabric_clk;
wire interconnect_clk;
wire debug_clk;
wire clk_locked;
wire [7:0] clk_status;

//-----------------------------------------------------------------------------
// Synchronized reset untuk setiap clock domain
//-----------------------------------------------------------------------------
reg [2:0] rst_sync_g = 0;
reg [2:0] rst_sync_h = 0;
reg [2:0] rst_sync_ai = 0;
reg [2:0] rst_sync_mem = 0;

always @(posedge g_core_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) rst_sync_g <= 0;
    else rst_sync_g <= {rst_sync_g[1:0], sys_rst_n};
end

always @(posedge h_core_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) rst_sync_h <= 0;
    else rst_sync_h <= {rst_sync_h[1:0], sys_rst_n};
end

always @(posedge ai_core_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) rst_sync_ai <= 0;
    else rst_sync_ai <= {rst_sync_ai[1:0], sys_rst_n};
end

always @(posedge mem_fabric_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) rst_sync_mem <= 0;
    else rst_sync_mem <= {rst_sync_mem[1:0], sys_rst_n};
end

wire sys_rst_g = rst_sync_g[2];
wire sys_rst_h = rst_sync_h[2];
wire sys_rst_ai = rst_sync_ai[2];
wire sys_rst_mem = rst_sync_mem[2];

//-----------------------------------------------------------------------------
// Internal signals - AURORA-172 interfaces
//-----------------------------------------------------------------------------
wire [63:0] game_cmd_addr;
wire [31:0] game_cmd_data;
wire        game_cmd_valid;
wire        game_cmd_ready;
wire [63:0] game_result;
wire        game_result_valid;

wire [63:0] ai_cmd_addr;
wire [63:0] ai_cmd_data;
wire        ai_cmd_valid;
wire        ai_cmd_ready;
wire [63:0] ai_result;
wire        ai_result_valid;

wire        sys_interrupt;
wire [15:0] sys_power_mode;
wire [31:0] sys_status;

wire [171:0] mem_addr;
wire         mem_rd_en;
wire         mem_wr_en;
wire [171:0] mem_rd_data_int;
wire [171:0] mem_wr_data;
wire         mem_ready;

//-----------------------------------------------------------------------------
// CDC: Memory data dari DDR4 domain ke G-Core domain
//-----------------------------------------------------------------------------
wire [171:0] mem_rd_data_cdc;

cdc_fifo #(
    .DATA_WIDTH(172),
    .ADDR_WIDTH(3)  // 8-entry FIFO
) cdc_mem_data (
    .wr_clk     (mem_fabric_clk),
    .wr_rst_n   (sys_rst_mem),
    .wr_data    (mem_rd_data_int),
    .wr_en      (mem_ready),
    .wr_full    (),

    .rd_clk     (g_core_clk),
    .rd_rst_n   (sys_rst_g),
    .rd_data    (mem_rd_data_cdc),
    .rd_valid   (),
    .rd_en      (mem_rd_en)
);

assign mem_rd_data = mem_rd_data_cdc;

//-----------------------------------------------------------------------------
// CDC: Command dari external ke core domains
//-----------------------------------------------------------------------------
// FIX: Remove useless CDC instances that discard all outputs.
// Game and AI commands are already in the correct clock domain
// (connected directly to aurora_172_inst). CDC is only needed when
// crossing between DIFFERENT clock domains, which is not the case here
// since both src and dst use the same clk.
//
// If external interface runs on a different clock, instantiate proper
// CDC with connected outputs. For now, direct passthrough is correct.
//
// Game command — direct connect (no CDC needed for same-domain signals)
// AI command  — direct connect (no CDC needed for same-domain signals)

//-----------------------------------------------------------------------------
// Clock Distribution Network
//-----------------------------------------------------------------------------
fpga_clock_distribution clock_dist (
    .sys_clk_p          (sys_clk_p),
    .sys_clk_n          (sys_clk_n),
    .sys_rst_n          (sys_rst_n),
    .g_core_clk         (g_core_clk),
    .h_core_clk         (h_core_clk),
    .ai_core_clk        (ai_core_clk),
    .mem_fabric_clk     (mem_fabric_clk),
    .interconnect_clk   (interconnect_clk),
    .debug_clk          (debug_clk),
    .clk_locked         (clk_locked),
    .clk_status         (clk_status),
    .freq_sel           (3'b000),  // Default: max performance
    .freq_update_req    (1'b0),
    .freq_update_ack    ()
);

//-----------------------------------------------------------------------------
// AURORA-172 Core Complex
//-----------------------------------------------------------------------------
aurora_172_top #(
    .DATA_WIDTH         (64),
    .ADDR_WIDTH         (48),
    .INST_WIDTH         (128),
    .NUM_G_CORES        (16),
    .NUM_H_CORES        (32),
    .NUM_A_CORES        (64),
    .NUM_NPU_CLUSTERS   (8),
    .CACHE_LINE_WIDTH   (172),
    .MAX_CLOCK_FREQ     (500)  // 500 MHz FPGA clock
) aurora_172_inst (
    // Clock & Reset
    .clk                (g_core_clk),
    .rst_n              (sys_rst_g),

    // Gaming interface
    .game_cmd_addr      (game_cmd_addr),
    .game_cmd_data      (game_cmd_data),
    .game_cmd_valid     (game_cmd_valid),
    .game_cmd_ready     (game_cmd_ready),
    .game_result        (game_result),
    .game_result_valid  (game_result_valid),

    // AI interface
    .ai_cmd_addr        (ai_cmd_addr),
    .ai_cmd_data        (ai_cmd_data),
    .ai_cmd_valid       (ai_cmd_valid),
    .ai_cmd_ready       (ai_cmd_ready),
    .ai_result          (ai_result),
    .ai_result_valid    (ai_result_valid),

    // System interface
    .sys_interrupt      (sys_interrupt),
    .sys_power_mode     (sys_power_mode),
    .sys_status         (sys_status),

    // Memory interface (172-bit bus)
    .mem_addr           (mem_addr),
    .mem_rd_en          (mem_rd_en),
    .mem_wr_en          (mem_wr_en),
    .mem_rd_data        (mem_rd_data),
    .mem_wr_data        (mem_wr_data),
    .mem_ready          (mem_ready)
);

//-----------------------------------------------------------------------------
// I/O Wrapper - Connect to FPGA pins
//-----------------------------------------------------------------------------
fpga_io_wrapper io_wrapper_inst (
    .sys_clk_p          (sys_clk_p),
    .sys_clk_n          (sys_clk_n),
    .sys_rst_n          (sys_rst_n),
    .ddr4_addr          (ddr4_addr),
    .ddr4_ba            (ddr4_ba),
    .ddr4_cke           (ddr4_cke),
    .ddr4_cs_n          (ddr4_cs_n),
    .ddr4_ras_n         (ddr4_ras_n),
    .ddr4_cas_n         (ddr4_cas_n),
    .ddr4_we_n          (ddr4_we_n),
    .ddr4_reset_n       (ddr4_reset_n),
    .ddr4_dq            (ddr4_dq),
    .ddr4_dqs_p         (ddr4_dqs_p),
    .ddr4_dqs_n         (ddr4_dqs_n),
    .ddr4_act_n         (ddr4_act_n),
    .pcie_tx_p          (pcie_tx_p),
    .pcie_tx_n          (pcie_tx_n),
    .pcie_rx_p          (pcie_rx_p),
    .pcie_rx_n          (pcie_rx_n),
    .pcie_perst_n       (pcie_perst_n),
    .pcie_clk_p         (pcie_clk_p),
    .pcie_clk_n         (pcie_clk_n),
    .jtag_tck           (jtag_tck),
    .jtag_tms           (jtag_tms),
    .jtag_tdi           (jtag_tdi),
    .jtag_tdo           (jtag_tdo),
    .jtag_trst_n        (jtag_trst_n),
    .uart_tx            (uart_tx),
    .uart_rx            (uart_rx),
    .led_status         (led_status),
    .gpio_int_n         (gpio_int_n),
    .test_mode_en       (test_mode_en)
);

//-----------------------------------------------------------------------------
// Debug Infrastructure - ILA Probes
//-----------------------------------------------------------------------------
// Mark signals untuk Integrated Logic Analyzer (ILA)
// Dalam implementasi nyata, instantiate ILA IP di sini

wire ila_trigger = game_cmd_valid | ai_cmd_valid | mem_rd_en | mem_wr_en;

// Debug registers untuk ILA
reg [31:0] debug_reg_0 = 0;
reg [31:0] debug_reg_1 = 0;
reg [31:0] debug_reg_2 = 0;
reg [31:0] debug_reg_3 = 0;

always @(posedge debug_clk) begin
    debug_reg_0 <= sys_status;
    debug_reg_1 <= {clk_status, 24'h0};
    debug_reg_2 <= game_cmd_valid ? game_cmd_data : debug_reg_2;
    debug_reg_3 <= ai_cmd_valid ? ai_cmd_data[31:0] : debug_reg_3;
end

//-----------------------------------------------------------------------------
// Power Mode Configuration
//-----------------------------------------------------------------------------
// Default: Mixed mode (Gaming + AI)
assign sys_power_mode = 16'b0011;

//-----------------------------------------------------------------------------
// System Interrupt
//-----------------------------------------------------------------------------
// 2-flop synchronizer for async inputs gpio_int_n and pcie_perst_n
reg gpio_sync1, gpio_sync2;
reg pcie_sync1, pcie_sync2;
always @(posedge g_core_clk) begin
    gpio_sync1 <= gpio_int_n;
    gpio_sync2 <= gpio_sync1;
    pcie_sync1 <= pcie_perst_n;
    pcie_sync2 <= pcie_sync1;
end
assign sys_interrupt = ~gpio_sync2 | ~pcie_sync2;

//=============================================================================
// Simulation-Only Assertions
//=============================================================================
`ifndef SYNTHESIS
    // Check clock frequencies
    property p_clock_freq_check;
        realtime period;
        @(posedge g_core_clk) (1, period = $realtime) |-> 
            @(posedge g_core_clk) ($realtime - period) >= 1.8ns;
    endproperty
    assert property (p_clock_freq_check) else
        $warning("G-Core clock frequency below 500 MHz");

    // Check reset synchronization
    property p_reset_sync;
        @(posedge g_core_clk) !sys_rst_n |=> ##[1:3] sys_rst_g == 0;
    endproperty
    assert property (p_reset_sync) else
        $error("Reset synchronization failed");
`endif

endmodule
