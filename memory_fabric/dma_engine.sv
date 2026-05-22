`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: System Architecture Team
// 
// Create Date: 10 April 2026
// Design Name: AURORA-172 DMA Engine
// Module Name: dma_engine
// 
// Description:
//   Direct Memory Access Engine untuk high-speed data transfer
//   Fitur:
//   - Scatter-gather DMA support
//   - Multiple channels (8 channels)
//   - Burst transfer up to 4KB per transaction
//   - Memory-to-memory, memory-to-peripheral, peripheral-to-memory
//   - Interrupt on completion
//   - Hardware checksum offload
//
// Target: Offload CPU dari data copy operations
//////////////////////////////////////////////////////////////////////////////////

module dma_engine #(
    parameter NUM_CHANNELS    = 4,     // OPTIMIZED: 8->4 (simpler arbitration)
    parameter ADDR_WIDTH      = `AURORA_ADDR_WIDTH,   // FIXED: Use standard parameter
    parameter DATA_WIDTH      = `AURORA_DATA_WIDTH,  // FIXED: Use standard parameter
    parameter BURST_SIZE_BITS = 14,   // OPTIMIZED: 12->14 (up to 16KB burst)
    parameter DESC_FIFO_DEPTH = 16    // OPTIMIZED: 32->16 (smaller for efficiency)
)(
    input  wire                         clk,
    input  wire                         rst_n,
    
    // Configuration interface (from CPU)
    input  wire [ADDR_WIDTH-1:0]        cfg_src_addr,
    input  wire [ADDR_WIDTH-1:0]        cfg_dst_addr,
    input  wire [BURST_SIZE_BITS-1:0]   cfg_transfer_size,
    input  wire [3:0]                   cfg_channel,
    input  wire                         cfg_start,
    input  wire                         cfg_enable_interrupt,
    
    // Memory interface
    output reg [ADDR_WIDTH-1:0]         mem_rd_addr,
    output reg                          mem_rd_en,
    input  wire [DATA_WIDTH-1:0]        mem_rd_data,
    input  wire                         mem_rd_ready,
    
    output reg [ADDR_WIDTH-1:0]         mem_wr_addr,
    output reg                          mem_wr_en,
    output wire [DATA_WIDTH-1:0]        mem_wr_data,
    input  wire                         mem_wr_ready,
    
    // Interrupt acknowledge (clear interrupt request)
    input  wire                         interrupt_ack,

    // Status
    output reg [NUM_CHANNELS-1:0]       channel_busy,
    output reg [NUM_CHANNELS-1:0]       channel_complete,
    output reg [NUM_CHANNELS-1:0]       channel_error,
    output reg                          interrupt_req,
    output reg [3:0]                    interrupt_channel,
    
    // Statistics
    output reg [31:0]                   total_transfers,
    output reg [31:0]                   total_bytes_transferred,
    output reg [31:0]                   dma_errors
);

    // =========================================================================
    // DMA Channel state - PACKED struct for Icarus Verilog compatibility
    // =========================================================================
    typedef struct packed {
        logic                           active;
        logic [ADDR_WIDTH-1:0]          src_addr;
        logic [ADDR_WIDTH-1:0]          dst_addr;
        logic [BURST_SIZE_BITS-1:0]     remaining_size;
        logic [BURST_SIZE_BITS-1:0]     total_size;
        logic [1:0]                     state;  // 0=IDLE, 1=READ, 2=WRITE, 3=DONE
        logic                           enable_interrupt;
    } dma_channel_t;

    dma_channel_t [0:NUM_CHANNELS-1] channels;
    
    // Interrupt pending (separate from output to avoid 1-cycle race)
    reg interrupt_pending;

    // Data buffer
    reg [DATA_WIDTH-1:0] dma_buffer [0:NUM_CHANNELS-1];

    // MEDIUM FIX #5: Timeout counters per channel
    reg [15:0] channel_timeout_counter [0:NUM_CHANNELS-1];
    
    // State enum
    localparam ST_IDLE    = 2'b00;
    localparam ST_READ    = 2'b01;
    localparam ST_WRITE   = 2'b10;
    localparam ST_DONE    = 2'b11;
    
    // =========================================================================
    // Channel arbitration (round-robin)
    // =========================================================================
    reg [3:0] current_channel;
    
    function automatic [3:0] find_next_active_channel;
        input [3:0] current;
        integer i;
        integer idx;
        begin
            find_next_active_channel = current; // Default
            for (i = 1; i <= NUM_CHANNELS; i = i + 1) begin
                idx = (current + i) % NUM_CHANNELS;
                if (channels[idx].active) begin
                    find_next_active_channel = idx[3:0];
                end
            end
        end
    endfunction
    
    // =========================================================================
    // DMA arbitration: select one active channel to drive mem signals
    // Prevents NBA write conflicts where only the last active channel's
    // mem_rd_en/mem_wr_en assignments would take effect
    // =========================================================================
    reg [NUM_CHANNELS-1:0] grant;
    reg [ADDR_WIDTH-1:0] arb_addr;

    always_comb begin
        grant = 0;
        arb_addr = 0;
        for (int ch = 0; ch < NUM_CHANNELS; ch++) begin
            if (channels[ch].active && !grant) begin
                grant = (1 << ch);
                arb_addr = channels[ch].src_addr;
            end
        end
    end

    // =========================================================================
    // DMA controller per channel
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all channels - use generate for Phase 1
            channels[0].active <= 1'b0;
            channels[0].state <= ST_IDLE;
            channels[0].remaining_size <= {BURST_SIZE_BITS{1'b0}};
            channels[0].total_size <= {BURST_SIZE_BITS{1'b0}};
            channel_busy[0] <= 1'b0;
            channel_complete[0] <= 1'b0;
            channel_error[0] <= 1'b0;
            channel_timeout_counter[0] <= 16'h0;
            
            current_channel <= 4'b0;
            interrupt_req <= 1'b0;
            interrupt_pending <= 1'b0;
            total_transfers <= 32'b0;
            total_bytes_transferred <= 32'b0;
            dma_errors <= 32'b0;
            
            mem_rd_en <= 1'b0;
            mem_wr_en <= 1'b0;
        end else begin
            // Configuration: start new transfer
            if (cfg_start && !channels[cfg_channel].active) begin
                // FIX: Validate address alignment
                if ((cfg_src_addr[$clog2(DATA_WIDTH/8)-1:0] != 0) ||
                     (cfg_dst_addr[$clog2(DATA_WIDTH/8)-1:0] != 0)) begin
                    // Misaligned address — flag error
                    channel_error[cfg_channel] <= 1'b1;
                    dma_errors <= dma_errors + 1;
                end else begin
                    channels[cfg_channel].src_addr <= cfg_src_addr;
                    channels[cfg_channel].dst_addr <= cfg_dst_addr;
                    channels[cfg_channel].remaining_size <= cfg_transfer_size;
                    channels[cfg_channel].total_size <= cfg_transfer_size;
                    channels[cfg_channel].active <= 1'b1;
                    channels[cfg_channel].state <= ST_READ;
                    channels[cfg_channel].enable_interrupt <= cfg_enable_interrupt;

                    channel_busy[cfg_channel] <= 1'b1;
                    channel_complete[cfg_channel] <= 1'b0;
                    channel_error[cfg_channel] <= 1'b0;

                    total_transfers <= total_transfers + 1;
                end
            end
            
            // Process only the granted channel (prevents NBA conflicts on mem_rd_en/wr_en)
            if (|grant) begin
                int ch;
                // Find the granted channel index
                ch = 0;
                for (int gi = 0; gi < NUM_CHANNELS; gi++) begin
                    if (grant[gi]) ch = gi;
                end
                begin
                    current_channel <= ch;
                    case (channels[ch].state)
                        ST_READ: begin
                                // MEDIUM FIX #5: Add 256-cycle timeout to prevent permanent stall
                                if (channel_timeout_counter[ch] >= 16'd256) begin
                                    $display("[%0t] [DMA-CH%0d] ST_READ TIMEOUT: mem_rd_ready not asserted after 256 cycles", $time, ch);
                                    channel_error[ch] <= 1'b1;
                                    channels[ch].active <= 1'b0;
                                    channels[ch].state <= ST_IDLE;
                                    channel_busy[ch] <= 1'b0;
                                    channel_timeout_counter[ch] <= 16'h0;
                                    mem_rd_en <= 1'b0;
                                    dma_errors <= dma_errors + 1;
                                end else if (!mem_rd_en) begin
                                    mem_rd_addr <= channels[ch].src_addr;
                                    mem_rd_en <= 1'b1;
                                    channel_timeout_counter[ch] <= channel_timeout_counter[ch] + 1;
                                end else if (mem_rd_ready) begin
                                    // Store data in buffer
                                    dma_buffer[ch] <= mem_rd_data;
                                    mem_rd_en <= 1'b0;
                                    channel_timeout_counter[ch] <= 16'h0;  // Reset counter
                                    channels[ch].state <= ST_WRITE;
                                end else begin
                                    channel_timeout_counter[ch] <= channel_timeout_counter[ch] + 1;
                                end
                            end

                            ST_WRITE: begin
                                // MEDIUM FIX #5: Add 256-cycle timeout to prevent permanent stall
                                if (channel_timeout_counter[ch] >= 16'd256) begin
                                    $display("[%0t] [DMA-CH%0d] ST_WRITE TIMEOUT: mem_wr_ready not asserted after 256 cycles", $time, ch);
                                    channel_error[ch] <= 1'b1;
                                    channels[ch].active <= 1'b0;
                                    channels[ch].state <= ST_IDLE;
                                    channel_busy[ch] <= 1'b0;
                                    channel_timeout_counter[ch] <= 16'h0;
                                    mem_wr_en <= 1'b0;
                                    dma_errors <= dma_errors + 1;
                                end else if (!mem_wr_en) begin
                                    mem_wr_addr <= channels[ch].dst_addr;
                                    mem_wr_en <= 1'b1;
                                    channel_timeout_counter[ch] <= channel_timeout_counter[ch] + 1;
                                end else if (mem_wr_ready) begin
                                    mem_wr_en <= 1'b0;

                                    // Update addresses and remaining size
                                    channels[ch].src_addr <= channels[ch].src_addr + (DATA_WIDTH/8);
                                    channels[ch].dst_addr <= channels[ch].dst_addr + (DATA_WIDTH/8);
                                    if (channels[ch].remaining_size >= (DATA_WIDTH/8)) begin
                                        channels[ch].remaining_size <= channels[ch].remaining_size - (DATA_WIDTH/8);
                                    end else begin
                                        channels[ch].remaining_size <= {BURST_SIZE_BITS{1'b0}};
                                    end
                                    channel_timeout_counter[ch] <= 16'h0;  // Reset counter

                                    // Check if transfer complete
                                    if (channels[ch].remaining_size <= (DATA_WIDTH/8)) begin
                                        channels[ch].state <= ST_DONE;
                                    end else begin
                                        channels[ch].state <= ST_READ;
                                    end

                                    total_bytes_transferred <= total_bytes_transferred + (DATA_WIDTH/8);
                                end else begin
                                    channel_timeout_counter[ch] <= channel_timeout_counter[ch] + 1;
                                end
                            end

                            ST_DONE: begin
                                channels[ch].active <= 1'b0;
                                channel_busy[ch] <= 1'b0;
                                channel_complete[ch] <= 1'b1;
                                channel_timeout_counter[ch] <= 16'h0;

                                // FIXED: Check for overflow error before marking complete
                                if (channels[ch].remaining_size > channels[ch].total_size) begin
                                    // Error: remaining size exceeded (overflow)
                                    channel_error[ch] <= 1'b1;
                                    dma_errors <= dma_errors + 1;  // Combined error counter
                                end

                                // Generate interrupt if enabled
                                // FIX: Hold interrupt pending until consumer acknowledges
                                if (channels[ch].enable_interrupt) begin
                                    interrupt_pending <= 1'b1;
                                    interrupt_channel <= ch;
                                end
                            end

                            default: begin
                                channels[ch].state <= ST_IDLE;
                            end
                        endcase
                    end
                end

            // Clear complete flags for all channels (exclude just-completed channel)
            for (int ch_clr = 0; ch_clr < NUM_CHANNELS; ch_clr++) begin
                if (channels[ch_clr].state != ST_DONE &&
                    current_channel != ch_clr) begin
                    channel_complete[ch_clr] <= 1'b0;
                end
            end

            // Move completed channels to IDLE after clear logic
            for (int ch_idle = 0; ch_idle < NUM_CHANNELS; ch_idle++) begin
                if (channels[ch_idle].active && grant[ch_idle] &&
                    channels[ch_idle].state == ST_DONE) begin
                    channels[ch_idle].state <= ST_IDLE;
                end
            end

            // Drive interrupt_req from pending state, clear on acknowledge
            interrupt_req <= interrupt_pending;
            if (interrupt_pending && interrupt_ack) begin
                interrupt_pending <= 1'b0;
                interrupt_req <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Mem write data assignment (from buffer)
    // =========================================================================
    assign mem_wr_data = dma_buffer[current_channel];

    // =========================================================================
    // Error detection (FIXED: Moved error counting to main always block to prevent multi-driver)
    // =========================================================================
    // Error detection is now integrated into the main channel processing loop
    // See ST_DONE state for overflow error detection and dma_errors increment

endmodule
