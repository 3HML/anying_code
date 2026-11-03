// Five contrast steps around RGB midpoint 128, followed by existing fade/brightness.
// Signed shift/add arithmetic; no new multiplier, RAM or pixel clock.
module player_contrast_pixels_113 (
    input wire I_clk,I_rst,
    input wire [2:0] I_level,
    input wire I_hs,I_vs,I_de,I_picture,
    input wire [23:0] I_rgb,
    output reg O_hs,O_vs,O_de,
    output reg [23:0] O_rgb
);
reg vs_d;
reg [2:0] level;
reg signed [8:0] r_center,g_center,b_center;
reg signed [12:0] r_num,g_num,b_num;
reg [2:0] sync1,sync2;
reg valid1,valid2;

function signed [12:0] scale_center;
    input signed [8:0] c;
    input [2:0] gain;
    reg signed [12:0] d;
    begin
        d={{4{c[8]}},c};
        case(gain)
          0:scale_center=13'sd1024+(d<<<3)-(d<<<1);
          1:scale_center=13'sd1024+(d<<<3)-d;
          3:scale_center=13'sd1024+(d<<<3)+d;
          4:scale_center=13'sd1024+(d<<<3)+(d<<<1);
          default:scale_center=13'sd1024+(d<<<3);
        endcase
    end
endfunction
function [7:0] clip_round;
    input signed [12:0] n;
    reg signed [12:0] rounded;
    begin
        rounded=n+13'sd4;
        if(rounded<0)clip_round=0;
        else if(rounded>=13'sd2040)clip_round=255;
        else clip_round=rounded[10:3];
    end
endfunction

always @(posedge I_clk or posedge I_rst) begin
    if(I_rst)begin
        vs_d<=0;level<=3'd2;
        r_center<=0;g_center<=0;b_center<=0;
        r_num<=0;g_num<=0;b_num<=0;
        sync1<=0;sync2<=0;valid1<=0;valid2<=0;
        O_hs<=0;O_vs<=0;O_de<=0;O_rgb<=0;
    end else begin
        vs_d<=I_vs;
        if(I_vs&&!vs_d)level<=(I_level<=3'd4) ? I_level : 3'd2;
        sync1<={I_hs,I_vs,I_de};sync2<=sync1;
        {O_hs,O_vs,O_de}<=sync2;
        valid1<=I_de&&I_picture;valid2<=valid1;
        if(I_de&&I_picture)begin
            r_center<=$signed({1'b0,I_rgb[23:16]})-9'sd128;
            g_center<=$signed({1'b0,I_rgb[15:8]})-9'sd128;
            b_center<=$signed({1'b0,I_rgb[7:0]})-9'sd128;
        end
        if(valid1)begin
            r_num<=scale_center(r_center,level);
            g_num<=scale_center(g_center,level);
            b_num<=scale_center(b_center,level);
        end
        O_rgb<=valid2?{clip_round(r_num),clip_round(g_num),clip_round(b_num)}:24'd0;
    end
end
endmodule
