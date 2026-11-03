// timer view. The top retains startup/fault/interval diagnostic priority.
// Actual ADC: indices0..4 select physical left-to-right positions3..7.
// Segment order {DP,g,f,e,d,c,b,a}; common anode, low lights a segment.
module player_session_digits #(
    parameter ENCODED_MODE=0
)(
    input wire timer_enabled,timer_running,expired,editing,minute_selected,blink,
    input wire [4:0] hours,
    input wire [5:0] minutes,
    output wire [7:0] digit0,digit1,digit2,digit3,digit4
);
    wire [4:0] h=expired?5'd0:hours;
    wire [5:0] m=expired?6'd0:minutes;
    wire [3:0] ht=(h>=20)?4'd2:(h>=10)?4'd1:4'd0;
    wire [3:0] ho=(h>=20)?h-20:(h>=10)?h-10:h;
    wire [3:0] mt=(m>=50)?4'd5:(m>=40)?4'd4:(m>=30)?4'd3:
                  (m>=20)?4'd2:(m>=10)?4'd1:4'd0;
    wire [3:0] mo=(m>=50)?m-50:(m>=40)?m-40:(m>=30)?m-30:
                  (m>=20)?m-20:(m>=10)?m-10:m;
    localparam [7:0] DASH_CODE=ENCODED_MODE?8'hA0:8'hBF;
    localparam [7:0] BLANK_CODE=ENCODED_MODE?8'hC0:8'hFF;
    function [7:0] decimal_segments;
        input [3:0] n;
        begin case(n)
            0:decimal_segments=8'hC0;1:decimal_segments=8'hF9;
            2:decimal_segments=8'hA4;3:decimal_segments=8'hB0;
            4:decimal_segments=8'h99;5:decimal_segments=8'h92;
            6:decimal_segments=8'h82;7:decimal_segments=8'hF8;
            8:decimal_segments=8'h80;9:decimal_segments=8'h90;
            default:decimal_segments=8'hFF;
        endcase
        if(ENCODED_MODE)begin
            case(n)
                0,1,2,3,4,5,6,7,8,9:decimal_segments={4'h8,n};
                default:decimal_segments=BLANK_CODE;
            endcase
        end
        end
    endfunction
    wire unlimited=!timer_enabled && !expired;
    wire hide_hours=editing && !minute_selected && !blink && !expired;
    wire hide_minutes=editing && minute_selected && !blink && !expired;
    assign digit0=unlimited?DASH_CODE:hide_hours?BLANK_CODE:decimal_segments(ht);
    assign digit1=unlimited?DASH_CODE:hide_hours?BLANK_CODE:decimal_segments(ho);
    assign digit2=(!unlimited && !expired && timer_running && !editing && !blink)?BLANK_CODE:DASH_CODE;
    assign digit3=unlimited?DASH_CODE:hide_minutes?BLANK_CODE:decimal_segments(mt);
    assign digit4=unlimited?DASH_CODE:hide_minutes?BLANK_CODE:decimal_segments(mo);
endmodule
