module mux4x16 (
    input  wire [15:0] in0,
    input  wire [15:0] in1,
    input  wire [15:0] in2,
    input  wire [15:0] in3,
    input  wire [1:0]  sel,
    output wire [15:0] out
);
    assign out = (sel == 2'b00) ? in0 : (sel == 2'b01) ? in1 : (sel == 2'b10) ? in2 : in3;
endmodule
