module mux4x16 (
       input  wire [15:0] in0,
       input  wire [15:0] in1,
       input  wire [15:0] in2,
       input  wire [15:0] in3,
       input  wire [1:0]  sel,
       output reg [15:0] out
   );
      always @(*) begin
         case (sel)
            2'b00: out = in0;
            2'b01: out = in1;
            2'b10: out = in2;
            default: out = in3;
         endcase
      end
   endmodule
