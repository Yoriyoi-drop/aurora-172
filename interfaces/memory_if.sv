`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team
//
// Create Date: 14 April 2026
// Design Name: AURORA-172 Memory Interface
// Module Name: memory_if
//
// Description:
//   Standard memory interface untuk AURORA-172 menggunakan SystemVerilog interface
//   Mendukung read/write operations dengan ready/valid handshake
//////////////////////////////////////////////////////////////////////////////////

interface memory_if #(
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 48
)();
    
    // Address and control signals
    logic [ADDR_WIDTH-1:0] addr;
    logic                  rd_en;
    logic                  wr_en;
    logic [DATA_WIDTH-1:0] wr_data;
    
    // Response signals
    logic [DATA_WIDTH-1:0] rd_data;
    logic                  ready;
    logic                  valid;
    
    // Modports untuk master dan slave
    modport master (
        output addr,
        output rd_en,
        output wr_en,
        output wr_data,
        input  rd_data,
        input  ready,
        output valid
    );
    
    modport slave (
        input  addr,
        input  rd_en,
        input  wr_en,
        input  wr_data,
        output rd_data,
        output ready,
        input  valid
    );
    
    // Clocking block untuk testbench
    clocking cb @(posedge clk);
        input  addr;
        input  rd_en;
        input  wr_en;
        input  wr_data;
        output rd_data;
        output ready;
        input  valid;
    endclocking
    
endinterface
