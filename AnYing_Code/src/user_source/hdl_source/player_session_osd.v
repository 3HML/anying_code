// synchronous ASCII rows. Slots32..38: K x . - + S W.
// The direct six-input row table avoids a 35-bit bitmap followed by a row mux.
// Rows are centered and doubled vertically; all other glyph/row codes are blank.
// One-clock output latency with five registered payload bits.
module player_session_osd(
    input wire clk,
    input wire [5:0] glyph,
    input wire [3:0] row,
    output reg [15:0] pixels
);
    reg [4:0] line;
    always @* begin
        line=5'd0;
        if(glyph[5:3]==3'd4)begin
            case({glyph[2:0],row[3:1]})
                6'd0:line=5'b10001;
                6'd1:line=5'b10010;
                6'd2:line=5'b10100;
                6'd3:line=5'b11000;
                6'd4:line=5'b10100;
                6'd5:line=5'b10010;
                6'd6:line=5'b10001;
                6'd10:line=5'b10001;
                6'd11:line=5'b01010;
                6'd12:line=5'b00100;
                6'd13:line=5'b01010;
                6'd14:line=5'b10001;
                6'd21:line=5'b00100;
                6'd22:line=5'b00100;
                6'd27:line=5'b11111;
                6'd33:line=5'b00100;
                6'd34:line=5'b00100;
                6'd35:line=5'b11111;
                6'd36:line=5'b00100;
                6'd37:line=5'b00100;
                6'd40:line=5'b01111;
                6'd41:line=5'b10000;
                6'd42:line=5'b10000;
                6'd43:line=5'b01110;
                6'd44:line=5'b00001;
                6'd45:line=5'b00001;
                6'd46:line=5'b11110;
                6'd48:line=5'b10001;
                6'd49:line=5'b10001;
                6'd50:line=5'b10001;
                6'd51:line=5'b10101;
                6'd52:line=5'b10101;
                6'd53:line=5'b10101;
                6'd54:line=5'b01010;
                default:line=5'd0;
            endcase
        end
    end
    always @(posedge clk) pixels<={5'b0,line,6'b0};
endmodule
