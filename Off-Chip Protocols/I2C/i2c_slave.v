// ============================================================================
// Module: i2c_slave_model
// File:   i2c_slave_model.v
// Location: C:\Users\Gowtham\OneDrive\Documents\VLSI\Protocols\I2C\
// Description:
//   A complete, synthesizable I2C Slave Model with internal memory (like an EEPROM).
//   Features:
//     - 7-bit slave address matching (default: 7'h50)
//     - Synchronous edge detection for START and STOP conditions
//     - Automatic ACK generation when addressed
//     - Handles Master Write (stores byte into internal memory)
//     - Handles Master Read  (sends byte from internal memory to master)
//     - True Open-Drain physical bus modeling using inout and tri-state (1'bz)
// ============================================================================

`timescale 1ns / 1ps

module i2c_slave_model #(
    parameter [6:0] SLAVE_ADDR = 7'h50 // Default 7-bit address (e.g., 24C02 EEPROM)
)(
    // ------------------------------------------------------------------------
    // System Clock & Reset (Runs edge-detectors & internal state machine)
    // ------------------------------------------------------------------------
    input  wire       clk,        // Fast system clock (e.g., 50 MHz)
    input  wire       reset_n,    // Active-low asynchronous reset

    // ------------------------------------------------------------------------
    // I2C Physical Bidirectional Bus Lines (Shared with Master)
    // ------------------------------------------------------------------------
    inout  wire       scl,        // Serial Clock Line
    inout  wire       sda         // Serial Data Line
);

    // ========================================================================
    // 1. Synchronizers & Edge Detectors for SCL and SDA
    // ========================================================================
    // Because SCL and SDA come from external pins, we pass them through a
    // 3-stage flip-flop synchronizer to safely detect:
    //   - SCL rising edge  (time to sample data)
    //   - SCL falling edge (time to change data)
    //   - START condition  (SDA falls while SCL is HIGH)
    //   - STOP condition   (SDA rises while SCL is HIGH)
    // ========================================================================
    reg [2:0] scl_sync;
    reg [2:0] sda_sync;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            scl_sync <= 3'b111;
            sda_sync <= 3'b111;
        end else begin
            scl_sync <= {scl_sync[1:0], scl};
            sda_sync <= {sda_sync[1:0], sda};
        end
    end

    wire scl_curr = scl_sync[1];
    wire sda_curr = sda_sync[1];

    // Edge detections
    wire scl_posedge = (scl_sync[2:1] == 2'b01); // SCL went from 0 to 1
    wire scl_negedge = (scl_sync[2:1] == 2'b10); // SCL went from 1 to 0

    // START condition: SDA falls from 1 to 0 while SCL is firmly HIGH
    wire start_detected = (scl_curr == 1'b1) && (sda_sync[2:1] == 2'b10);

    // STOP condition: SDA rises from 0 to 1 while SCL is firmly HIGH
    wire stop_detected  = (scl_curr == 1'b1) && (sda_sync[2:1] == 2'b01);

    // ========================================================================
    // 2. Open-Drain Output Modeling for Slave
    // ========================================================================
    // Slave only drives SDA (or releases it).
    //   - sda_out == 0 -> Drive 1'b0 (pull to GND for ACK or data 0)
    //   - sda_out == 1 -> Release wire (1'bz), let pull-up resistor pull HIGH
    // ========================================================================
    reg sda_out;
    assign sda = (sda_out == 1'b0) ? 1'b0 : 1'bz;

    // ========================================================================
    // 3. FSM States & Registers
    // ========================================================================
    localparam [2:0]
        SLAVE_IDLE     = 3'd0, // Waiting for START condition
        SLAVE_RX_ADDR  = 3'd1, // Shifting in 7-bit Address + 1-bit R/W
        SLAVE_ACK_ADDR = 3'd2, // Drive ACK (pull SDA LOW) if address matches
        SLAVE_RX_DATA  = 3'd3, // Receive 8 bits of write data from master
        SLAVE_ACK_DATA = 3'd4, // Drive ACK for received data byte
        SLAVE_TX_DATA  = 3'd5, // Send 8 bits of read data to master
        SLAVE_WAIT_ACK = 3'd6; // Listen to Master's ACK / NACK on 9th clock

    reg [2:0] state;
    reg [7:0] rx_shift;         // Shift register for incoming Address or Write Data
    reg [7:0] tx_shift;         // Shift register for outgoing Read Data
    reg [2:0] bit_cnt;          // Counts 8 bits (7 down to 0)
    reg       rw_mode;          // Saved R/W mode: 0 = Master Write, 1 = Master Read

    // Internal memory array (256 bytes) to act like an EEPROM
    reg [7:0] memory [0:255];
    reg [7:0] mem_addr;         // Memory pointer (defaults to address 0)

    // Pre-load memory location 0 with a test pattern (0x5A) for Read tests
    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1)
            memory[i] = 8'h00;
        memory[0] = 8'h5A; // Default test byte stored in location 0
    end

    // ========================================================================
    // 4. Main Slave Sequential State Machine
    // ========================================================================
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state    <= SLAVE_IDLE;
            sda_out  <= 1'b1;  // Released
            bit_cnt  <= 3'd7;
            rx_shift <= 8'h00;
            tx_shift <= 8'h00;
            rw_mode  <= 1'b0;
            mem_addr <= 8'h00;
        end else begin

            // ----------------------------------------------------------------
            // GLOBAL PRIORITY: START and STOP conditions
            // Any time a START occurs, instantly reset to receive Address.
            // Any time a STOP occurs, instantly return to IDLE.
            // ----------------------------------------------------------------
            if (start_detected) begin
                state    <= SLAVE_RX_ADDR;
                bit_cnt  <= 3'd7;
                sda_out  <= 1'b1; // Release line
            end else if (stop_detected) begin
                state    <= SLAVE_IDLE;
                sda_out  <= 1'b1; // Release line
            end else begin

                case (state)

                    // --------------------------------------------------------
                    // STATE: SLAVE_IDLE
                    // Doing nothing. Waiting for start_detected.
                    // --------------------------------------------------------
                    SLAVE_IDLE: begin
                        sda_out <= 1'b1; // Keep SDA released
                        bit_cnt <= 3'd7;
                    end

                    // --------------------------------------------------------
                    // STATE: SLAVE_RX_ADDR
                    // Sample 7-bit Address + 1-bit R/W on each SCL rising edge.
                    // --------------------------------------------------------
                    SLAVE_RX_ADDR: begin
                        if (scl_posedge) begin
                            // Sample incoming address bit dead-center of SCL HIGH
                            rx_shift[bit_cnt] <= sda_curr;

                            if (bit_cnt == 3'd0) begin
                                // All 8 bits received! Check address on next falling edge
                                bit_cnt <= 3'd7;
                            end else begin
                                bit_cnt <= bit_cnt - 1'b1;
                            end
                        end

                        // On SCL falling edge after the 8th bit, check address
                        if (scl_negedge && bit_cnt == 3'd7) begin
                            // Compare upper 7 bits with our SLAVE_ADDR
                            if (rx_shift[7:1] == SLAVE_ADDR) begin
                                rw_mode <= rx_shift[0]; // Save R/W bit: 0=Write, 1=Read
                                sda_out <= 1'b0;        // *** PULL SDA LOW TO SEND ACK! ***
                                state   <= SLAVE_ACK_ADDR;

                                // If Master wants to Read, prepare the data byte now
                                if (rx_shift[0] == 1'b1) begin
                                    tx_shift <= memory[mem_addr];
                                end
                            end else begin
                                // Address does not match: ignore transaction, return to IDLE
                                state <= SLAVE_IDLE;
                            end
                        end
                    end

                    // --------------------------------------------------------
                    // STATE: SLAVE_ACK_ADDR
                    // The 9th clock cycle of the address byte.
                    // Slave held SDA LOW during Phase 0-2. Release it at Phase 3.
                    // --------------------------------------------------------
                    SLAVE_ACK_ADDR: begin
                        if (scl_negedge) begin
                            // 9th clock has finished (falling edge).
                            // Release SDA line!
                            sda_out <= 1'b1;
                            bit_cnt <= 3'd7;

                            if (rw_mode == 1'b0) begin
                                // Master wants to WRITE -> Prepare to receive data
                                state <= SLAVE_RX_DATA;
                            end else begin
                                // Master wants to READ -> Prepare to drive first data bit
                                sda_out <= tx_shift[7]; // Place MSB on SDA while SCL is LOW
                                state   <= SLAVE_TX_DATA;
                            end
                        end
                    end

                    // --------------------------------------------------------
                    // STATE: SLAVE_RX_DATA (Master WRITE mode)
                    // Sample incoming 8 bits of write data from Master on posedge.
                    // --------------------------------------------------------
                    SLAVE_RX_DATA: begin
                        if (scl_posedge) begin
                            rx_shift[bit_cnt] <= sda_curr;

                            if (bit_cnt == 3'd0) begin
                                bit_cnt <= 3'd7;
                            end else begin
                                bit_cnt <= bit_cnt - 1'b1;
                            end
                        end

                        // On SCL falling edge after 8th data bit:
                        if (scl_negedge && bit_cnt == 3'd7) begin
                            // Save received byte into internal memory
                            memory[mem_addr] <= rx_shift;

                            // Send ACK for the data byte:
                            sda_out <= 1'b0; // *** PULL SDA LOW FOR DATA ACK! ***
                            state   <= SLAVE_ACK_DATA;
                        end
                    end

                    // --------------------------------------------------------
                    // STATE: SLAVE_ACK_DATA
                    // 9th clock cycle of data byte. Release SDA on SCL negedge.
                    // --------------------------------------------------------
                    SLAVE_ACK_DATA: begin
                        if (scl_negedge) begin
                            sda_out <= 1'b1; // Release SDA
                            state   <= SLAVE_IDLE; // Single byte write finished, wait for STOP
                        end
                    end

                    // --------------------------------------------------------
                    // STATE: SLAVE_TX_DATA (Master READ mode)
                    // Slave drives 8 bits to SDA on each SCL falling edge.
                    // --------------------------------------------------------
                    SLAVE_TX_DATA: begin
                        if (scl_negedge) begin
                            if (bit_cnt == 3'd0) begin
                                // All 8 bits transmitted: release SDA for Master's ACK/NACK
                                sda_out <= 1'b1;
                                state   <= SLAVE_WAIT_ACK;
                            end else begin
                                bit_cnt <= bit_cnt - 1'b1;
                                sda_out <= tx_shift[bit_cnt - 1'b1]; // Output next bit
                            end
                        end
                    end

                    // --------------------------------------------------------
                    // STATE: SLAVE_WAIT_ACK
                    // 9th clock cycle of Read: Slave samples Master's ACK or NACK.
                    // --------------------------------------------------------
                    SLAVE_WAIT_ACK: begin
                        if (scl_posedge) begin
                            // Master usually sends NACK (SDA=1) to terminate read
                            // We return to IDLE to wait for Master's STOP condition
                        end

                        if (scl_negedge) begin
                            sda_out <= 1'b1; // Ensure SDA is released
                            state   <= SLAVE_IDLE;
                        end
                    end

                    default: begin
                        state <= SLAVE_IDLE;
                    end

                endcase
            end
        end
    end

endmodule
