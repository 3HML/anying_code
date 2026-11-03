module seg_scan(
    input clk,
    input rst_n,
    input sleep,
    output reg [7:0] seg_sel,
    output reg [7:0] seg_data,
    input [7:0] seg_data_0,seg_data_1,seg_data_2,seg_data_3,
    input [7:0] seg_data_4,seg_data_5,seg_data_6,seg_data_7
);
// Default legacy inputs are already decoded segments. Encoded mode uses
// {DP_off,blank,dash,reserved,hex[3:0]} and shares one decoder after digit select.
parameter SCAN_FREQ = 200;
parameter CLK_FREQ = 50000000;
parameter SCAN_COUNT = CLK_FREQ/(SCAN_FREQ*8)-1;
parameter ENCODED_MODE = 0;
parameter SLEEP_ENABLE = 0;
// Negative or very large parameter overrides use a 32-bit counter.
// SCAN_COUNT0/1 use one bit and use the blank/latch sequence.
localparam integer TIMER_W=(SCAN_COUNT>=0 && SCAN_COUNT<32'h7fffffff)?
                          ((SCAN_COUNT<2)?1:$clog2(SCAN_COUNT+1)):32;
reg [TIMER_W-1:0] scan_timer;
reg [2:0] scan_sel;
reg [7:0] selected_data;
reg [6:0] decoded_hex;
always @* begin
    selected_data=8'hff;
    case(scan_sel)
        0:selected_data=seg_data_0;1:selected_data=seg_data_1;
        2:selected_data=seg_data_2;3:selected_data=seg_data_3;
        4:selected_data=seg_data_4;5:selected_data=seg_data_5;
        6:selected_data=seg_data_6;7:selected_data=seg_data_7;
    endcase
    case(selected_data[3:0])
        0:decoded_hex=7'h40;1:decoded_hex=7'h79;
        2:decoded_hex=7'h24;3:decoded_hex=7'h30;
        4:decoded_hex=7'h19;5:decoded_hex=7'h12;
        6:decoded_hex=7'h02;7:decoded_hex=7'h78;
        8:decoded_hex=7'h00;9:decoded_hex=7'h10;
        10:decoded_hex=7'h08;11:decoded_hex=7'h03;
        12:decoded_hex=7'h46;13:decoded_hex=7'h21;
        14:decoded_hex=7'h06;15:decoded_hex=7'h0e;
        default:decoded_hex=7'h7f;
    endcase
end
wire [7:0] selected_segments=ENCODED_MODE ?
    (selected_data[6]?8'hff:selected_data[5]?{selected_data[7],7'h3f}:
     {selected_data[7],decoded_hex}):selected_data;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin scan_timer<=0;scan_sel<=0;end
    // Sleep is already synchronized to clk by the caller. Restart at the
    // blank phase on wake; keep the active scan duty cycle unchanged.
    else if (SLEEP_ENABLE && sleep) begin scan_timer<=0;scan_sel<=0;end
    else if (scan_timer>=SCAN_COUNT) begin scan_timer<=0;scan_sel<=scan_sel+3'd1;end
    else scan_timer<=scan_timer+1'b1;
end
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin seg_sel<=8'hff;seg_data<=8'hff;end
    else if (SLEEP_ENABLE && sleep) begin seg_sel<=8'hff;seg_data<=8'hff;end
    else if (scan_timer==0) begin
        // One blank clock before making the next digit active prevents ghosts.
        seg_sel<=8'hff;seg_data<=8'hff;
    end else if (scan_timer==1) begin
        case(scan_sel)
            3'd0:begin seg_sel<=8'b11111110;seg_data<=selected_segments;end
            3'd1:begin seg_sel<=8'b11111101;seg_data<=selected_segments;end
            3'd2:begin seg_sel<=8'b11111011;seg_data<=selected_segments;end
            3'd3:begin seg_sel<=8'b11110111;seg_data<=selected_segments;end
            3'd4:begin seg_sel<=8'b11101111;seg_data<=selected_segments;end
            3'd5:begin seg_sel<=8'b11011111;seg_data<=selected_segments;end
            3'd6:begin seg_sel<=8'b10111111;seg_data<=selected_segments;end
            3'd7:begin seg_sel<=8'b01111111;seg_data<=selected_segments;end
        endcase
    end
end
endmodule
