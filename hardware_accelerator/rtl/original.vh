// --------------------------------------------------------
// --------------------------------------------------------
//   Neuron Wrapper Configuration
// --------------------------------------------------------
// --------------------------------------------------------

localparam NEURON_TYPE_G = "LIF";
localparam NEURON_STATE_DATA_WIDTH_G = 24; // fixed point format Q12.12
localparam NEURON_STATE_DECIMALS_G   = 12;

// --------------------------------------------------------
// --------------------------------------------------------
//   NEURON CONFIGURATION for LIF Neuron
// --------------------------------------------------------
// --------------------------------------------------------

localparam TAU_MEM_INV_DATA_WIDTH_G = 16; // data format UQ0.16
localparam TAU_MEM_INV_DECIMALS_G   = 16;
localparam TAU_MEM_INV_G = 0.01 * 2**TAU_MEM_INV_DECIMALS_G; // tau_mem_inv = 1/tau_mem, tau_mem = 10

localparam SPIKE_THRESHOLD_DATA_WIDTH_G = 11; // data format UQ1.10
localparam SPIKE_THRESHOLD_DECIMALS_G   = 10;
localparam SPIKE_THRESHOLD_G = 0.01 * 2**SPIKE_THRESHOLD_DECIMALS_G;

localparam RESET_VALUE_G = 0;

// A Python script to calculate the init file can be found in core/neurons/lif_neuron/
localparam RAM_LEAK_ADDR_WIDTH_G = 9; // 512 entries (for tau_inv=0.01)
localparam RAM_LEAK_DATA_WIDTH_G = 8; // data format UQ0.8
localparam RAM_LEAK_DECIMALS_G   = 8;
localparam RAM_LEAK_INIT_MEM_FILE_G = "./leak_factors.data";
