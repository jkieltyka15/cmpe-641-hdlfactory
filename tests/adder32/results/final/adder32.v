module adder32 (
       input  wire [31:0] a,
       input  wire [31:0] b,
       input  wire        cin,
       output reg [31:0] sum, // using register instead of wire for less power consumption
       output reg         cout
   );
       always @* begin
           {cout, sum} = a + b + {cin}; // eliminating intermediate wire result to minimize physical size and power
       end
   endmodule
