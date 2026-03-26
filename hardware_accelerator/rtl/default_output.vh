/* Configuration for Output Core */

// --------------------------------------------------------
// --------------------------------------------------------
//   Neuron Wrapper Configuration
// --------------------------------------------------------
// --------------------------------------------------------

localparam OUT_CORE_NEURON_TYPE_G = "LIF";
localparam OUT_CORE_NEURON_STATE_DATA_WIDTH_G = 24; // fixed point format Q12.12
localparam OUT_CORE_NEURON_STATE_DECIMALS_G   = 12;

// --------------------------------------------------------
// --------------------------------------------------------
//   NEURON CONFIGURATION for LIF Neuron
// --------------------------------------------------------
// --------------------------------------------------------

localparam OUT_CORE_TAU_MEM_INV_DATA_WIDTH_G = 16; // data format UQ0.16
localparam OUT_CORE_TAU_MEM_INV_DECIMALS_G   = 16;
localparam OUT_CORE_TAU_MEM_INV_G = 0.001 * 2**TAU_MEM_INV_DECIMALS_G; // tau_mem_inv = 1/tau_mem, tau_mem = 10

// A Python script to calculate the init file can be found in core/neurons/lif/lutram_leak_factors.py
localparam OUT_CORE_RAM_LEAK_ADDR_WIDTH_G = 12; // 4096 entries (for tau_inv=0.001)
localparam OUT_CORE_RAM_LEAK_DATA_WIDTH_G = 8; // data format UQ0.8
localparam OUT_CORE_RAM_LEAK_DECIMALS_G   = 8;
localparam OUT_CORE_RAM_LEAK_INIT_MEM_FILE_G = "./leak_factors_output.data";
