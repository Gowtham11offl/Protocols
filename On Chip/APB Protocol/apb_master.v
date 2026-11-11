// ============================================================================
// Module: apb_master
// Description:
//   Implements an AMBA APB (Advanced Peripheral Bus) Master.
//   Translates high-level CPU/Host requests (address, data, transfer, write)
//   into the standard APB 3-phase protocol (IDLE -> SETUP -> ACCESS).
// ============================================================================

module apb_master (
    // ------------------------------------------------------------------------
    // System Clock & Reset
    // ------------------------------------------------------------------------
    input wire        PCLK,       // Bus clock; all transfers sample on rising edge
    input wire        PRESETn,    // Active-low asynchronous reset

    // ------------------------------------------------------------------------
    // Host / CPU Core Interface (Commands coming into Master)
    // ------------------------------------------------------------------------
    input wire [31:0] data,       // 32-bit data to write (from Host/CPU)
    input wire [31:0] address,    // 32-bit destination register address (from Host/CPU)
    input wire        transfer,   // High pulse tells Master: "Start a transaction"
    input wire        write,      // Transfer direction: 1 = Write, 0 = Read

    // ------------------------------------------------------------------------
    // APB Slave Response Inputs (Signals coming back from Slave)
    // ------------------------------------------------------------------------
    input wire        PREADY,     // Slave ready handshake (1 = transfer complete, 0 = stall)
    input wire [31:0] PRDATA,     // Read data driven by Slave during read transfers

    // ------------------------------------------------------------------------
    // APB Bus Control & Data Outputs (Driven by Master to Slave)
    // ------------------------------------------------------------------------
    output reg  [31:0] PADDR,     // APB Address bus to the Slave
    output reg  [31:0] PWDATA,    // APB Write Data bus to the Slave
    output reg         PSELX,     // Peripheral Select: asserts high when slave is targeted
    output reg         PENABLE,   // Enable Strobe: asserts during ACCESS phase (phase 2)
    output reg         PWRITE,    // Bus direction: 1 = Write to Slave, 0 = Read from Slave
    output reg  [31:0] read_data  // Master output register holding captured PRDATA for Host
);

    // ------------------------------------------------------------------------
    // State Encoding (2-bit Binary Parameters)
    // ------------------------------------------------------------------------
    parameter idle   = 2'b00;     // Default inactive state on the bus
    parameter setup  = 2'b01;     // Cycle 1: Select slave, present address & write data
    parameter access = 2'b10;     // Cycle 2: Assert PENABLE and complete or extend transfer

    // State registers
    reg [1:0] current_state;      // Present State: Holds active state (sequential flip-flops)
    reg [1:0] next_state;         // Next State: Combinational decision of where to go next

    // ------------------------------------------------------------------------
    // 1. Present State Sequential Block
    // Updates the current state on every clock rising edge or resets to IDLE
    // ------------------------------------------------------------------------
    always @(posedge PCLK or negedge PRESETn) begin 
        if (!PRESETn)
            current_state <= idle;       // Asynchronous reset brings FSM to IDLE
        else
            current_state <= next_state; // Advance to the calculated next state on clock
    end

    // ------------------------------------------------------------------------
    // 2. Next State Combinational Logic Block
    // Pure combinational logic (always @*): calculates next_state based on inputs
    // ------------------------------------------------------------------------
    always @(*) begin 
        case (current_state)

            // IDLE State: Wait until host requests a transfer
            idle: begin
                if (transfer)
                    next_state = setup;  // Transfer requested: move to SETUP phase
                else
                    next_state = idle;   // No transfer: remain in IDLE
            end

            // SETUP State: Lasts exactly 1 clock cycle according to APB spec
            setup: begin 
                next_state = access;     // Always advance to ACCESS on next clock edge
            end

            // ACCESS State: Wait until slave is ready (PREADY == 1)
            access: begin 
                if (PREADY) begin
                    if (transfer)
                        next_state = setup; // PREADY=1 and new transfer queued -> Back-to-back!
                    else 
                        next_state = idle;  // PREADY=1 and no new transfer -> Return to IDLE
                end
                else begin
                    next_state = access;    // PREADY=0: Slave is busy, insert wait state (stay)
                end
            end

            // Safety default: return to IDLE if an illegal state occurs
            default: next_state = idle; 
        endcase
    end

    // ------------------------------------------------------------------------
    // 3. APB Output Signals & Read Data Capture (Sequential Block)
    // Registers outputs based on next_state for zero-latency phase alignment
    // ------------------------------------------------------------------------
    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin 
            // Initialize all APB bus outputs and internal capture registers to 0 on reset
            PSELX     <= 1'b0;
            PENABLE   <= 1'b0; 
            PWDATA    <= 32'd0;
            PADDR     <= 32'd0;
            PWRITE    <= 1'b0;
            read_data <= 32'd0; 
        end
        else begin 
            // ----------------------------------------------------------------
            // Capture Read Data:
            // When currently in ACCESS phase, slave asserts PREADY, and it's a Read,
            // latch the incoming PRDATA from the slave into read_data
            // ----------------------------------------------------------------
            if (current_state == access && PREADY && !PWRITE) begin 
                read_data <= PRDATA; 
            end

            // ----------------------------------------------------------------
            // Drive APB Bus Control Outputs:
            // Based on next_state so signals appear exactly on the entering clock edge
            // ----------------------------------------------------------------
            case (next_state)

                // When transitioning to IDLE: deassert select and enable
                idle: begin 
                    PSELX   <= 1'b0; 
                    PENABLE <= 1'b0; 
                end

                // When transitioning to SETUP: assert select, drive address, data, and direction
                setup: begin
                    PSELX   <= 1'b1;        // Select the slave
                    PENABLE <= 1'b0;        // PENABLE must be LOW during SETUP
                    PADDR   <= address;     // Latch address to bus
                    PWDATA  <= data;        // Latch write data to bus
                    PWRITE  <= write;       // Latch direction (1=Write, 0=Read)
                end

                // When transitioning to ACCESS: keep select high and assert enable
                access: begin 
                    PSELX   <= 1'b1;        // Keep slave selected
                    PENABLE <= 1'b1;        // Assert PENABLE high for ACCESS phase
                    // PADDR, PWDATA, and PWRITE remain held from SETUP (no reassignment needed)
                end

                // Safety default
                default: begin 
                    PSELX   <= 1'b0; 
                    PENABLE <= 1'b0;
                end

            endcase
        end
    end

endmodule
