`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Verification Team
//
// Create Date: 14 April 2026
// Design Name: AURORA-172 UVM Testbench
// Module Name: uvm_testbench
//
// Description:
//   UVM-based testbench untuk AURORA-172 top-level module
//   Menggunakan UVM methodology untuk verification profesional
//////////////////////////////////////////////////////////////////////////////////

import uvm_pkg::*;
`include "uvm_macros.svh"

// Include interfaces
`include "memory_if.sv"
`include "axi_if.sv"

// ========================================================================
// UVM Components
// ========================================================================

// Memory transaction item
class memory_transaction extends uvm_sequence_item;
    rand bit [47:0] addr;
    rand bit [63:0] data;
    rand bit        read_write; // 0=read, 1=write
    rand bit [7:0]  burst_len;
    
    `uvm_object_utils_begin(memory_transaction)
        `uvm_field_int(addr, UVM_ALL_ON)
        `uvm_field_int(data, UVM_ALL_ON)
        `uvm_field_int(read_write, UVM_ALL_ON)
        `uvm_field_int(burst_len, UVM_ALL_ON)
    `uvm_object_utils_end
    
    constraint addr_c {
        addr < 48'h0000_0000_FFFF;
        burst_len <= 16;
    }
    
    function new(string name = "memory_transaction");
        super.new(name);
    endfunction
endclass

// Memory sequencer
class memory_sequencer extends uvm_sequencer #(memory_transaction);
    `uvm_component_utils(memory_sequencer)
    
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
endclass

// Memory driver
class memory_driver extends uvm_driver #(memory_transaction);
    virtual memory_if mem_vif;
    
    `uvm_component_utils(memory_driver)
    
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual memory_if)::get(this, "", "mem_vif", mem_vif)) begin
            `uvm_fatal("NOVIF", "Virtual interface not set for memory driver")
        end
    endfunction
    
    task run_phase(uvm_phase phase);
        memory_transaction trans;
        
        forever begin
            seq_item_port.get_next_item(trans);
            drive_transaction(trans);
            seq_item_port.item_done();
        end
    endtask
    
    task drive_transaction(memory_transaction trans);
        @(posedge mem_vif.clk);
        
        mem_vif.addr <= trans.addr;
        mem_vif.wr_data <= trans.data;
        
        if (trans.read_write == 0) begin // Read
            mem_vif.rd_en <= 1;
            mem_vif.wr_en <= 0;
        end else begin // Write
            mem_vif.rd_en <= 0;
            mem_vif.wr_en <= 1;
        end
        
        wait (mem_vif.ready);
        @(posedge mem_vif.clk);
        
        mem_vif.rd_en <= 0;
        mem_vif.wr_en <= 0;
    endtask
endclass

// Memory monitor
class memory_monitor extends uvm_monitor;
    virtual memory_if mem_vif;
    uvm_analysis_port #(memory_transaction) ap;
    
    `uvm_component_utils(memory_monitor)
    
    function new(string name, uvm_component parent);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction
    
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual memory_if)::get(this, "", "mem_vif", mem_vif)) begin
            `uvm_fatal("NOVIF", "Virtual interface not set for memory monitor")
        end
    endfunction
    
    task run_phase(uvm_phase phase);
        memory_transaction trans;
        
        forever begin
            @(posedge mem_vif.clk);
            if (mem_vif.rd_en || mem_vif.wr_en) begin
                trans = memory_transaction::type_id::create("trans");
                trans.addr = mem_vif.addr;
                trans.data = mem_vif.wr_data;
                trans.read_write = mem_vif.wr_en;
                ap.write(trans);
            end
        end
    endtask
endclass

// Memory agent
class memory_agent extends uvm_agent;
    memory_driver    driver;
    memory_sequencer sequencer;
    memory_monitor   monitor;
    
    `uvm_component_utils(memory_agent)
    
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        monitor = memory_monitor::type_id::create("monitor", this);
        
        if (get_is_active() == UVM_ACTIVE) begin
            driver = memory_driver::type_id::create("driver", this);
            sequencer = memory_sequencer::type_id::create("sequencer", this);
        end
    endfunction
    
    function void connect_phase(uvm_phase phase);
        if (get_is_active() == UVM_ACTIVE) begin
            driver.seq_item_port.connect(sequencer.seq_item_export);
        end
    endfunction
endclass

// Basic memory test sequence
class memory_basic_test_seq extends uvm_sequence #(memory_transaction);
    `uvm_object_utils(memory_basic_test_seq)
    
    function new(string name = "memory_basic_test_seq");
        super.new(name);
    endfunction
    
    task body();
        memory_transaction trans;
        
        repeat (100) begin
            trans = memory_transaction::type_id::create("trans");
            start_item(trans);
            assert(trans.randomize());
            finish_item(trans);
        end
    endtask
endclass

// Test environment
class aurora_env extends uvm_env;
    memory_agent mem_agent;
    
    `uvm_component_utils(aurora_env)
    
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mem_agent = memory_agent::type_id::create("mem_agent", this);
    endfunction
endclass

// Basic test
class aurora_basic_test extends uvm_test;
    aurora_env env;
    
    `uvm_component_utils(aurora_basic_test)
    
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = aurora_env::type_id::create("env", this);
    endfunction
    
    task run_phase(uvm_phase phase);
        memory_basic_test_seq seq;
        phase.raise_objection(this);
        
        seq = memory_basic_test_seq::type_id::create("seq");
        seq.start(env.mem_agent.sequencer);
        
        phase.drop_objection(this);
    endtask
endclass

// ========================================================================
// Top-level testbench
// ========================================================================

module uvm_tb_aurora_172;
    
    // Clock and reset
    reg         clk;
    reg         rst_n;
    
    // Memory interface
    memory_if mem_if();
    
    // DUT connections
    wire [47:0]        dut_mem_addr;
    wire               dut_mem_rd_en;
    wire               dut_mem_wr_en;
    wire [511:0]       dut_mem_wr_data;
    wire               dut_mem_ready;
    wire [511:0]       dut_mem_rd_data;
    
    // Connect interface to DUT
    assign mem_if.clk     = clk;
    assign mem_if.rst_n   = rst_n;
    assign mem_if.addr    = dut_mem_addr;
    assign mem_if.rd_en   = dut_mem_rd_en;
    assign mem_if.wr_en   = dut_mem_wr_en;
    assign mem_if.wr_data = dut_mem_wr_data[63:0];  // Use lower 64 bits
    assign mem_if.ready   = dut_mem_ready;
    assign mem_if.valid   = dut_mem_rd_en || dut_mem_wr_en;
    
    // DUT instantiation
    aurora_172_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .mem_addr(dut_mem_addr),
        .mem_rd_en(dut_mem_rd_en),
        .mem_wr_en(dut_mem_wr_en),
        .mem_wr_data(dut_mem_wr_data),
        .mem_rd_data(dut_mem_rd_data),
        .mem_ready(dut_mem_ready),
        // Other connections tied off for basic test
        .game_cmd_addr(48'h0),
        .game_cmd_data(32'h0),
        .game_cmd_valid(1'b0),
        .ai_cmd_addr(48'h0),
        .ai_cmd_data(64'h0),
        .ai_cmd_valid(1'b0),
        .sys_interrupt(1'b0),
        .sys_power_mode(16'h0)
    );
    
    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;  // 100 MHz clock
    end
    
    // Reset generation
    initial begin
        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
    end
    
    // UVM configuration
    initial begin
        uvm_config_db#(virtual memory_if)::set(null, "*", "mem_vif", mem_if);
        run_test("aurora_basic_test");
    end
    
endmodule
