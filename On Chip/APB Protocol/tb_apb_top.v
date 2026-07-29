`timescale 1ns/1ps

module apb_top_tb;

  reg         Pclk;
  reg         Prst;
  reg         start;
  reg         write;
  reg  [31:0] addr;
  reg  [31:0] wdata;
  wire        done;
  wire [31:0] rdata;

  // bus signals (just for waveform visibility)
  wire        Pselx, Penable, Pwrite, Pready, Pslverr;
  wire [31:0] Paddr, Pwdata, Prdata;

  integer     errors = 0;

  apb_top dut (
      .Pclk(Pclk), .Prst(Prst),
      .start(start), .write(write), .addr(addr), .wdata(wdata),
      .done(done), .rdata(rdata),
      .Pselx(Pselx), .Penable(Penable), .Pwrite(Pwrite),
      .Paddr(Paddr), .Pwdata(Pwdata),
      .Pready(Pready), .Pslverr(Pslverr), .Prdata(Prdata)
  );

  // ---- clock ----
  initial Pclk = 0;
  always #5 Pclk = ~Pclk;

  // ---- reset ----
  initial begin
    Prst  = 1;
    start = 0; write = 0; addr = 0; wdata = 0;
    repeat (3) @(posedge Pclk);
    Prst = 0;
    @(posedge Pclk);
  end

  // ---- simple task: kick off a transfer via the front-end interface ----
  task do_write(input [31:0] a, input [31:0] d);
    begin
      @(posedge Pclk);
      start = 1; write = 1; addr = a; wdata = d;
      @(posedge Pclk);
      start = 0;
      wait (done == 1);
      @(posedge Pclk);
    end
  endtask

  task do_read(input [31:0] a, output [31:0] d);
    begin
      @(posedge Pclk);
      start = 1; write = 0; addr = a;
      @(posedge Pclk);
      start = 0;
      wait (done == 1);
      d = rdata;
      @(posedge Pclk);
    end
  endtask

  task check(input [31:0] expected, input [31:0] actual, input [255:0] name);
    begin
      if (expected !== actual) begin
        $display("FAIL: %0s  expected=%0h actual=%0h @ time=%0t", name, expected, actual, $time);
        errors = errors + 1;
      end else
        $display("PASS: %0s  data=%0h @ time=%0t", name, actual, $time);
    end
  endtask

  reg [31:0] rd;

  initial begin
    @(negedge Prst);
    @(posedge Pclk);

    do_write(32'h0, 32'hDEAD_BEEF);
    do_read (32'h0, rd);
    check(32'hDEAD_BEEF, rd, "Master->Slave Write/Read addr0");

    do_write(32'h5, 32'h1234_5678);
    do_read (32'h5, rd);
    check(32'h1234_5678, rd, "Master->Slave Write/Read addr5");

    do_write(32'h1, 32'hAAAA_AAAA);
    do_write(32'h2, 32'h5555_5555);
    do_read (32'h1, rd);
    check(32'hAAAA_AAAA, rd, "Back-to-back addr1");
    do_read (32'h2, rd);
    check(32'h5555_5555, rd, "Back-to-back addr2");

    #20;
    if (errors == 0)
      $display("\n*** ALL TESTS PASSED ***\n");
    else
      $display("\n*** %0d TEST(S) FAILED ***\n", errors);

    $finish;
  end

  initial begin
    $dumpfile("apb_top_tb.vcd");
    $dumpvars(0, apb_top_tb);
  end

endmodule
