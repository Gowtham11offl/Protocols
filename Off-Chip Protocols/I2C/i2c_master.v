// ============================================================================
// Module: i2c_master
// File:   i2c_master.v
// Location: C:\Users\Gowtham\OneDrive\Documents\VLSI\Protocols\I2C\
// Description:
//   A complete, synthesizable I2C Master Controller written in Verilog.
//   Features:
//     - Standard 7-bit slave addressing
//     - Master Write and Master Read single-byte transactions
//     - 4-phase clock tick generation for strict setup, hold, and sample timing
//     - True Open-Drain physical bus modeling using inout and tri-state (1'bz)
//     - Automatic ACK / NACK handling and error detection
// ============================================================================

`timescale 1ns / 1ps

module i2c_master #(
    parameter CLK_FREQ = 50_000_000, // System clock frequency in Hz (50 MHz)
    parameter I2C_FREQ = 100_000     // Target I2C bus speed in Hz (100 kHz Standard Mode)
)(
    // ------------------------------------------------------------------------
    // System Clock & Reset
    // ------------------------------------------------------------------------
    input  wire        clk,        // Fast system clock
    input  wire        reset_n,    // Active-low asynchronous reset

    // ------------------------------------------------------------------------
    // Host / CPU Core Control Interface
    // ------------------------------------------------------------------------
    input  wire        start,      // 1-cycle pulse to start an I2C transaction
    input  wire [6:0]  addr,       // 7-bit target slave address
    input  wire        rw,         // Transfer direction: 0 = Write, 1 = Read
    input  wire [7:0]  write_data, // 8-bit data to write to the slave
    output reg  [7:0]  read_data,  // 8-bit data received from the slave
    output reg         busy,       // 1 = Transaction active, 0 = Bus is idle
    output reg         ack_error,  // 1 = NACK received (slave missing or refused)
    output reg         done,       // 1-cycle pulse indicating transfer finished

    // ------------------------------------------------------------------------
    // Physical I2C Bus Pins (External Bidirectional Lines)
    // ------------------------------------------------------------------------
    inout  wire        scl,        // Serial Clock Line (Open-Drain)
    inout  wire        sda         // Serial Data Line  (Open-Drain)
);

    // ========================================================================
    // 1. Parameters & Constants
    // ========================================================================
    // Calculate how many system clock cycles make up one quarter-phase of SCL
    // For 50 MHz clock & 100 kHz I2C: 50,000,000 / (100,000 * 4) = 125 clocks
    localparam QUARTER_PERIOD = CLK_FREQ / (I2C_FREQ * 4);
    localparam CNT_WIDTH      = $clog2(QUARTER_PERIOD);

    // FSM State Encodings (4 bits for 9 states)
    localparam [3:0]
        IDLE       = 4'd0,  // Bus waiting for start command
        START      = 4'd1,  // Generate START condition (SDA drops while SCL is HIGH)
        ADDR       = 4'd2,  // Transmit 7-bit Address + 1-bit R/W (8 bits total)
        ACK_ADDR   = 4'd3,  // Listen for Slave's ACK on the 9th clock
        WRITE_DATA = 4'd4,  // Transmit 8 bits of write_data to slave
        ACK_DATA   = 4'd5,  // Listen for Slave's ACK on the written data byte
        READ_DATA  = 4'd6,  // Receive 8 bits of data driven by the slave
        SEND_ACK   = 4'd7,  // Master sends NACK to slave to signal end of read
        STOP       = 4'd8;  // Generate STOP condition (SDA rises while SCL is HIGH)

    // ========================================================================
    // 2. Internal Registers & Wires Declaration
    // ========================================================================
    // Clock divider and phase counters
    reg [CNT_WIDTH-1:0] clk_cnt;  // Counts system clock cycles (0 to QUARTER_PERIOD-1)
    reg [1:0]           phase;    // Cycles through 4 phases: 00 -> 01 -> 10 -> 11
    wire                tick;     // Pulses HIGH for 1 clock cycle every quarter-period

    // Open-drain driver registers
    reg scl_out;  // Internal SCL drive: 0 = pull to 0V (GND), 1 = release wire (floating)
    reg sda_out;  // Internal SDA drive: 0 = pull to 0V (GND), 1 = release wire (floating)
    wire sda_in;  // Wire to continuously sample the real physical SDA pin

    // FSM state and operational registers
    reg [3:0] state;     // Holds the current state of the controller FSM
    reg [7:0] tx_shift;  // Shift register holding outgoing byte (shifted MSB first)
    reg [7:0] rx_shift;  // Shift register accumulating incoming bits from slave
    reg [2:0] bit_cnt;   // Counts bit index from 7 down to 0
    reg       rw_reg;    // Latched copy of the 'rw' command input

    // ========================================================================
    // 3. Open-Drain Tri-State Bus Modeling
    // ========================================================================
    // Open-Drain behavior:
    //   - Driving 0: output 1'b0 (pin connects to GND)
    //   - Driving 1: output 1'bz (pin floats, external pull-up resistor pulls to 3.3V/5V)
    assign scl    = (scl_out == 1'b0) ? 1'b0 : 1'bz;
    assign sda    = (sda_out == 1'b0) ? 1'b0 : 1'bz;
    assign sda_in = sda; // Always monitor the real voltage on SDA

    // ========================================================================
    // 4. Clock Tick & Phase Generator
    // ========================================================================
    // Ticks every QUARTER_PERIOD system clock cycles to step through 4 phases:
    //   Phase 0 (2'b00): SCL is LOW       -> Safe time to change SDA
    //   Phase 1 (2'b01): SCL goes HIGH    -> Bus settles (recovers from RC rise time)
    //   Phase 2 (2'b10): SCL is HIGH      -> Sample SDA (dead-center peak stability)
    //   Phase 3 (2'b11): SCL drops LOW    -> Hold time confirmed, prep next bit
    assign tick = (clk_cnt == QUARTER_PERIOD - 1);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            clk_cnt <= {CNT_WIDTH{1'b0}};
            phase   <= 2'b00;
        end else if (busy) begin
            if (tick) begin
                clk_cnt <= {CNT_WIDTH{1'b0}};
                phase   <= phase + 1'b1; // Advance to the next phase (00->01->10->11)
            end else begin
                clk_cnt <= clk_cnt + 1'b1;
            end
        end else begin
            clk_cnt <= {CNT_WIDTH{1'b0}};
            phase   <= 2'b00;
        end
    end

    // ========================================================================
    // 5. Main Finite State Machine (FSM)
    // ========================================================================
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            // Reset all outputs and internal registers to safe defaults
            state      <= IDLE;
            scl_out    <= 1'b1; // Release SCL (pulled HIGH)
            sda_out    <= 1'b1; // Release SDA (pulled HIGH)
            busy       <= 1'b0;
            ack_error  <= 1'b0;
            done       <= 1'b0;
            read_data  <= 8'h00;
            tx_shift   <= 8'h00;
            rx_shift   <= 8'h00;
            bit_cnt    <= 3'd0;
            rw_reg     <= 1'b0;
        end else begin
            done <= 1'b0; // Default: 'done' is a single-clock pulse

            case (state)

                // ------------------------------------------------------------
                // STATE: IDLE
                // Bus is free. Wait for the host to assert 'start'.
                // ------------------------------------------------------------
                IDLE: begin
                    scl_out   <= 1'b1; // Keep bus idle at HIGH
                    sda_out   <= 1'b1;
                    busy      <= 1'b0;
                    ack_error <= 1'b0;
                    bit_cnt   <= 3'd7;

                    if (start) begin
                        busy     <= 1'b1;
                        rw_reg   <= rw;                  // Latch direction: 0=Write, 1=Read
                        tx_shift <= {addr, rw};          // Combine 7-bit addr + 1-bit rw into byte
                        state    <= START;
                    end
                end

                // ------------------------------------------------------------
                // STATE: START
                // Generates the I2C START condition (SDA drops while SCL is HIGH).
                // ------------------------------------------------------------
                START: begin
                    if (tick) begin
                        case (phase)
                            2'b00: begin
                                scl_out <= 1'b1; // Keep SCL HIGH
                                sda_out <= 1'b1; // Keep SDA HIGH
                            end
                            2'b01: begin
                                scl_out <= 1'b1; // SCL remains HIGH
                                sda_out <= 1'b1; // SDA remains HIGH
                            end
                            2'b10: begin
                                scl_out <= 1'b1; // SCL remains HIGH
                                sda_out <= 1'b0; // Pull SDA LOW -> *** START CONDITION ***
                            end
                            2'b11: begin
                                scl_out <= 1'b0; // Pull SCL LOW to prepare for data transmission
                                bit_cnt <= 3'd7; // Start transmitting from MSB (bit 7)
                                state   <= ADDR;
                            end
                        endcase
                    end
                end

                // ------------------------------------------------------------
                // STATE: ADDR
                // Transmits 7-bit address + R/W bit (8 bits total, MSB first).
                // ------------------------------------------------------------
                ADDR: begin
                    if (tick) begin
                        case (phase)
                            2'b00: begin
                                scl_out <= 1'b0;              // SCL is LOW: safe to update SDA
                                sda_out <= tx_shift[bit_cnt]; // Place current bit on SDA
                            end
                            2'b01: begin
                                scl_out <= 1'b1;              // Release SCL to HIGH (settling)
                            end
                            2'b10: begin
                                // SCL is HIGH: data is stable, slave is sampling
                            end
                            2'b11: begin
                                scl_out <= 1'b0;              // SCL drops LOW
                                if (bit_cnt == 3'd0) begin
                                    state <= ACK_ADDR;        // All 8 bits sent, wait for ACK
                                end else begin
                                    bit_cnt <= bit_cnt - 1'b1;// Move to next bit
                                end
                            end
                        endcase
                    end
                end

                // ------------------------------------------------------------
                // STATE: ACK_ADDR
                // 9th clock cycle: Master releases SDA and listens for Slave ACK.
                // ------------------------------------------------------------
                ACK_ADDR: begin
                    if (tick) begin
                        case (phase)
                            2'b00: begin
                                scl_out <= 1'b0;
                                sda_out <= 1'b1; // Release SDA so slave can pull it LOW (ACK)
                            end
                            2'b01: begin
                                scl_out <= 1'b1; // SCL rises
                            end
                            2'b10: begin
                                // Sample ACK dead-center of SCL HIGH
                                if (sda_in == 1'b1)
                                    ack_error <= 1'b1; // Slave did not pull LOW (NACK error)
                                else
                                    ack_error <= 1'b0; // Slave pulled LOW (ACK success)
                            end
                            2'b11: begin
                                scl_out <= 1'b0; // SCL drops LOW
                                bit_cnt <= 3'd7; // Reset bit counter for upcoming data byte

                                if (ack_error || sda_in == 1'b1) begin
                                    // Slave missing or refused address: abort to STOP
                                    state <= STOP;
                                end else if (rw_reg == 1'b0) begin
                                    // Master Write: load data and proceed to write
                                    tx_shift <= write_data;
                                    state    <= WRITE_DATA;
                                end else begin
                                    // Master Read: proceed to receive data from slave
                                    state    <= READ_DATA;
                                end
                            end
                        endcase
                    end
                end

                // ------------------------------------------------------------
                // STATE: WRITE_DATA
                // Transmits 8 bits of write_data to the slave (MSB first).
                // ------------------------------------------------------------
                WRITE_DATA: begin
                    if (tick) begin
                        case (phase)
                            2'b00: begin
                                scl_out <= 1'b0;              // SCL LOW: safe to update SDA
                                sda_out <= tx_shift[bit_cnt]; // Place current data bit on SDA
                            end
                            2'b01: begin
                                scl_out <= 1'b1;              // SCL rises HIGH (settling)
                            end
                            2'b10: begin
                                // SCL is HIGH: data held stable for slave to sample
                            end
                            2'b11: begin
                                scl_out <= 1'b0;              // SCL drops LOW
                                if (bit_cnt == 3'd0) begin
                                    state <= ACK_DATA;        // All 8 data bits sent
                                end else begin
                                    bit_cnt <= bit_cnt - 1'b1;// Move to next data bit
                                end
                            end
                        endcase
                    end
                end

                // ------------------------------------------------------------
                // STATE: ACK_DATA
                // 9th clock cycle: Master listens for Slave ACK of the data byte.
                // ------------------------------------------------------------
                ACK_DATA: begin
                    if (tick) begin
                        case (phase)
                            2'b00: begin
                                scl_out <= 1'b0;
                                sda_out <= 1'b1; // Release SDA so slave can pull LOW (ACK)
                            end
                            2'b01: begin
                                scl_out <= 1'b1; // SCL rises HIGH
                            end
                            2'b10: begin
                                // Sample slave ACK dead-center of SCL HIGH
                                if (sda_in == 1'b1)
                                    ack_error <= 1'b1; // Slave did not ACK data byte
                                else
                                    ack_error <= 1'b0; // Slave successfully ACKed data byte
                            end
                            2'b11: begin
                                scl_out <= 1'b0; // SCL drops LOW
                                state   <= STOP; // Write complete, proceed to STOP
                            end
                        endcase
                    end
                end

                // ------------------------------------------------------------
                // STATE: READ_DATA
                // Receives 8 bits from the slave (Slave drives SDA, Master drives SCL).
                // ------------------------------------------------------------
                READ_DATA: begin
                    if (tick) begin
                        case (phase)
                            2'b00: begin
                                scl_out <= 1'b0;
                                sda_out <= 1'b1; // Keep SDA released so slave can drive it
                            end
                            2'b01: begin
                                scl_out <= 1'b1; // SCL rises HIGH, let slave bit settle
                            end
                            2'b10: begin
                                // Sample incoming bit dead-center of SCL HIGH
                                rx_shift[bit_cnt] <= sda_in;
                            end
                            2'b11: begin
                                scl_out <= 1'b0; // SCL drops LOW
                                if (bit_cnt == 3'd0) begin
                                    // Capture final byte including the last sampled bit
                                    read_data <= {rx_shift[7:1], sda_in};
                                    state     <= SEND_ACK;
                                end else begin
                                    bit_cnt <= bit_cnt - 1'b1; // Move to next bit
                                end
                            end
                        endcase
                    end
                end

                // ------------------------------------------------------------
                // STATE: SEND_ACK
                // Master sends NACK (1'b1) to tell the slave to stop sending data.
                // ------------------------------------------------------------
                SEND_ACK: begin
                    if (tick) begin
                        case (phase)
                            2'b00: begin
                                scl_out <= 1'b0;
                                sda_out <= 1'b1; // Send NACK (release SDA) to signal end of read
                            end
                            2'b01: begin
                                scl_out <= 1'b1; // SCL rises HIGH
                            end
                            2'b10: begin
                                // Hold NACK stable on the wire
                            end
                            2'b11: begin
                                scl_out <= 1'b0; // SCL drops LOW
                                state   <= STOP; // Read complete, proceed to STOP
                            end
                        endcase
                    end
                end

                // ------------------------------------------------------------
                // STATE: STOP
                // Generates the I2C STOP condition (SDA rises while SCL is HIGH).
                // ------------------------------------------------------------
                STOP: begin
                    if (tick) begin
                        case (phase)
                            2'b00: begin
                                scl_out <= 1'b0;
                                sda_out <= 1'b0; // Pull SDA LOW while SCL is still LOW
                            end
                            2'b01: begin
                                scl_out <= 1'b1; // SCL rises HIGH first
                                sda_out <= 1'b0; // SDA held LOW
                            end
                            2'b10: begin
                                scl_out <= 1'b1; // SCL remains HIGH
                                sda_out <= 1'b1; // Release SDA to HIGH -> *** STOP CONDITION ***
                            end
                            2'b11: begin
                                scl_out <= 1'b1; // Bus returns to idle HIGH
                                sda_out <= 1'b1;
                                busy    <= 1'b0; // Master is no longer busy
                                done    <= 1'b1; // 1-cycle completion pulse to host
                                state   <= IDLE; // Return to IDLE
                            end
                        endcase
                    end
                end

                // ------------------------------------------------------------
                // Default fallback
                // ------------------------------------------------------------
                default: begin
                    state <= IDLE;
                end

            endcase
        end
    end

endmodule
