// Lint-only black-box stand-in for the Vivado xpm_memory_spram library macro (NOT part of the bundle).
/* verilator lint_off UNUSED */
/* verilator lint_off UNDRIVEN */
module xpm_memory_spram #(
  parameter int ADDR_WIDTH_A = 6, parameter int AUTO_SLEEP_TIME = 0, parameter int BYTE_WRITE_WIDTH_A = 32,
  parameter ECC_MODE = "no_ecc", parameter MEMORY_INIT_FILE = "none", parameter MEMORY_INIT_PARAM = "0",
  parameter MEMORY_OPTIMIZATION = "true", parameter MEMORY_PRIMITIVE = "auto", parameter int MEMORY_SIZE = 2048,
  parameter int MESSAGE_CONTROL = 0, parameter int READ_DATA_WIDTH_A = 32, parameter int READ_LATENCY_A = 2,
  parameter READ_RESET_VALUE_A = "0", parameter int USE_MEM_INIT = 1, parameter WAKEUP_TIME = "disable_sleep",
  parameter int WRITE_DATA_WIDTH_A = 32, parameter WRITE_MODE_A = "read_first"
) (
  output logic dbiterra, output logic [READ_DATA_WIDTH_A-1:0] douta, output logic sbiterra,
  input logic [ADDR_WIDTH_A-1:0] addra, input logic clka, input logic [WRITE_DATA_WIDTH_A-1:0] dina,
  input logic ena, input logic injectdbiterra, input logic injectsbiterra, input logic regcea,
  input logic rsta, input logic sleep, input logic [WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A-1:0] wea
);
  assign douta = '0; assign dbiterra = 1'b0; assign sbiterra = 1'b0;
endmodule
