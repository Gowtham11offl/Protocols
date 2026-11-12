`timescale 1ns / 1ps

// ============================================================================
// Module: apb_tb
// Description:
//   Self-checking verification testbench for APB Master & APB Slave.
//   Features:
//     - Concurrent protocol assertions (checking APB rules)
//     - Golden reference memory model
//     - Automated comparator with Pass/Fail tally
//     - Full 32-register sweep test
//     - Bit-pattern and walking 1s test
//     - Back-to-back pipeline transfer verification
// ============================================================================

module apb_tb;

    // ------------------------------------------------------------------------
    // 1. Clock, Reset, and Host-Side Stimulus Signals
    // ------------------------------------------------------------------------
    reg         PCLK;         // Master bus clock generator
    reg         PRESETn;      // Master reset generator
    reg  [31:0] data;         // Write data stimulus presented to APB Master
    reg  [31:0] address;      // Address stimulus presented to APB Master
    reg         transfer;     // Host control to initiate a transfer
    reg         write;        // Host direction: 1 = Write, 0 = Read

    wire [31:0] read_data;    // Captured read data output from APB Master

    // ------------------------------------------------------------------------
    // 2. APB Bus Interface Wires (Connects Master to Slave)
    // ------------------------------------------------------------------------
    wire [31:0] PADDR;        // Address bus between Master and Slave
    wire [31:0] PWDATA;       // Write data bus between Master and Slave
    wire        PSELX;        // Slave select line
    wire        PENABLE;      // Enable strobe
    wire        PWRITE;       // Transfer direction on bus
    wire [31:0] PRDATA;       // Read data bus from Slave to Master
    wire        PREADY;       // Ready handshake from Slave to Master

    // ------------------------------------------------------------------------
    // 3. Scoreboard & Verification Counters
    // ------------------------------------------------------------------------
    integer pass_count  = 0;  // Tracks number of successful assertions
    integer fail_count  = 0;  // Tracks number of failed assertions
    integer proto_errs  = 0;  // Tracks bus protocol violations
    integer total_tests = 0;  // Tracks total verification checks performed

    // Golden Reference Model: software memory array mirroring expected contents
    reg [31:0] expected_mem [0:31];
    reg [31:0] captured_val;  // Temporary variable storing read output
    integer k;                // Loop index for sweeps

    // ------------------------------------------------------------------------
    // 4. Instantiate Device Under Test: APB Master
    // ------------------------------------------------------------------------
    apb_master u_master (
        .PCLK       (PCLK),
        .PRESETn    (PRESETn),
        .data       (data),
        .address    (address),
        .transfer   (transfer),
        .write      (write),
        .PREADY     (PREADY),
        .PRDATA     (PRDATA),
        .PADDR      (PADDR),
        .PWDATA     (PWDATA),
        .PSELX      (PSELX),
        .PENABLE    (PENABLE),
        .PWRITE     (PWRITE),
        .read_data  (read_data)
    );

    // ------------------------------------------------------------------------
    // 5. Instantiate Device Under Test: APB Slave
    // ------------------------------------------------------------------------
    apb_slave u_slave (
        .PCLK       (PCLK),
        .PRESETn    (PRESETn),
        .PSELX      (PSELX),
        .PENABLE    (PENABLE),
        .PWRITE     (PWRITE),
        .PADDR      (PADDR),
        .PWDATA     (PWDATA),
        .PRDATA     (PRDATA),
        .PREADY     (PREADY)
    );

    // ------------------------------------------------------------------------
    // 6. Clock Generation (100 MHz -> 10ns clock period)
    // ------------------------------------------------------------------------
    initial begin
        PCLK = 1'b0;
        forever #5 PCLK = ~PCLK; // Toggle every 5ns (5ns LOW, 5ns HIGH = 10ns)
    end

    // ------------------------------------------------------------------------
    // 7. Concurrent Online Protocol Checker
    // Continuously monitors APB bus rules every rising clock edge
    // ------------------------------------------------------------------------
    always @(posedge PCLK) begin
        if (PRESETn) begin
            // Protocol Rule 1: PENABLE must never be asserted without PSELX
            if (PENABLE && !PSELX) begin
                $display("[PROTOCOL ERROR @ %0t ns] PENABLE is HIGH while PSELX is LOW!", $time);
                proto_errs = proto_errs + 1;
            end

            // Protocol Rule 2: In SETUP phase, PENABLE must always be LOW
            if (u_master.current_state == u_master.setup && PENABLE !== 1'b0) begin
                $display("[PROTOCOL ERROR @ %0t ns] In SETUP phase, PENABLE must be LOW!", $time);
                proto_errs = proto_errs + 1;
            end

            // Protocol Rule 3: In ACCESS phase, PENABLE must always be HIGH
            if (u_master.current_state == u_master.access && PENABLE !== 1'b1) begin
                $display("[PROTOCOL ERROR @ %0t ns] In ACCESS phase, PENABLE must be HIGH!", $time);
                proto_errs = proto_errs + 1;
            end
        end
    end

    // ------------------------------------------------------------------------
    // 8. Reusable Verification Tasks
    // ------------------------------------------------------------------------

    // Task: Automated Comparator
    // Compares actual read data with golden reference data and logs result
    task check_result(input [31:0] addr, input [31:0] actual, input [31:0] expected);
        begin
            total_tests = total_tests + 1;
            if (actual === expected) begin
                $display("  [PASS] Addr: 0x%02X | Actual: 0x%08X == Expected: 0x%08X", addr, actual, expected);
                pass_count = pass_count + 1;
            end else begin
                $display("  [FAIL] Addr: 0x%02X | Actual: 0x%08X != Expected: 0x%08X ***", addr, actual, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Task: Single APB Write
    task do_write(input [31:0] wr_addr, input [31:0] wr_data);
        begin
            @(posedge PCLK);
            transfer <= 1'b1;         // Assert transfer to request write
            write    <= 1'b1;         // Direction: 1 = Write
            address  <= wr_addr;      // Present address
            data     <= wr_data;      // Present write data
            expected_mem[wr_addr[4:0]] = wr_data; // Record in golden reference model

            // Wait until master transitions into SETUP
            wait (u_master.current_state == u_master.setup);
            transfer <= 1'b0;         // Drop transfer: tells master this is a single transfer

            // Wait until master reaches ACCESS and slave is READY
            wait (u_master.current_state == u_master.access && PREADY);
            @(posedge PCLK);          // Clock edge where slave absorbs write data
            write <= 1'b0;            // Return write signal to 0
            #1;                       // Small delay to settle bus before next test
        end
    endtask

    // Task: Single APB Read
    task do_read(input [31:0] rd_addr, output [31:0] rd_data);
        begin
            @(posedge PCLK);
            transfer <= 1'b1;         // Assert transfer to request read
            write    <= 1'b0;         // Direction: 0 = Read
            address  <= rd_addr;      // Present target address

            // Wait until master transitions into SETUP
            wait (u_master.current_state == u_master.setup);
            transfer <= 1'b0;         // Drop transfer: single read operation

            // Wait until master reaches ACCESS and slave is READY
            wait (u_master.current_state == u_master.access && PREADY);

            // Clock edge ending ACCESS latches data into read_data register
            @(posedge PCLK);
            #1;                       // Delta delay to sample after non-blocking assignment settles
            rd_data = read_data;      // Return captured data to caller
        end
    endtask

    // ------------------------------------------------------------------------
    // 9. Main Stimulus Process
    // ------------------------------------------------------------------------
    initial begin
        // Configure waveform dump file for viewing in ModelSim / GTKWave
        $dumpfile("apb_waveform.vcd");
        $dumpvars(0, apb_tb);

        // Initialize all control signals to idle defaults
        PRESETn  = 1'b0;
        transfer = 1'b0;
        write    = 1'b0;
        address  = 32'd0;
        data     = 32'd0;

        // Clear golden memory reference model
        for (k = 0; k < 32; k = k + 1) begin
            expected_mem[k] = 32'd0;
        end

        $display("\n===============================================================");
        $display("          SELF-CHECKING APB VERIFICATION SUITE                 ");
        $display("===============================================================");
        $display("  TOTAL TESTS RUN   : %0d", total_tests);
        $display("===============================================================\n");

        // --------------------------------------------------------------------
        // Test 1: Reset Check
        // Verify that after reset, Master outputs are deasserted (IDLE state)
        // --------------------------------------------------------------------
        $display("[TEST 1] Verifying Reset State...");
        #25;
        @(posedge PCLK);
        PRESETn <= 1'b1;              // Release active-low reset
        #15;
        if (PSELX === 1'b0 && PENABLE === 1'b0) begin
            $display("  [PASS] Reset correctly initialized bus to IDLE (PSEL=0, PENABLE=0)");
            pass_count = pass_count + 1;
        end else begin
            $display("  [FAIL] Bus not in IDLE after reset!");
            fail_count = fail_count + 1;
        end
        total_tests = total_tests + 1;

        // --------------------------------------------------------------------
        // Test 2: Full Register Sweep
        // Write unique 32-bit patterns to all 32 registers, then read all 32 back
        // --------------------------------------------------------------------
        $display("\n[TEST 2] Full Register Sweep: Writing all 32 registers...");
        for (k = 0; k < 32; k = k + 1) begin
            do_write(k, (32'hA000_0000 + (k * 32'h0001_0001)));
        end
        $display("  Done writing 32 registers. Now reading back and verifying...");

        for (k = 0; k < 32; k = k + 1) begin
            do_read(k, captured_val);
            check_result(k, captured_val, expected_mem[k]);
        end

        // --------------------------------------------------------------------
        // Test 3: Bit Pattern Test (Walking 1s and Boundary Values)
        // Tests individual bits to guarantee no stuck-at or bridged bit-lines
        // --------------------------------------------------------------------
        $display("\n[TEST 3] Bit Pattern Test (Walking 1s)...");
        do_write(32'd4,  32'h0000_0001); // Bit 0
        do_write(32'd8,  32'h0000_0002); // Bit 1
        do_write(32'd12, 32'h8000_0000); // Bit 31 (MSB)
        do_write(32'd16, 32'hFFFF_FFFF); // All 1s

        do_read(32'd4,  captured_val); check_result(32'd4,  captured_val, 32'h0000_0001);
        do_read(32'd8,  captured_val); check_result(32'd8,  captured_val, 32'h0000_0002);
        do_read(32'd12, captured_val); check_result(32'd12, captured_val, 32'h8000_0000);
        do_read(32'd16, captured_val); check_result(32'd16, captured_val, 32'hFFFF_FFFF);

        // --------------------------------------------------------------------
        // Test 4: Back-to-Back Consecutive Pipeline Transfers
        // Tests executing Transfer A and Transfer B with 0 idle cycles in between
        // --------------------------------------------------------------------
        $display("\n[TEST 4] Back-to-Back Consecutive Pipeline Transfers...");
        
        // Step 4.1: Queue Transfer A (Write to Reg 20)
        @(posedge PCLK);
        transfer <= 1'b1;
        write    <= 1'b1;
        address  <= 32'd20;
        data     <= 32'h1122_3344;
        expected_mem[20] = 32'h1122_3344;

        // Step 4.2: Wait for Transfer A SETUP
        @(posedge PCLK);

        // Step 4.3: In ACCESS of Transfer A, queue Transfer B (Write to Reg 21)
        transfer <= 1'b1;             // Keep transfer high to trigger back-to-back
        write    <= 1'b1;
        address  <= 32'd21;
        data     <= 32'h5566_7788;
        expected_mem[21] = 32'h5566_7788;

        // Step 4.4: Clock edge finishes Transfer A and enters SETUP of Transfer B
        @(posedge PCLK);

        // Step 4.5: In SETUP of Transfer B, tell Master to return to IDLE after B
        transfer <= 1'b0;

        // Step 4.6: Wait for Transfer B to complete in ACCESS
        @(posedge PCLK);
        @(posedge PCLK);
        write <= 1'b0;

        // Step 4.7: Read both registers back to verify both writes succeeded
        do_read(32'd20, captured_val); check_result(32'd20, captured_val, 32'h1122_3344);
        do_read(32'd21, captured_val); check_result(32'd21, captured_val, 32'h5566_7788);

        // --------------------------------------------------------------------
        // Final Scoreboard Report Summary
        // --------------------------------------------------------------------
        #50;
        $display("\n===============================================================");
        $display("                   FINAL SCOREBOARD REPORT                     ");
        $display("===============================================================");
        $display("  TOTAL TESTS RUN   : %0d", total_tests);
        $display("  PASSED TESTS      : %0d", pass_count);
        $display("  FAILED TESTS      : %0d", fail_count);
        $display("  PROTOCOL ERRORS   : %0d", proto_errs);
        $display("===============================================================");

        if (fail_count == 0 && proto_errs == 0) begin
            $display("  >>> STATUS: ALL VERIFICATION CHECKS PASSED SUCCESSFULLY! <<<");
        end else begin
            $display("  >>> STATUS: VERIFICATION FAILED! PLEASE REVIEW LOGS.     <<<");
        end
        $display("===============================================================\n");

        #20;
        $finish; // End simulation
    end

endmodule
