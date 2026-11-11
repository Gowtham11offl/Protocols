// ============================================================================
// Module: apb_slave
// Description:
//   Implements an AMBA APB 32-word memory-mapped register slave.
//   Uses Direct-Style decoding (checks PSELX && PENABLE) with 0 wait-states.
// ============================================================================

module apb_slave (
    // ------------------------------------------------------------------------
    // System Clock & Reset
    // ------------------------------------------------------------------------
    input  wire        PCLK,      // APB Bus clock
    input  wire        PRESETn,   // Active-low asynchronous reset

    // ------------------------------------------------------------------------
    // APB Bus Inputs (Driven by APB Master)
    // ------------------------------------------------------------------------
    input  wire        PSELX,     // Slave select: 1 indicates this slave is targeted
    input  wire        PENABLE,   // Strobe indicating the ACCESS (second) phase
    input  wire        PWRITE,    // 1 = Master writes to slave, 0 = Master reads from slave
    input  wire [31:0] PADDR,     // Address bus (we use lower 5 bits for 32 registers)
    input  wire [31:0] PWDATA,    // 32-bit incoming write data from Master

    // ------------------------------------------------------------------------
    // APB Bus Outputs (Driven by Slave back to Master)
    // ------------------------------------------------------------------------
    output reg  [31:0] PRDATA,    // 32-bit read data sent back to Master
    output wire        PREADY     // Ready handshake signal
); 

    // ------------------------------------------------------------------------
    // Internal Storage: 32 registers of 32 bits each (mem[0] to mem[31])
    // ------------------------------------------------------------------------
    reg [31:0] mem [0:31]; 

    // ------------------------------------------------------------------------
    // Ready Logic:
    // This slave responds with 0 wait-states, so it permanently asserts PREADY = 1
    // ------------------------------------------------------------------------
    assign PREADY = 1'b1; 

    // Loop index variable for memory reset
    integer i; 

    // ------------------------------------------------------------------------
    // Synchronous WRITE Logic (Clocked)
    // Writes occur on clock edge only when PSEL, PENABLE, and PWRITE are all high
    // ------------------------------------------------------------------------
    always @(posedge PCLK or negedge PRESETn) begin 
        if (!PRESETn) begin
            // Reset condition: loop through all 32 memory registers and clear to 0
            for (i = 0; i < 32; i = i + 1) begin
                mem[i] <= 32'd0; 
            end
        end
        else begin
            // Write condition: valid ACCESS phase and direction is WRITE
            if (PSELX && PENABLE && PWRITE) begin
                // Use lower 5 bits of address (PADDR[4:0] = 0 to 31) to index register
                mem[PADDR[4:0]] <= PWDATA; 
            end
        end
    end

    // ------------------------------------------------------------------------
    // Combinational READ Logic
    // Drives PRDATA immediately when selected and in read mode
    // ------------------------------------------------------------------------
    always @(*) begin 
        // Read condition: selected by master and direction is READ (!PWRITE)
        if (PSELX && !PWRITE) begin 
            PRDATA = mem[PADDR[4:0]];  // Output contents of selected register
        end
        else begin 
            PRDATA = 32'd0;            // Default bus value when idle or writing
        end
    end

endmodule
