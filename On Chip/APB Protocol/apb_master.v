`timescale 1ns/1ps

module apb_master (
    input             Pclk,
    input             Prst,

    
    input             start,       
    input             write,       
    input      [31:0] addr,
    input      [31:0] wdata,
    output reg        done,        
    output reg [31:0] rdata,       

    
    output reg        Pselx,
    output reg        Penable,
    output reg        Pwrite,
    output reg [31:0] Paddr,
    output reg [31:0] Pwdata,

    
    input             Pready,
    input             Pslverr,
    input      [31:0] Prdata
);

  parameter [1:0] idle   = 2'b00;
  parameter [1:0] setup  = 2'b01;
  parameter [1:0] access = 2'b10;

  reg [1:0] present_state;

  always @(posedge Pclk) begin
    if (Prst) begin
      present_state <= idle;
      Pselx   <= 1'b0;
      Penable <= 1'b0;
      Pwrite  <= 1'b0;
      Paddr   <= 32'b0;
      Pwdata  <= 32'b0;
      done    <= 1'b0;
      rdata   <= 32'b0;
    end
    else begin
      
      done <= 1'b0;

      case (present_state)

        
        idle: begin
          if (start) begin
            Pselx   <= 1'b1;
            Penable <= 1'b0;
            Pwrite  <= write;
            Paddr   <= addr;
            Pwdata  <= wdata;
            present_state <= setup;
          end
        end

        
        setup: begin
          Penable <= 1'b1;
          present_state <= access;
        end

        
        access: begin
          if (Pready) begin
            if (!Pwrite)
              rdata <= Prdata;
            done    <= 1'b1;
            Pselx   <= 1'b0;
            Penable <= 1'b0;
            present_state <= idle;
          end
          
        end

        default: present_state <= idle;
      endcase
    end
  end

endmodule
