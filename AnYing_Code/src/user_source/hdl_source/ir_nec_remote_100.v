// active-low demodulated NEC receiver. Independent synchronous RTL.
// Byte display/mapping follows the reference handset's arrival-order notation:
// e.g. NEC command 0x45 sent LSB-first is displayed as 0xA2 (Power).
// Standard NEC short repeat frames are accepted but never generate an action.
module ir_nec_remote_100 #(
    parameter integer CLK_FREQ_HZ=100_000_000
)(
    input wire clk,rst,ir_rx,
    output reg action_valid,
    output reg [3:0] action,
    output reg [7:0] last_command,frame_count
);
localparam integer DIV=(CLK_FREQ_HZ/100000>0)?CLK_FREQ_HZ/100000:1;
localparam integer DW=(DIV>1)?$clog2(DIV):1;
localparam [2:0] IDLE=0,LEAD_LOW=1,LEAD_HIGH=2,BIT_LOW=3,BIT_HIGH=4,STOP_LOW=5,REPEAT_LOW=6;
(* async_reg="true" *) reg [2:0] rx_sync;
reg [DW-1:0] divider;
reg [2:0] samples;
reg level;
reg [10:0] duration;
reg [2:0] state;
reg [4:0] bit_index;
reg [31:0] frame;
wire tick=divider==DIV-1;
wire filtered=(samples==3'b111)?1'b1:(samples==3'b000)?1'b0:level;
wire edge_seen=filtered!=level;
wire mark_ok=duration>=35 && duration<=80;
wire zero_ok=duration>=35 && duration<=90;
wire one_ok=duration>=130 && duration<=200;
wire leader_ok=duration>=800 && duration<=1000;
wire frame_ok=frame[31:24]==8'h00 && frame[23:16]==8'hff &&
              (frame[15:8]^frame[7:0])==8'hff;
always @(posedge clk or posedge rst)begin
    if(rst)rx_sync<=3'b111;
    else rx_sync<={rx_sync[1:0],ir_rx};
end
always @(posedge clk or posedge rst)begin
    if(rst)begin
        divider<=0;samples<=3'b111;level<=1;duration<=0;
        state<=IDLE;bit_index<=0;frame<=0;
        action_valid<=0;action<=0;last_command<=0;frame_count<=0;
    end else begin
        action_valid<=0;
        if(tick)begin
            divider<=0;samples<={samples[1:0],rx_sync[2]};
            if(duration!=11'h7ff)duration<=duration+1'b1;
            if(state!=IDLE && duration>=1200)state<=IDLE;
            if(edge_seen)begin
                level<=filtered;duration<=0;
                case(state)
                    IDLE:if(!filtered)state<=LEAD_LOW;
                    LEAD_LOW:if(filtered && leader_ok)state<=LEAD_HIGH;else state<=IDLE;
                    LEAD_HIGH:begin
                        if(!filtered && duration>=350 && duration<=550)begin
                            state<=BIT_LOW;bit_index<=0;frame<=0;
                        end else if(!filtered && duration>=200 && duration<=250)state<=REPEAT_LOW;
                        else state<=IDLE;
                    end
                    BIT_LOW:if(filtered && mark_ok)state<=BIT_HIGH;else state<=IDLE;
                    BIT_HIGH:begin
                        if(!filtered && (zero_ok||one_ok))begin
                            frame<={frame[30:0],one_ok};
                            if(bit_index==31)state<=STOP_LOW;
                            else begin bit_index<=bit_index+1'b1;state<=BIT_LOW;end
                        end else state<=IDLE;
                    end
                    STOP_LOW:begin
                        state<=IDLE;
                        if(filtered && mark_ok && frame_ok)begin
                            last_command<=frame[15:8];frame_count<=frame_count+1'b1;
                            action_valid<=1;
                            case(frame[15:8])
                                8'ha2:action<=4'd0; // Power: sleep / wake only
                                8'he2:action<=4'd1; // Menu: settings
                                8'h22:action<=4'd2; // Test: brightness up
                                8'h02:action<=4'd3; // +: volume up
                                8'hc2:action<=4'd4; // Return: manual / auto
                                8'he0:action<=4'd5; // Left: thumbnails / open selected
                                8'ha8:action<=4'd6; // Play: music on/off
                                8'h90:action<=4'd7; // Right: next image (manual)
                                8'h68:action<=4'd8; // 0: brightness down
                                8'h98:action<=4'd9; // -: volume down
                                8'hb0:action<=4'd10; // C: next song
                                8'h30:action<=4'd11; // 1: thumbnail left/right
                                8'h18:action<=4'd12; // 2: thumbnail up/down
                                8'h7a:action<=4'd13; // 3: slideshow period (ordinary Auto only)
                                default:action_valid<=0;
                            endcase
                        end
                    end
                    REPEAT_LOW:state<=IDLE;
                    default:state<=IDLE;
                endcase
            end
        end else divider<=divider+1'b1;
    end
end
endmodule
