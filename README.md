# 2D Convolution Hardware Accelerator

A high-performance, parameterized 2D convolution hardware accelerator implemented in SystemVerilog. Features 9-way parallel MAC operations, dual-buffered input memories, and AXI-Stream interfaces for efficient convolution processing.

## Architecture Overview
```
INPUT_TDATA ──┐
INPUT_TVALID ─┤
INPUT_TUSER ──┤──> Input Memories ──> 9x Parallel MACs ──> Output FIFO ──> OUTPUT_TDATA
INPUT_TREADY ─┘    (Dual-Buffered)     (Pipelined)         (Depth=C-1)     OUTPUT_TVALID
(control signals                                                           OUTPUT_TREADY
 indicating valid data)                                                    (control signals
                                                                            indicating valid output)                    
```

**Module Hierarchy:**
- `Conv` - Top-level convolution controller
- `input_mems` (x9) - Dual-buffered input memory banks
- `mac_pipe` - Pipelined multiply-accumulate unit
- `fifo_out` - AXI-Stream output FIFO

## Top-Level Parameters

| Parameter | Description | Range |
|-----------|-------------|-------|
| `INW` | Input data width (bits) | 4-32 |
| `R` | Input matrix rows | ≥ 2 |
| `C` | Input matrix columns | ≥ 2 |
| `MAXK` | Maximum kernel size | 2-9 |
| `OUTW` | Output width (auto-calculated) | - |

## Module Descriptions

### Conv.sv (Top-Level Convolution Module)

**Purpose:** Orchestrates parallel convolution computation across 9 memory banks using control logic for Input_Mems, MACs, and Output FIFO.

**Key Features:**
- 9-way parallel MAC operations
- 2-cycle pipeline (memory read + multiply)
- Dynamic masking for kernel boundaries
- 5-state FSM: WAIT_INPUTS → COMPUTE → DRAIN_PIPE → WRITE_RESULT → DONE_PULSE

**I/O Ports:**
```systemverilog
input  logic [INW-1:0]  INPUT_TDATA      // Input data stream
input  logic            INPUT_TVALID     // Input data valid
input  logic [K_BITS:0] INPUT_TUSER      // K value and new_W flag
output logic            INPUT_TREADY     // Ready to accept input

output logic [OUTW-1:0] OUTPUT_TDATA     // Output data stream
output logic            OUTPUT_TVALID    // Output data valid
input  logic            OUTPUT_TREADY    // Downstream ready signal
```

### input_mems.sv (Input Memory Module)

**Purpose:** Dual-buffered storage for input matrices X, weight matrices W, and bias B.

**Key Features:**
- Dual-bank architecture enables overlapped I/O and computation
- Matrix reuse capability (avoid reloading W and B)
- Row-major storage order
- AXI-Stream input with flow control

**I/O Ports:**
```systemverilog
// AXI-Stream Input Interface
input  [INW-1:0]        AXIS_TDATA       // Input data
input                   AXIS_TVALID      // Data valid
input  [K_BITS:0]       AXIS_TUSER       // Control: new_W and K value
output logic            AXIS_TREADY      // Ready for data

// Status and Control
output logic            inputs_loaded    // Memories contain valid data
input                   compute_finished // Computation complete signal
output logic [K_BITS-1:0] K              // Current kernel size
output logic signed [INW-1:0] B          // Bias value

// Memory Read Interfaces
input  [X_ADDR_BITS-1:0] X_read_addr     // X matrix read address
output logic signed [INW-1:0] X_data     // X matrix data output
input  [W_ADDR_BITS-1:0] W_read_addr     // W matrix read address
output logic signed [INW-1:0] W_data     // W matrix data output
```

**Protocol:**
- `AXIS_TUSER[0]` (new_W): 1=load new W&B, 0=reuse existing
- `AXIS_TUSER[K_BITS:1]`: Kernel size K (valid on first transfer)
- **Data Order if new_W=1:** W matrix (K×K) → B (1 value) → X matrix (R×C)
- **Data Order if new_W=0:** X matrix (R×C) only

### mac_pipe.sv (Pipelined MAC Unit)

**Purpose:** Pipelined multiply-accumulate with bias initialization.

**Key Features:**
- 2-stage pipeline with DesignWare multiplier support
- Accumulator with configurable initialization
- Signed arithmetic
- Enable control for selective accumulation

**I/O Ports:**
```systemverilog
input  signed [INW-1:0]  input0          // Multiplicand A
input  signed [INW-1:0]  input1          // Multiplicand B
input  signed [INW-1:0]  init_value      // Accumulator init value
output logic signed [OUTW-1:0] out       // Accumulated result
input                    init_acc        // Initialize accumulator
input                    input_valid     // Enable accumulation
```

### fifo_out.sv (Output FIFO)

**Purpose:** AXI-Stream compliant FIFO for output buffering.

**Key Features:**
- Dual-port memory with read/write bypass
- Configurable depth (typically C-1)
- Full/empty status generation
- Look-ahead addressing

**I/O Ports:**
```systemverilog
// Input Interface
input  [OUTW-1:0]       IN_AXIS_TDATA    // Data to store
input                   IN_AXIS_TVALID   // Write request
output logic            IN_AXIS_TREADY   // FIFO not full

// Output Interface
output logic [OUTW-1:0] OUT_AXIS_TDATA   // Data output
output logic            OUT_AXIS_TVALID  // Data available
input                   OUT_AXIS_TREADY  // Consumer ready
```

## Instantiation Example
```systemverilog
Conv #(
    .INW(24),
    .R(16),
    .C(17),
    .MAXK(9)
) conv_inst (
    .clk(clk),
    .reset(reset),
    
    // Input AXI-Stream Interface
    .INPUT_TDATA(input_data),
    .INPUT_TVALID(input_valid),
    .INPUT_TUSER(input_user),
    .INPUT_TREADY(input_ready),
    
    // Output AXI-Stream Interface
    .OUTPUT_TDATA(output_data),
    .OUTPUT_TVALID(output_valid),
    .OUTPUT_TREADY(output_ready)
);
```

## Files
```
.
├── Conv.sv                # Top-level convolution module
├── input_mems.sv          # Dual-buffered input memory module
├── mac_pipe.sv            # Pipelined MAC unit
├── fifo_out.sv            # Output FIFO
├── memory.sv              # Single-port memory primitive
├── memory_dual_port.sv    # Dual-port memory primitive
└── README.md              # This file
```
