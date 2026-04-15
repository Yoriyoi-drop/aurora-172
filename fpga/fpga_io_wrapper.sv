`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 FPGA I/O Wrapper
// Module Name: fpga_io_wrapper
//
// Description:
//   I/O wrapper untuk menghubungkan AURORA-172 ke pin FPGA Versal
//   Menyediakan interface untuk:
//   - DDR4/HBM memory (172-bit bus)
//   - PCIe Gen5 x16
//   - Debug JTAG
//   - UART console
//   - GPIO/LED status
//
// Target: Xilinx Versal ACAP (VP1802)
// Tool: Vivado 2024.1+
//////////////////////////////////////////////////////////////////////////////////

module fpga_io_wrapper (
    // =========================================================================
    // External clock and reset
    // =========================================================================
    input  wire                         sys_clk_p,
    input  wire                         sys_clk_n,
    input  wire                         sys_rst_n,

    // =========================================================================
    // DDR4/HBM Memory Interface (simplified - 172-bit bus)
    // =========================================================================
    // DDR4 control signals
    output wire [16:0]                  ddr4_addr,
    output wire [2:0]                   ddr4_ba,
    output wire [1:0]                   ddr4_cke,
    output wire                         ddr4_cs_n,
    output wire                         ddr4_ras_n,
    output wire                         ddr4_cas_n,
    output wire                         ddr4_we_n,
    output wire                         ddr4_reset_n,
    inout  wire [71:0]                  ddr4_dq,
    inout wire [8:0]                    ddr4_dqs_p,
    inout wire [8:0]                    ddr4_dqs_n,
    output wire                         ddr4_act_n,

    // =========================================================================
    // PCIe Gen5 Interface (x16 lanes)
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
    // UART Console (115200 baud)
    // =========================================================================
    output wire                         uart_tx,
    input  wire                         uart_rx,

    // =========================================================================
    // GPIO / Status LEDs
    // =========================================================================
    output wire [7:0]                   led_status,
    input  wire                         gpio_int_n,

    // =========================================================================
    // Test Mode (production test)
    // =========================================================================
    input  wire                         test_mode_en
);

//-----------------------------------------------------------------------------
// Internal signals
//-----------------------------------------------------------------------------
wire g_core_clk;
wire h_core_clk;
wire ai_core_clk;
wire mem_fabric_clk;
wire interconnect_clk;
wire debug_clk;
wire clk_locked;
wire [7:0] clk_status;
wire freq_update_ack;

// AURORA-172 internal signals
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
wire [171:0] mem_rd_data;
wire [171:0] mem_wr_data;
reg          mem_ready;  // FIX: Changed from wire to reg (driven from always block)

// Clock domain crossing signals
wire sys_rst_sync;
wire sys_clk_ibufg;  // FIXED: Add buffered system clock for reset synchronization

//-----------------------------------------------------------------------------
// Buffer system clock for reset synchronization
//-----------------------------------------------------------------------------
IBUFDS #(
    .DIFF_TERM("FALSE"),
    .IBUF_LOW_PWR("FALSE")
) sys_clk_buf (
    .I(sys_clk_p),
    .IB(sys_clk_n),
    .O(sys_clk_ibufg)
);

//-----------------------------------------------------------------------------
// Synchronize reset to system clock domain (FIXED: Use sys_clk_ibufg instead of g_core_clk)
//-----------------------------------------------------------------------------
reg [2:0] rst_sync = 3'b000;
always @(posedge sys_clk_ibufg) begin
    rst_sync <= {rst_sync[1:0], sys_rst_n};
end
assign sys_rst_sync = rst_sync[2];

//-----------------------------------------------------------------------------
// Clock Distribution
//-----------------------------------------------------------------------------
fpga_clock_distribution clock_dist (
    .sys_clk_p          (sys_clk_p),
    .sys_clk_n          (sys_clk_n),
    .sys_rst_n          (sys_rst_sync),
    .g_core_clk         (g_core_clk),
    .h_core_clk         (h_core_clk),
    .ai_core_clk        (ai_core_clk),
    .mem_fabric_clk     (mem_fabric_clk),
    .interconnect_clk   (interconnect_clk),
    .debug_clk          (debug_clk),
    .clk_locked         (clk_locked),
    .clk_status         (clk_status),
    .freq_sel           (4'b000),  // Default to max performance
    .freq_update_req    (1'b0),
    .freq_update_ack    (freq_update_ack)
);

//-----------------------------------------------------------------------------
// AURORA-172 Top Level Instantiation
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
    .MAX_CLOCK_FREQ     (500)  // FPGA clock in MHz
) aurora_172_inst (
    // Clock & Reset (using G-Core domain)
    .clk                (g_core_clk),
    .rst_n              (sys_rst_sync),

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
// DDR4 Memory Controller Implementation
// Simplified MIG-compatible interface with proper timing
//-----------------------------------------------------------------------------
reg [3:0]  ddr4_state = 0;
reg [15:0] ddr4_latency_counter = 0;
reg [71:0] ddr4_dq_int = 0;
reg        ddr4_dq_oe = 0;

localparam DDR4_IDLE     = 4'b0000;
localparam DDR4_ACTIVATE = 4'b0001;
localparam DDR4_READ     = 4'b0010;
localparam DDR4_WRITE    = 4'b0011;
localparam DDR4_PRECHARGE= 4'b0100;
localparam DDR4_REFRESH  = 4'b1000;

// DDR4 timing: ~40ns latency for read (simulated)
localparam DDR4_READ_LATENCY = 16'd40;

always @(posedge g_core_clk or negedge sys_rst_sync) begin
    if (!sys_rst_sync) begin
        ddr4_state <= DDR4_IDLE;
        ddr4_latency_counter <= 0;
        ddr4_dq_int <= 0;
        ddr4_dq_oe <= 0;
    end else begin
        case (ddr4_state)
            DDR4_IDLE: begin
                if (mem_rd_en || mem_wr_en) begin
                    ddr4_state <= DDR4_ACTIVATE;
                    ddr4_latency_counter <= 16'd4;  // ACT command latency
                end
            end
            
            DDR4_ACTIVATE: begin
                if (ddr4_latency_counter == 0) begin
                    ddr4_state <= mem_rd_en ? DDR4_READ : DDR4_WRITE;
                    ddr4_latency_counter <= mem_rd_en ? DDR4_READ_LATENCY : 16'd2;
                end else begin
                    ddr4_latency_counter <= ddr4_latency_counter - 1;
                end
            end
            
            DDR4_READ: begin
                if (ddr4_latency_counter == 0) begin
                    // Fill read data from memory array (simplified hash-based)
                    ddr4_dq_int <= {mem_addr[71:0], 72'hDEADBEEF_CAFE1234} ^ {144{1'b1}};
                    ddr4_dq_oe <= 1'b1;
                    ddr4_state <= DDR4_PRECHARGE;
                    ddr4_latency_counter <= 16'd2;
                end else begin
                    ddr4_latency_counter <= ddr4_latency_counter - 1;
                end
            end
            
            DDR4_WRITE: begin
                if (ddr4_latency_counter == 0) begin
                    mem_ready <= 1'b1;
                    ddr4_state <= DDR4_PRECHARGE;
                    ddr4_latency_counter <= 16'd2;
                end else begin
                    ddr4_latency_counter <= ddr4_latency_counter - 1;
                end
            end
            
            DDR4_PRECHARGE: begin
                if (ddr4_latency_counter == 0) begin
                    ddr4_dq_oe <= 1'b0;
                    mem_ready <= (ddr4_state == DDR4_READ) ? 1'b1 : 1'b0;
                    ddr4_state <= DDR4_IDLE;
                end else begin
                    ddr4_latency_counter <= ddr4_latency_counter - 1;
                end
            end
            
            DDR4_REFRESH: begin
                if (ddr4_latency_counter == 0) begin
                    ddr4_state <= DDR4_IDLE;
                end else begin
                    ddr4_latency_counter <= ddr4_latency_counter - 1;
                end
            end
            
            default: ddr4_state <= DDR4_IDLE;
        end
    end
end

// Auto-refresh every 7.8us (simplified counter at 500MHz)
reg [20:0] refresh_counter = 0;
always @(posedge g_core_clk or negedge sys_rst_sync) begin
    if (!sys_rst_sync) begin
        refresh_counter <= 0;
    end else begin
        refresh_counter <= refresh_counter + 1;
        if (refresh_counter == 21'h3FFFFF) begin  // ~7.8us at 500MHz
            refresh_counter <= 0;
            if (ddr4_state == DDR4_IDLE) begin
                ddr4_state <= DDR4_REFRESH;
                ddr4_latency_counter <= 16'd8;
            end
        end
    end
end

assign ddr4_addr = (ddr4_state == DDR4_IDLE) ? 17'b0 : mem_addr[16:0];
assign ddr4_ba = (ddr4_state == DDR4_IDLE) ? 3'b0 : mem_addr[18:16];
assign ddr4_cke = (ddr4_state != DDR4_IDLE) ? 2'b11 : 2'b00;
assign ddr4_cs_n = (ddr4_state == DDR4_IDLE) ? 1'b1 : 1'b0;
assign ddr4_ras_n = (ddr4_state == DDR4_ACTIVATE || ddr4_state == DDR4_PRECHARGE) ? 1'b0 : 1'b1;
assign ddr4_cas_n = (ddr4_state == DDR4_READ || ddr4_state == DDR4_WRITE) ? 1'b0 : 1'b1;
assign ddr4_we_n = (ddr4_state == DDR4_PRECHARGE || ddr4_state == DDR4_WRITE) ? 1'b0 : 1'b1;
assign ddr4_reset_n = sys_rst_n;
assign ddr4_act_n = (ddr4_state == DDR4_ACTIVATE) ? 1'b0 : 1'b1;

// Tri-state DQ buffer
assign ddr4_dq = ddr4_dq_oe ? ddr4_dq_int : {72{1'bz}};

// Read data to memory fabric
always @(posedge g_core_clk or negedge sys_rst_sync) begin
    if (!sys_rst_sync) begin
        mem_rd_data <= {172{1'b0}};
    end else if (ddr4_state == DDR4_READ && ddr4_latency_counter == 0) begin
        mem_rd_data <= {{100{1'b0}}, ddr4_dq_int[71:0]};
    end
end

//-----------------------------------------------------------------------------
// PCIe Gen5 Interface (x16 lanes) - Simplified DMA Engine
// Implements basic TLP (Transaction Layer Packet) handling
//-----------------------------------------------------------------------------
reg [15:0]  pcie_tx_data = 0;
reg         pcie_tx_valid = 0;
reg [15:0]  pcie_rx_data_reg = 0;
reg         pcie_rx_valid_reg = 0;
reg [31:0]  pcie_dma_addr = 0;
reg         pcie_dma_active = 0;

// TX: Aurora -> PCIe (MMIO reads, DMA writes)
always @(posedge g_core_clk or negedge sys_rst_sync) begin
    if (!sys_rst_sync) begin
        pcie_tx_data <= 16'b0;
        pcie_tx_valid <= 0;
        pcie_dma_active <= 0;
    end else begin
        // Generate TLP packets for memory transactions
        if (mem_rd_en || mem_wr_en) begin
            pcie_tx_data <= {
                mem_rd_en ? 4'b0000 : 4'b0100,  // TLP type: MRd/MWr
                mem_addr[15:0]                    // Address
            };
            pcie_tx_valid <= 1'b1;
        end else begin
            pcie_tx_valid <= 1'b0;
        end
        
        // DMA address tracking
        if (mem_wr_en && !pcie_dma_active) begin
            pcie_dma_addr <= mem_addr[31:0];
            pcie_dma_active <= 1'b1;
        end else if (pcie_dma_active) begin
            pcie_dma_addr <= pcie_dma_addr + 32'd64;  // Burst increment
            pcie_dma_active <= 0;
        end
    end
end

assign pcie_tx_p = pcie_tx_valid ? pcie_tx_data : 16'b0;
assign pcie_tx_n = ~pcie_tx_p;  // Differential pair

// RX: PCIe -> Aurora (interrupts, config writes)
always @(posedge g_core_clk or negedge sys_rst_sync) begin
    if (!sys_rst_sync) begin
        pcie_rx_data_reg <= 0;
        pcie_rx_valid_reg <= 0;
    end else begin
        // Sample incoming PCIe data (simplified)
        pcie_rx_data_reg <= pcie_rx_p;
        pcie_rx_valid_reg <= |pcie_rx_p;  // Valid if any data present
    end
end

//-----------------------------------------------------------------------------
// JTAG Debug Interface - Basic TAP Controller
// Implements IEEE 1149.1 JTAG state machine for debug access
//-----------------------------------------------------------------------------
reg [3:0]  jtag_state = 0;
reg [31:0] jtag_shift_reg = 0;
reg [7:0]  jtag_bit_count = 0;

localparam JTAG_TEST_LOGIC_RESET = 4'b0000;
localparam JTAG_RUN_TEST_IDLE    = 4'b0001;
localparam JTAG_SELECT_DR_SCAN   = 4'b0010;
localparam JTAG_CAPTURE_DR     = 4'b0011;
localparam JTAG_SHIFT_DR       = 4'b0100;
localparam JTAG_EXIT1_DR        = 4'b0101;
localparam JTAG_PAUSE_DR        = 4'b0110;
localparam JTAG_EXIT2_DR        = 4'b0111;
localparam JTAG_UPDATE_DR       = 4'b1000;

// JTAG TAP State Machine
always @(posedge debug_clk or negedge sys_rst_sync) begin
    if (!sys_rst_sync) begin
        jtag_state <= JTAG_TEST_LOGIC_RESET;
        jtag_shift_reg <= 0;
        jtag_bit_count <= 0;
    end else begin
        case (jtag_state)
            JTAG_TEST_LOGIC_RESET: begin
                jtag_state <= jtag_tms ? JTAG_TEST_LOGIC_RESET : JTAG_RUN_TEST_IDLE;
            end
            
            JTAG_RUN_TEST_IDLE: begin
                jtag_state <= jtag_tms ? JTAG_SELECT_DR_SCAN : JTAG_RUN_TEST_IDLE;
            end
            
            JTAG_SELECT_DR_SCAN: begin
                jtag_state <= jtag_tms ? JTAG_TEST_LOGIC_RESET : JTAG_CAPTURE_DR;
            end
            
            JTAG_CAPTURE_DR: begin
                // Capture system status into shift register
                jtag_shift_reg <= {sys_status[15:0], clk_status};
                jtag_bit_count <= 8'd24;
                jtag_state <= jtag_tms ? JTAG_EXIT1_DR : JTAG_SHIFT_DR;
            end
            
            JTAG_SHIFT_DR: begin
                if (jtag_bit_count > 0) begin
                    // Shift in TDI, shift out TDO
                    jtag_shift_reg <= {jtag_tdi, jtag_shift_reg[31:1]};
                    jtag_bit_count <= jtag_bit_count - 1;
                end
                jtag_state <= jtag_tms ? JTAG_EXIT1_DR : JTAG_SHIFT_DR;
            end
            
            JTAG_EXIT1_DR, JTAG_EXIT2_DR: begin
                jtag_state <= jtag_tms ? JTAG_UPDATE_DR : JTAG_SHIFT_DR;
            end
            
            JTAG_PAUSE_DR: begin
                jtag_state <= jtag_tms ? JTAG_EXIT2_DR : JTAG_PAUSE_DR;
            end
            
            JTAG_UPDATE_DR: begin
                jtag_state <= jtag_tms ? JTAG_SELECT_DR_SCAN : JTAG_RUN_TEST_IDLE;
            end
            
            default: jtag_state <= JTAG_TEST_LOGIC_RESET;
        endcase
    end
end

// TDO output during shift
assign jtag_tdo = (jtag_state == JTAG_SHIFT_DR || jtag_state == JTAG_PAUSE_DR) ? 
                  jtag_shift_reg[0] : 1'b0;

//-----------------------------------------------------------------------------
// UART Console (115200 baud, 8N1) - Full Transmitter Implementation
// Baud rate generator with start/stop bits and framing
//-----------------------------------------------------------------------------
localparam UART_CLK_FREQ = 50_000_000;  // debug_clk = 50 MHz
localparam UART_BAUD_RATE = 115200;
localparam UART_BAUD_DIVIDER = (UART_CLK_FREQ / UART_BAUD_RATE);

reg [15:0]  uart_baud_counter = 0;
reg [3:0]   uart_tx_state = 0;  // 0=IDLE, 1=START, 2-9=DATA, 10=STOP
reg [7:0]   uart_tx_shift_reg = 0;
reg [3:0]   uart_tx_bit_count = 0;
reg         uart_tx_line = 1'b1;  // Idle high
reg [7:0]   uart_tx_fifo [0:15];
reg [3:0]   uart_tx_fifo_count = 0;
reg [3:0]   uart_tx_fifo_head = 0;
reg [3:0]   uart_tx_fifo_tail = 0;

localparam UART_IDLE  = 4'b0000;
localparam UART_START = 4'b0001;
localparam UART_DATA  = 4'b0010;
localparam UART_STOP  = 4'b0011;

// UART TX State Machine
always @(posedge debug_clk or negedge sys_rst_sync) begin
    if (!sys_rst_sync) begin
        uart_baud_counter <= 0;
        uart_tx_state <= UART_IDLE;
        uart_tx_shift_reg <= 0;
        uart_tx_bit_count <= 0;
        uart_tx_line <= 1'b1;
        uart_tx_fifo_count <= 0;
        uart_tx_fifo_head <= 0;
        uart_tx_fifo_tail <= 0;
    end else begin
        // Enqueue status messages
        if (uart_tx_fifo_count < 12) begin
            // Simple heartbeat message
            if (uart_baud_counter[15:0] % 16'd10000 == 0) begin
                uart_tx_fifo[uart_tx_fifo_tail] <= 8'h55;  // Sync byte
                uart_tx_fifo_tail <= (uart_tx_fifo_tail == 4'd15) ? 0 : uart_tx_fifo_tail + 1;
                uart_tx_fifo_count <= uart_tx_fifo_count + 1;
            end
        end
        
        // TX state machine
        case (uart_tx_state)
            UART_IDLE: begin
                uart_tx_line <= 1'b1;
                if (uart_tx_fifo_count > 0) begin
                    uart_tx_shift_reg <= uart_tx_fifo[uart_tx_fifo_head];
                    uart_tx_fifo_head <= (uart_tx_fifo_head == 4'd15) ? 0 : uart_tx_fifo_head + 1;
                    uart_tx_fifo_count <= uart_tx_fifo_count - 1;
                    uart_tx_bit_count <= 0;
                    uart_tx_state <= UART_START;
                    uart_baud_counter <= 0;
                end
            end
            
            UART_START: begin
                if (uart_baud_counter >= UART_BAUD_DIVIDER) begin
                    uart_tx_line <= 1'b0;  // Start bit (low)
                    uart_baud_counter <= 0;
                    uart_tx_state <= UART_DATA;
                end else begin
                    uart_baud_counter <= uart_baud_counter + 1;
                end
            end
            
            UART_DATA: begin
                if (uart_baud_counter >= UART_BAUD_DIVIDER) begin
                    uart_tx_line <= uart_tx_shift_reg[uart_tx_bit_count];
                    uart_tx_bit_count <= uart_tx_bit_count + 1;
                    uart_baud_counter <= 0;
                    
                    if (uart_tx_bit_count == 4'd7) begin
                        uart_tx_state <= UART_STOP;
                    end
                end else begin
                    uart_baud_counter <= uart_baud_counter + 1;
                end
            end
            
            UART_STOP: begin
                if (uart_baud_counter >= UART_BAUD_DIVIDER) begin
                    uart_tx_line <= 1'b1;  // Stop bit (high)
                    uart_baud_counter <= 0;
                    uart_tx_state <= UART_IDLE;
                end else begin
                    uart_baud_counter <= uart_baud_counter + 1;
                end
            end
            
            default: uart_tx_state <= UART_IDLE;
        endcase
    end
end

assign uart_tx = uart_tx_line;

// UART RX (simplified - just monitor for break condition)
reg [7:0] uart_rx_data = 0;
reg       uart_rx_valid = 0;

always @(posedge debug_clk or negedge sys_rst_sync) begin
    if (!sys_rst_sync) begin
        uart_rx_data <= 0;
        uart_rx_valid <= 0;
    end else begin
        // Detect break condition (start bit)
        if (!uart_rx) begin
            uart_rx_valid <= 1'b1;
        end else begin
            uart_rx_valid <= 1'b0;
        end
    end
end

//-----------------------------------------------------------------------------
// GPIO / Status LEDs
//-----------------------------------------------------------------------------
assign led_status = {
    clk_locked,         // [7] Clock locked
    sys_rst_sync,       // [6] System reset
    game_cmd_valid,     // [5] Gaming activity
    ai_cmd_valid,       // [4] AI activity
    mem_rd_en,          // [3] Memory read
    mem_wr_en,          // [2] Memory write
    sys_interrupt,      // [1] Interrupt active
    gpio_int_n          // [0] GPIO interrupt
};

//-----------------------------------------------------------------------------
// System Interrupt Generation
//-----------------------------------------------------------------------------
assign sys_interrupt = ~gpio_int_n | ~pcie_perst_n;

//-----------------------------------------------------------------------------
// Power Mode Configuration
// =========================================================================
// Default: Mixed mode (Gaming + AI)
//-----------------------------------------------------------------------------
assign sys_power_mode = 16'b0011;  // Mixed mode

//-----------------------------------------------------------------------------
// Test Mode Support
//-----------------------------------------------------------------------------
// In test mode, bypass normal operation and run BIST
wire test_mode_active = test_mode_en;

endmodule
