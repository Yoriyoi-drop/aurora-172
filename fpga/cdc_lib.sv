`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 Clock Domain Crossing Library
// Module Name: cdc_lib
//
// Description:
//   Kumpulan modul Clock Domain Crossing (CDC) untuk desain multi-clock
//   AURORA-172 memiliki 5 domain clock berbeda, sehingga CDC yang aman
//   sangat kritis untuk mencegah metastability dan data corruption.
//
// Modules:
//   - cdc_synchronizer: 2-flop synchronizer untuk single-bit signals
//   - cdc_pulse_synchronizer: Pulse synchronizer dengan handshake
//   - cdc_fifo_1bit: 1-bit wide FIFO untuk multi-bit data
//   - cdc_grey_code: Gray code encoder/decoder untuk address pointers
//
// Target: Xilinx Versal ACAP (VP1802)
// Tool: Vivado 2024.1+
//////////////////////////////////////////////////////////////////////////////////

//=============================================================================
// 1. BASIC 2-FLOP SYNCHRONIZER (untuk single-bit signals)
//=============================================================================
module cdc_synchronizer #(
    parameter RESET_VALUE = 1'b0
)(
    input  wire src_clk,
    input  wire dst_clk,
    input  wire src_rst_n,
    input  wire dst_rst_n,
    input  wire src_data,
    output wire dst_data
);

// Synchronizer chain di destination clock domain
reg [1:0] sync_stage = 2'b00;

always @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n)
        sync_stage <= {RESET_VALUE, RESET_VALUE};
    else
        sync_stage <= {sync_stage[0], src_data};
end

assign dst_data = sync_stage[1];

// Metastability hardening: gunakan register dengan delay yang lebih panjang
// Xilinx attribute untuk mencegah optimasi
(* ASYNC_REG = "TRUE" *)
(* DONT_TOUCH = "TRUE" *)
reg metastability_hardened;

always @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n)
        metastability_hardened <= RESET_VALUE;
    else
        metastability_hardened <= sync_stage[1];
end

endmodule

//=============================================================================
// 2. PULSE SYNCHRONIZER (untuk sinyal pulse satu-siklus)
//=============================================================================
module cdc_pulse_synchronizer (
    input  wire src_clk,
    input  wire dst_clk,
    input  wire src_rst_n,
    input  wire dst_rst_n,
    input  wire src_pulse,
    output wire dst_pulse,
    output wire dst_busy
);

// Toggle flip-flop di source domain
reg src_toggle = 0;
always @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n)
        src_toggle <= 0;
    else if (src_pulse)
        src_toggle <= ~src_toggle;
end

// Synchronize toggle ke destination domain
wire dst_toggle_sync;
cdc_synchronizer #(
    .RESET_VALUE(1'b0)
) sync_toggle (
    .src_clk    (src_clk),
    .dst_clk    (dst_clk),
    .src_rst_n  (src_rst_n),
    .dst_rst_n  (dst_rst_n),
    .src_data   (src_toggle),
    .dst_data   (dst_toggle_sync)
);

// Detect perubahan di destination domain
reg dst_toggle_d = 0;
always @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n)
        dst_toggle_d <= 0;
    else
        dst_toggle_d <= dst_toggle_sync;
end

assign dst_pulse = dst_toggle_sync ^ dst_toggle_d;
assign dst_busy = 1'b0;  // Simplified

endmodule

//=============================================================================
// 3. GRAY CODE COUNTER (untuk FIFO pointers)
//=============================================================================
module cdc_grey_code #(
    parameter WIDTH = 4
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             increment,
    output wire [WIDTH-1:0] binary,
    output wire [WIDTH-1:0] gray
);

reg [WIDTH-1:0] binary_reg = 0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        binary_reg <= 0;
    else if (increment)
        binary_reg <= binary_reg + 1;
end

assign binary = binary_reg;

// Binary to Gray code conversion
assign gray = binary_reg ^ (binary_reg >> 1);

endmodule

//=============================================================================
// 4. ASYNC FIFO (untuk multi-bit data transfer antar clock domain)
//=============================================================================
module cdc_fifo #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 4,  // 2^ADDR_DEPTH entries
    parameter DEPTH = (1 << ADDR_WIDTH)
)(
    // Write port (source clock domain)
    input  wire                     wr_clk,
    input  wire                     wr_rst_n,
    input  wire [DATA_WIDTH-1:0]    wr_data,
    input  wire                     wr_en,
    output wire                     wr_full,

    // Read port (destination clock domain)
    input  wire                     rd_clk,
    input  wire                     rd_rst_n,
    output wire [DATA_WIDTH-1:0]    rd_data,
    output wire                     rd_valid,
    input  wire                     rd_en
);

// Memory array
reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

// Write/read pointers (binary)
wire [ADDR_WIDTH-1:0] wr_ptr_bin;
wire [ADDR_WIDTH-1:0] rd_ptr_bin;

// Gray code pointers
wire [ADDR_WIDTH:0]   wr_ptr_gray;  // +1 bit untuk full detection
wire [ADDR_WIDTH:0]   rd_ptr_gray;

// Synchronized pointers
wire [ADDR_WIDTH:0]   wr_ptr_gray_sync;
wire [ADDR_WIDTH:0]   rd_ptr_gray_sync;

//=============================================================================
// Write side
//=============================================================================
cdc_grey_code #(
    .WIDTH(ADDR_WIDTH + 1)
) wr_gray_counter (
    .clk        (wr_clk),
    .rst_n      (wr_rst_n),
    .increment  (wr_en && !wr_full),
    .binary     (),
    .gray       (wr_ptr_gray)
);

// Synchronize write pointer to read domain
cdc_synchronizer #(
    .RESET_VALUE(1'b0)
) sync_wr_ptr [ADDR_WIDTH:0](
    .src_clk    (wr_clk),
    .dst_clk    (rd_clk),
    .src_rst_n  (wr_rst_n),
    .dst_rst_n  (rd_rst_n),
    .src_data   (wr_ptr_gray),
    .dst_data   (wr_ptr_gray_sync)
);

// Write data to memory
always @(posedge wr_clk) begin
    if (wr_en && !wr_full)
        mem[wr_ptr_bin] <= wr_data;
end

// Full detection: bandingkan gray pointers
assign wr_full = (wr_ptr_gray == {~rd_ptr_gray_sync[ADDR_WIDTH:ADDR_WIDTH-1],
                                   rd_ptr_gray_sync[ADDR_WIDTH-2:0]});

//=============================================================================
// Read side
//=============================================================================
cdc_grey_code #(
    .WIDTH(ADDR_WIDTH + 1)
) rd_gray_counter (
    .clk        (rd_clk),
    .rst_n      (rd_rst_n),
    .increment  (rd_en && rd_valid),
    .binary     (),
    .gray       (rd_ptr_gray)
);

// Synchronize read pointer to write domain
cdc_synchronizer #(
    .RESET_VALUE(1'b0)
) sync_rd_ptr [ADDR_WIDTH:0](
    .src_clk    (rd_clk),
    .dst_clk    (wr_clk),
    .src_rst_n  (rd_rst_n),
    .dst_rst_n  (wr_rst_n),
    .src_data   (rd_ptr_gray),
    .dst_data   (rd_ptr_gray_sync)
);

// Read data from memory
assign rd_data = mem[rd_ptr_bin];
assign rd_valid = (rd_ptr_gray != wr_ptr_gray_sync);

// Extract binary pointers using proper Gray-to-binary conversion
function automatic [ADDR_WIDTH:0] gray_to_binary;
    input [ADDR_WIDTH:0] gray;
    integer g2b_i;
    begin
        gray_to_binary[ADDR_WIDTH] = gray[ADDR_WIDTH];
        for (g2b_i = ADDR_WIDTH - 1; g2b_i >= 0; g2b_i = g2b_i - 1) begin
            gray_to_binary[g2b_i] = gray_to_binary[g2b_i + 1] ^ gray[g2b_i];
        end
    end
endfunction

assign wr_ptr_bin = gray_to_binary(wr_ptr_gray)[ADDR_WIDTH-1:0];
assign rd_ptr_bin = gray_to_binary(rd_ptr_gray)[ADDR_WIDTH-1:0];

endmodule

//=============================================================================
// 5. HANDSHAKE SYNCHRONIZER (untuk transfer data terkontrol)
//=============================================================================
module cdc_handshake #(
    parameter DATA_WIDTH = 32
)(
    // Source domain
    input  wire                     src_clk,
    input  wire                     src_rst_n,
    input  wire [DATA_WIDTH-1:0]    src_data,
    input  wire                     src_valid,
    output wire                     src_ready,

    // Destination domain
    input  wire                     dst_clk,
    input  wire                     dst_rst_n,
    output wire [DATA_WIDTH-1:0]    dst_data,
    output wire                     dst_valid,
    input  wire                     dst_ready
);

// Request/acknowledge signals
reg src_req = 0;
reg dst_ack = 0;
reg data_latched = 0;

// Latch data saat valid
reg [DATA_WIDTH-1:0] data_reg = 0;
always @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n) begin
        data_reg <= 0;
    end else if (src_valid && src_ready) begin
        data_reg <= src_data;
    end
end

// Source request
always @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n)
        src_req <= 0;
    else if (src_valid && src_ready)
        src_req <= ~src_req;
end

// Synchronize request ke destination
wire dst_req_sync;
cdc_synchronizer #(
    .RESET_VALUE(1'b0)
) sync_req (
    .src_clk    (src_clk),
    .dst_clk    (dst_clk),
    .src_rst_n  (src_rst_n),
    .dst_rst_n  (dst_rst_n),
    .src_data   (src_req),
    .dst_data   (dst_req_sync)
);

// Destination acknowledge
always @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n)
        dst_ack <= 0;
    else if (dst_valid && dst_ready)
        dst_ack <= ~dst_ack;
end

// Synchronize acknowledge ke source
wire src_ack_sync;
cdc_synchronizer #(
    .RESET_VALUE(1'b0)
) sync_ack (
    .src_clk    (dst_clk),
    .dst_clk    (src_clk),
    .src_rst_n  (dst_rst_n),
    .dst_rst_n  (src_rst_n),
    .src_data   (dst_ack),
    .dst_data   (src_ack_sync)
);

// Control logic
assign src_ready = (src_req == src_ack_sync);
assign dst_valid = (dst_req_sync != dst_ack) && data_latched;

// Data latch di destination
always @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n) begin
        data_latched <= 0;
    end else if (dst_req_sync != dst_ack) begin
        data_latched <= 1;
    end else if (dst_ready) begin
        data_latched <= 0;
    end
end

assign dst_data = data_reg;

endmodule

//=============================================================================
// 6. MULTIBIT MUXED SYNCHRONIZER (untuk bus data lebar)
//=============================================================================
module cdc_muxed_synchronizer #(
    parameter DATA_WIDTH = 64
)(
    input  wire                     src_clk,
    input  wire                     dst_clk,
    input  wire                     src_rst_n,
    input  wire                     dst_rst_n,
    input  wire [DATA_WIDTH-1:0]    src_data,
    input  wire                     src_valid,
    output wire [DATA_WIDTH-1:0]    dst_data,
    output wire                     dst_valid
);

// Gunakan handshake synchronizer
cdc_handshake #(
    .DATA_WIDTH(DATA_WIDTH)
) handshake_sync (
    .src_clk        (src_clk),
    .src_rst_n      (src_rst_n),
    .src_data       (src_data),
    .src_valid      (src_valid),
    .src_ready      (),
    .dst_clk        (dst_clk),
    .dst_rst_n      (dst_rst_n),
    .dst_data       (dst_data),
    .dst_valid      (dst_valid),
    .dst_ready      (1'b1)  // Always ready
);

endmodule
