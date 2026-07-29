`timescale 1ns/1ps

module apb_top (
    input             Pclk,
    input             Prst,

   
    input             start,
    input             write,
    input      [31:0] addr,
    input      [31:0] wdata,
    output            done,
    output     [31:0] rdata,

    
    output            Pselx,
    output            Penable,
    output            Pwrite,
    output     [31:0] Paddr,
    output     [31:0] Pwdata,
    output            Pready,
    output            Pslverr,
    output     [31:0] Prdata
);

  apb_master u_master (
      .Pclk    (Pclk),
      .Prst    (Prst),
      .start   (start),
      .write   (write),
      .addr    (addr),
      .wdata   (wdata),
      .done    (done),
      .rdata   (rdata),
      .Pselx   (Pselx),
      .Penable (Penable),
      .Pwrite  (Pwrite),
      .Paddr   (Paddr),
      .Pwdata  (Pwdata),
      .Pready  (Pready),
      .Pslverr (Pslverr),
      .Prdata  (Prdata)
  );

  apb u_slave (
      .Pclk    (Pclk),
      .Prst    (Prst),
      .Pselx   (Pselx),
      .Penable (Penable),
      .Pwrite  (Pwrite),
      .Paddr   (Paddr),
      .Pwdata  (Pwdata),
      .Pready  (Pready),
      .Pslverr (Pslverr),
      .Prdata  (Prdata)
  );

endmodule
