`timescale 1ns / 1ps

// Include parameters (Icarus doesn't support import in interfaces)
`include "aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team
//
// Create Date: 14 April 2026
// Design Name: AURORA-172 AXI Interface
// Module Name: axi_if
//
// Description:
//   AXI4-like interface untuk interconnect AURORA-172
//   Mendukung 5-channel AXI protocol dengan SystemVerilog interface
//////////////////////////////////////////////////////////////////////////////////

interface axi_if #(
    parameter DATA_WIDTH = AURORA_DATA_WIDTH,    // Use standardized parameter
    parameter ADDR_WIDTH = AURORA_ADDR_WIDTH,
    parameter ID_WIDTH   = 4,     // OPTIMIZED: 8->4 (simpler routing)
    parameter STRB_WIDTH = DATA_WIDTH/8
)();
    
    // ========================================================================
    // Read Address Channel
    // ========================================================================
    logic [ID_WIDTH-1:0]    arid;
    logic [ADDR_WIDTH-1:0]  araddr;
    logic [7:0]             arlen;
    logic [2:0]             arsize;
    logic [1:0]             arburst;
    logic                   arlock;
    logic [3:0]             arcache;
    logic [2:0]             arprot;
    logic                   arvalid;
    logic                   arready;
    
    // ========================================================================
    // Read Data Channel
    // ========================================================================
    logic [ID_WIDTH-1:0]    rid;
    logic [DATA_WIDTH-1:0]  rdata;
    logic [1:0]             rresp;
    logic                   rlast;
    logic                   rvalid;
    logic                   rready;
    
    // ========================================================================
    // Write Address Channel
    // ========================================================================
    logic [ID_WIDTH-1:0]    awid;
    logic [ADDR_WIDTH-1:0]  awaddr;
    logic [7:0]             awlen;
    logic [2:0]             awsize;
    logic [1:0]             awburst;
    logic                   awlock;
    logic [3:0]             awcache;
    logic [2:0]             awprot;
    logic                   awvalid;
    logic                   awready;
    
    // ========================================================================
    // Write Data Channel
    // ========================================================================
    logic [ID_WIDTH-1:0]    wid;
    logic [DATA_WIDTH-1:0]  wdata;
    logic [STRB_WIDTH-1:0]  wstrb;
    logic                   wlast;
    logic                   wvalid;
    logic                   wready;
    
    // ========================================================================
    // Write Response Channel
    // ========================================================================
    logic [ID_WIDTH-1:0]    bid;
    logic [1:0]             bresp;
    logic                   bvalid;
    logic                   bready;
    
    // ========================================================================
    // Modports
    // ========================================================================
    
    // Master modport
    modport master (
        // Read Address
        output arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid,
        input  arready,
        // Read Data
        input  rid, rdata, rresp, rlast, rvalid,
        output rready,
        // Write Address
        output awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awvalid,
        input  awready,
        // Write Data
        output wid, wdata, wstrb, wlast, wvalid,
        input  wready,
        // Write Response
        input  bid, bresp, bvalid,
        output bready
    );
    
    // Slave modport
    modport slave (
        // Read Address
        input  arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid,
        output arready,
        // Read Data
        output rid, rdata, rresp, rlast, rvalid,
        input  rready,
        // Write Address
        input  awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awvalid,
        output awready,
        // Write Data
        input  wid, wdata, wstrb, wlast, wvalid,
        output wready,
        // Write Response
        output bid, bresp, bvalid,
        input  bready
    );
    
    // Monitor modport untuk testbench
    modport monitor (
        input  arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arvalid, arready,
        input  rid, rdata, rresp, rlast, rvalid, rready,
        input  awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awvalid, awready,
        input  wid, wdata, wstrb, wlast, wvalid, wready,
        input  bid, bresp, bvalid, bready
    );
    
endinterface
