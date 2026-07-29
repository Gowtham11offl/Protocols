`timescale 1ns/1ps

module apb (
    input             Pclk,
    input             Prst,
    input             Pselx,
    input             Penable,
    input             Pwrite,
    input      [31:0] Paddr,
    input      [31:0] Pwdata,
    output reg        Pready,
    output              Pslverr,
    output reg [31:0] Prdata
);

  parameter [1:0] idle   = 2'b00;
  parameter [1:0] setup  = 2'b01;
  parameter [1:0] access = 2'b10;

  reg [31:0] mem [31:0];
  reg [1:0]  present_state, next_state;

  
  always @(posedge Pclk) begin
    if (Prst)
      present_state <= idle;
    else
      present_state <= next_state;
  end

  
  always @(*) begin
    // Safe defaults so nothing ever infers a latch
    next_state = present_state;
    Pready     = 1'b0;
    Prdata     = 32'b0;

    case (present_state)

      idle: begin
        Pready = 1'b0;
        if (Pselx && !Penable)
          next_state = setup;
      end

      setup: begin
        Pready = 1'b0;
        
        if (Pselx)
          next_state = access;
        else
          next_state = idle;
      end

      access: begin
        Pready = 1'b1;                 
        if (!Pwrite)
          Prdata = mem[Paddr[4:0]];   

        if (!Pselx || !Penable)
          next_state = idle;
        else
          next_state = access;
      end

      default: next_state = idle;
    endcase
  end

 
  always @(posedge Pclk) begin
    if (present_state == setup && Pselx && Pwrite)
      mem[Paddr[4:0]] <= Pwdata;
  end

 
  assign Pslverr = 1'b0;

endmodule
