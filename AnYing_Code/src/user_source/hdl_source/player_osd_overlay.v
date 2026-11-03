// OSD: RGB24 is retained verbatim outside the overlay masks.
// Two registered pixel stages: synchronous glyph row + matching controls/RGB,
// then foreground/background selection. This block never stalls or gates DE.
module player_osd_overlay #(
    parameter integer NOTICE_FRAMES=120,
    parameter integer SESSION_ENABLE=0
)(
    input wire I_clk,I_rst,I_hs,I_vs,I_de,
    input wire [23:0] I_rgb,
    // {ready,settings,volume_selected,brightness4,volume4,period5,auto}
    input wire [16:0] I_state,
    // {state2,enabled,running,page,selected_auto,hours5,minutes6,blink,zoom2,rotate2}
    // State0=play,1=ready,2=confirmed waiting for image,3=expired.
    input wire [21:0] I_session,
    input wire I_activity,I_display_valid,I_audio_valid,
    input wire [23:0] I_audio_pcm,
    output reg O_hs,O_vs,O_de,
    output reg [23:0] O_rgb
);
    localparam integer NOTICE_W=(NOTICE_FRAMES<2)?1:$clog2(NOTICE_FRAMES+1);
    reg vs_d,de_d,frame_seen;
    reg [9:0] pixel_x;
    reg [8:0] pixel_y;
    reg [16:0] active_state;
    reg [21:0] active_session;
    wire [1:0] session_state=active_session[21:20];
    wire timer_page=SESSION_ENABLE && active_state[15] && active_session[17];
    wire ready_page=SESSION_ENABLE && !active_state[15] && (session_state==1 || session_state==2);
    wire transform_page=SESSION_ENABLE && !active_state[15] && session_state==0 && active_state[0] && active_state[14];
    wire expired=SESSION_ENABLE && session_state==3;
    wire [4:0] hours=active_session[15:11];
    wire [5:0] minutes=active_session[10:5];
    wire [1:0] zoom=active_session[3:2],rotate=active_session[1:0];
    function [5:0] tens_glyph;
        input [5:0] value;
        begin tens_glyph=(value>=50)?6:(value>=40)?5:(value>=30)?4:(value>=20)?3:(value>=10)?2:1; end
    endfunction
    function [5:0] ones_glyph;
        input [5:0] value;
        begin ones_glyph=(value>=50)?value-49:(value>=40)?value-39:(value>=30)?value-29:(value>=20)?value-19:(value>=10)?value-9:value+1; end
    endfunction
    reg qualified,activity_pending;
    reg [NOTICE_W-1:0] notice_left;
    // Negative-polarity VS: this is its falling/assertion edge, in blanking.
    wire frame_start=vs_d && !I_vs;
    wire eligible=I_state[16] && I_display_valid;
    wire panel_visible=qualified && !expired && (active_state[15] || ready_page || transform_page || notice_left!=0);
    wire [3:0] audio_level;
    player_audio_meter u_meter(
        .clk(I_clk),.rst(I_rst),.frame_start(frame_start),
        .mute(I_state[9:6]==4'd0),.pcm_valid(I_audio_valid),
        .pcm_sample(I_audio_pcm),.level(audio_level)
    );

    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst)begin
            vs_d<=0;de_d<=0;frame_seen<=0;pixel_x<=0;pixel_y<=0;
            active_state<=0;active_session<=0;qualified<=0;activity_pending<=0;notice_left<=0;
        end else begin
            vs_d<=I_vs;de_d<=I_de;
            if(I_activity)activity_pending<=1;
            if(frame_start)begin
                frame_seen<=1;pixel_x<=0;pixel_y<=0;
                active_state<=I_state;active_session<=SESSION_ENABLE?I_session:22'd0;qualified<=eligible;activity_pending<=0;
                if(!eligible)notice_left<=0;
                else if(!qualified || I_activity || activity_pending ||
                        (active_state[15] && !I_state[15]))notice_left<=NOTICE_FRAMES;
                else if(notice_left!=0)notice_left<=notice_left-1'b1;
            end else begin
                if(I_de)pixel_x<=pixel_x+1'b1;
                else pixel_x<=0;
                if(de_d && !I_de)pixel_y<=pixel_y+1'b1;
            end
        end
    end

    // Fixed 18-cell-wide panel: two 16-pixel rows with eight-pixel margins.
    // The text uses 12 cells in row 0 and up to 10 in row 1.
    wire coordinates_valid=frame_seen && qualified && !expired && I_de;
    wire panel_region=coordinates_valid && panel_visible &&
                      pixel_x>=10'd16 && pixel_x<10'd304 &&
                      pixel_y>=9'd16 && pixel_y<9'd72;
    wire row0=(pixel_y>=9'd24 && pixel_y<9'd40);
    wire row1=(pixel_y>=9'd48 && pixel_y<9'd64);
    wire [9:0] text_x=pixel_x-10'd24;
    wire [4:0] text_col=text_x[8:4];
    wire text_region=panel_region && pixel_x>=10'd24 &&
                     pixel_x<10'd296 && (row0 || row1);
    wire [3:0] glyph_row=row0?(pixel_y-9'd24):(pixel_y-9'd48);
    wire [3:0] glyph_bit=text_x[3:0];
    reg [5:0] glyph;
    reg selected;
    reg [3:0] decimal_digit;
    always @* begin
        glyph=0;selected=0;decimal_digit=0;
        if(row0)begin
            case(text_col)
                0:glyph=12; 1:glyph=13; 2:glyph=11;
                3:glyph=active_state[0]?14:16; 4:glyph=15;
                6:glyph=17; 7:glyph=18; 8:glyph=11;
                9:begin
                    decimal_digit=(active_state[5:1]>=30)?3:
                                  (active_state[5:1]>=20)?2:
                                  (active_state[5:1]>=10)?1:0;
                    glyph={1'b0,decimal_digit}+5'd1;
                end
                10:begin
                    decimal_digit=(active_state[5:1]>=30)?active_state[5:1]-30:
                                  (active_state[5:1]>=20)?active_state[5:1]-20:
                                  (active_state[5:1]>=10)?active_state[5:1]-10:
                                  active_state[5:1];
                    glyph={1'b0,decimal_digit}+5'd1;
                end
                11:glyph=19;
                default:glyph=0;
            endcase
        end else if(row1)begin
            case(text_col)
                0:glyph=20; 1:glyph=21; 2:glyph=11;
                3:glyph={1'b0,active_state[13:10]}+5'd1;
                5:glyph=22; 6:glyph=23; 7:glyph=11;
                8:glyph=(active_state[9:6]==0)?24:({1'b0,active_state[9:6]}+5'd1);
                9:glyph=(active_state[9:6]==0)?22:0;
                default:glyph=0;
            endcase
            selected=active_state[15] &&
                     (active_state[14]?(text_col>=5 && text_col<=9):(text_col<=3));
        end
        if(timer_page)begin
            glyph=0;selected=0;
            if(row0)begin
                case(text_col)
                    0:glyph=25;1:glyph=11;
                    2:glyph=active_session[19]?tens_glyph({1'b0,hours}):35;
                    3:glyph=active_session[19]?ones_glyph({1'b0,hours}):35;
                    5:glyph=26;6:glyph=11;
                    7:glyph=active_session[19]?tens_glyph(minutes):35;
                    8:glyph=active_session[19]?ones_glyph(minutes):35;
                    default:glyph=0;
                endcase
                selected=active_session[19] && (active_state[14]?(text_col>=5 && text_col<=8):(text_col<=3));
            end else if(row1)begin
                if(active_session[19])begin
                    case(text_col)
                        0:glyph=32;1:glyph=3;2:glyph=11;3:glyph=35;
                        5:glyph=32;6:glyph=4;7:glyph=11;8:glyph=36;
                        10:glyph=32;11:glyph=5;12:glyph=11;13:glyph=20;14:glyph=21;
                        default:glyph=0;
                    endcase
                end else begin
                    case(text_col)
                        0:glyph=37;1:glyph=38;2:glyph=5;3:glyph=11;4:glyph=2;
                        7:glyph=32;8:glyph=5;9:glyph=11;10:glyph=20;11:glyph=21;
                        default:glyph=0;
                    endcase
                end
            end
        end else if(ready_page)begin
            glyph=0;selected=0;
            if(row0)begin
                case(text_col)
                    0:glyph=12;1:glyph=13;2:glyph=11;
                    3:glyph=active_session[16]?14:16;4:glyph=15;
                    7:glyph=(session_state==1)?32:0;
                    8:glyph=(session_state==1)?5:0;
                    9:glyph=(session_state==1)?11:0;
                    10:glyph=30;11:glyph=31;
                    default:glyph=0;
                endcase
                selected=text_col>=3 && text_col<=4;
            end else if(row1 && session_state==1)begin
                case(text_col)
                    0:glyph=32;1:glyph=3;2:glyph=11;3:glyph=16;4:glyph=15;
                    7:glyph=32;8:glyph=4;9:glyph=11;10:glyph=14;11:glyph=15;
                    default:glyph=0;
                endcase
            end
        end else if(transform_page)begin
            glyph=0;selected=0;
            if(row0)begin
                case(text_col)
                    0:glyph=27;1:glyph=28;2:glyph=11;
                    3:glyph=(zoom==2)?1:((zoom==1)?3:2);
                    4:glyph=(zoom==2)?34:33;
                    5:glyph=(zoom==2)?6:0;
                    6:glyph=(zoom==2)?33:0;
                    8:glyph=29;9:glyph=11;
                    10:glyph=(rotate==3)?3:(rotate==2)?2:1;
                    11:glyph=(rotate==3)?8:(rotate==2)?9:(rotate==1)?10:1;
                    12:glyph=1;13:glyph=21;
                    default:glyph=0;
                endcase
            end else if(row1)begin
                case(text_col)
                    0:glyph=32;1:glyph=3;2:glyph=11;3:glyph=27;4:glyph=28;
                    7:glyph=32;8:glyph=4;9:glyph=11;10:glyph=29;
                    12:glyph=32;13:glyph=5;14:glyph=11;15:glyph=16;16:glyph=15;
                    default:glyph=0;
                endcase
            end
        end
    end
    wire [15:0] font_pixels,main_font_pixels,extra_font_pixels;
    wire extra_font_q;
    player_osd_font u_font(.clk(I_clk),.glyph(glyph[4:0]),.row(glyph_row),.pixels(main_font_pixels));
    generate if(SESSION_ENABLE)begin:g_session_font
        player_session_osd u_extra_font(.clk(I_clk),.glyph(glyph),.row(glyph_row),.pixels(extra_font_pixels));
        reg extra_q;
        always @(posedge I_clk)extra_q<=glyph[5];
        assign extra_font_q=extra_q;
    end else begin:g_legacy_font
        assign extra_font_pixels=16'd0;
        assign extra_font_q=1'b0;
    end endgenerate
    assign font_pixels=extra_font_q?extra_font_pixels:main_font_pixels;

    wire meter_region=coordinates_valid && audio_level!=0 &&
                      pixel_x>=10'd496 && pixel_x<10'd624 &&
                      pixel_y>=9'd416 && pixel_y<9'd464;
    wire [6:0] meter_x=pixel_x-10'd496;
    wire [2:0] segment=meter_x[6:4];
    wire bar_region=meter_region && pixel_y>=9'd428 && pixel_y<9'd452 &&
                    meter_x[3:0]>=4'd2 && meter_x[3:0]<4'd14 &&
                    {1'b0,segment}<audio_level;
    wire [23:0] bar_color=(segment<5)?24'h00D060:
                           (segment<7)?24'hFFE040:24'hFF9020;
    reg hs_q,vs_q,de_q,text_q,panel_q,bar_q;
    reg [3:0] bit_q;
    reg [23:0] rgb_q,text_color_q,bar_color_q;
    always @(posedge I_clk or posedge I_rst)begin
        if(I_rst)begin
            hs_q<=0;vs_q<=0;de_q<=0;text_q<=0;panel_q<=0;bar_q<=0;bit_q<=0;
            rgb_q<=0;text_color_q<=0;bar_color_q<=0;
            O_hs<=0;O_vs<=0;O_de<=0;O_rgb<=0;
        end else begin
            hs_q<=I_hs;vs_q<=I_vs;de_q<=I_de;rgb_q<=I_rgb;
            text_q<=text_region;panel_q<=panel_region || meter_region;
            bar_q<=bar_region;bit_q<=glyph_bit;
            text_color_q<=selected?24'hFFFF00:24'hFFFFFF;bar_color_q<=bar_color;
            O_hs<=hs_q;O_vs<=vs_q;O_de<=de_q;
            if(text_q && font_pixels[4'd15-bit_q])O_rgb<=text_color_q;
            else if(bar_q)O_rgb<=bar_color_q;
            else if(panel_q)O_rgb<={1'b0,rgb_q[23:17],1'b0,rgb_q[15:9],1'b0,rgb_q[7:1]};
            else O_rgb<=rgb_q;
        end
    end
endmodule
