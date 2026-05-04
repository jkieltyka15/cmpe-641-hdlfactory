module decoder3x8 (
    input  wire [2:0] in,
    input  wire       en,
    output wire [7:0] out
);

assign out = en ? (8'b00000001 << in) : 8'b00000000;

endmodule
