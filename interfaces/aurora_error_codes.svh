`ifndef AURORA_ERROR_CODES_SVH
`define AURORA_ERROR_CODES_SVH

// Error codes (prefixed with AURORA_ to avoid namespace collision)
`define AURORA_ERR_NONE                 8'h00
`define AURORA_ERR_ILLEGAL_OPCODE       8'h01
`define AURORA_ERR_MEMORY_FAULT         8'h02
`define AURORA_ERR_BUS_ERROR            8'h03
`define AURORA_ERR_TIMEOUT              8'h04
`define AURORA_ERR_OVERFLOW             8'h05
`define AURORA_ERR_UNDERFLOW            8'h06
`define AURORA_ERR_DIVIDE_BY_ZERO       8'h07
`define AURORA_ERR_PRIVILEGE_VIOLATION  8'h08
`define AURORA_ERR_PAGE_FAULT           8'h09
`define AURORA_ERR_ALIGNMENT_FAULT      8'h0A
`define AURORA_ERR_DEBUG_TRAP           8'h0B
`define AURORA_ERR_SYSTEM_CALL          8'h0C
`define AURORA_ERR_HARDWARE_FAULT       8'h0D
`define AURORA_ERR_POWER_FAULT          8'h0E
`define AURORA_ERR_THERMAL_FAULT        8'h0F
`define AURORA_ERR_OOB_ADDRESS          8'h10
`define AURORA_ERR_ACCESS_VIOLATION     8'h11
`define AURORA_ERR_CACHE_TIMEOUT        8'h12

`endif
