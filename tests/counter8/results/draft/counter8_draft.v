module counter8 (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       en,
    input  wire       load,
    input  wire [7:0] load_value,
    output reg  [7:0] count
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        count <= 8'h00;
    end else if (load) begin
        count <= load_value;
    end else if (en) begin
        count <= count + 1;
    end
end

endmodule
