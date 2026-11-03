// Fixed 5-byte request / 15-byte response, one outstanding transaction.
// All application ports are in clk domain. No clocks, media buffers or text ROMs.
module uart_control_link_093 #(
    parameter integer CLOCK_HZ=100000000,
    parameter integer BAUD=115200,
    parameter integer GAP_CYCLES=CLOCK_HZ/50
)(
    input wire clk,rst,rx,
    output wire tx,
    output reg command_valid,
    output reg [7:0] command,argument,
    input wire reply_valid,
    input wire [2:0] reply_result,
    input wire [79:0] status
);
localparam integer DIV=(CLOCK_HZ+BAUD/2)/BAUD;
localparam integer CW=(DIV>1)?$clog2(DIV):1;
localparam integer GW=(GAP_CYCLES>1)?$clog2(GAP_CYCLES):1;
(* async_reg="true" *) reg rx_meta,rx_sync;
reg rx_previous;
always @(posedge clk or posedge rst)begin
    if(rst)begin rx_meta<=1;rx_sync<=1;rx_previous<=1;end
    else begin rx_meta<=rx;rx_sync<=rx_meta;rx_previous<=rx_sync;end
end
reg [1:0] rx_state;
reg [CW-1:0] rx_count;
reg [2:0] rx_bit;
reg [7:0] rx_shift,rx_byte;
reg rx_valid,rx_error;
always @(posedge clk or posedge rst)begin
    if(rst)begin rx_state<=0;rx_count<=0;rx_bit<=0;rx_shift<=0;rx_byte<=0;rx_valid<=0;rx_error<=0;end
    else begin
        rx_valid<=0;rx_error<=0;
        case(rx_state)
        0:if(rx_previous&&!rx_sync)begin rx_state<=1;rx_count<=DIV/2-1;end
        1:if(rx_count!=0)rx_count<=rx_count-1'b1;
          else if(!rx_sync)begin rx_state<=2;rx_count<=DIV-1;rx_bit<=0;end
          else rx_state<=0;
        2:if(rx_count!=0)rx_count<=rx_count-1'b1;
          else begin
              rx_shift<={rx_sync,rx_shift[7:1]};rx_count<=DIV-1;
              if(rx_bit==7)rx_state<=3;else rx_bit<=rx_bit+1'b1;
          end
        3:if(rx_count!=0)rx_count<=rx_count-1'b1;
          else begin rx_state<=0;rx_byte<=rx_shift;rx_valid<=rx_sync;rx_error<=!rx_sync;end
        endcase
    end
end
reg [9:0] tx_shift;
reg [CW-1:0] tx_count;
reg [3:0] tx_bits;
reg tx_start;
reg [7:0] tx_byte;
wire tx_busy=tx_bits!=0;
assign tx=tx_shift[0];
always @(posedge clk or posedge rst)begin
    if(rst)begin tx_shift<=10'h3ff;tx_count<=0;tx_bits<=0;end
    else if(tx_start&&!tx_busy)begin tx_shift<={1'b1,tx_byte,1'b0};tx_bits<=10;tx_count<=DIV-1;end
    else if(tx_busy)begin
        if(tx_count!=0)tx_count<=tx_count-1'b1;
        else begin tx_count<=DIV-1;tx_shift<={1'b1,tx_shift[9:1]};tx_bits<=tx_bits-1'b1;end
    end
end
function [7:0] crc8;
    input [7:0] crc,data;
    reg [7:0] c;
    integer i;
    begin c=crc^data;for(i=0;i<8;i=i+1)c=c[7]?{c[6:0],1'b0}^8'h07:{c[6:0],1'b0};crc8=c;end
endfunction
localparam [2:0] RECEIVE=0,WAIT_REPLY=1,CAPTURE=2,SEND=3,DRAIN=4;
reg [2:0] phase,packet_index;
reg [7:0] sequence_id,receive_crc,send_crc;
reg [2:0] response_result;
reg [GW-1:0] gap;
reg [79:0] snapshot;
reg [3:0] send_index;
reg [7:0] send_byte;
always @*begin
    case(send_index)
        0:send_byte=8'h5a;
        1:send_byte=sequence_id;
        2:send_byte=command;
        3:send_byte={5'd0,response_result};
        14:send_byte=send_crc;
        default:send_byte=snapshot[7:0];
    endcase
end
always @(posedge clk or posedge rst)begin
    if(rst)begin
        phase<=RECEIVE;packet_index<=0;sequence_id<=0;receive_crc<=0;gap<=0;
        command_valid<=0;command<=0;argument<=0;response_result<=0;
        tx_start<=0;tx_byte<=0;send_index<=0;send_crc<=0;
    end else begin
        command_valid<=0;tx_start<=0;
        if(packet_index!=0||phase==WAIT_REPLY)begin
            if(gap!=GAP_CYCLES-1)gap<=gap+1'b1;
        end else gap<=0;
        case(phase)
        RECEIVE:begin
            if(rx_error||gap==GAP_CYCLES-1)packet_index<=0;
            else if(rx_valid)begin
                gap<=0;
                case(packet_index)
                0:if(rx_byte==8'ha5)begin receive_crc<=crc8(0,8'ha5);packet_index<=1;end
                1:begin sequence_id<=rx_byte;receive_crc<=crc8(receive_crc,rx_byte);packet_index<=2;end
                2:begin command<=rx_byte;receive_crc<=crc8(receive_crc,rx_byte);packet_index<=3;end
                3:begin argument<=rx_byte;receive_crc<=crc8(receive_crc,rx_byte);packet_index<=4;end
                4:begin
                    packet_index<=0;
                    if(rx_byte==receive_crc)begin command_valid<=1;phase<=WAIT_REPLY;end
                    else begin response_result<=5;phase<=CAPTURE;end
                end
                default:packet_index<=0;
                endcase
            end
        end
        WAIT_REPLY:begin
            if(reply_valid)begin response_result<=reply_result;phase<=CAPTURE;end
            else if(gap==GAP_CYCLES-1)begin response_result<=3;phase<=CAPTURE;end
        end
        CAPTURE:begin
            // One extra edge lets registered control pulses reach their owners.
            send_index<=0;send_crc<=0;phase<=SEND;
        end
        SEND:if(!tx_busy&&!tx_start)begin
            tx_byte<=send_byte;tx_start<=1;
            if(send_index==14)phase<=DRAIN;
            else begin
                send_crc<=crc8(send_crc,send_byte);
                send_index<=send_index+1'b1;
            end
        end
        DRAIN:if(!tx_busy&&!tx_start)begin phase<=RECEIVE;gap<=0;packet_index<=0;end
        default:begin phase<=RECEIVE;packet_index<=0;end
        endcase
    end
end
// snapshot is written in CAPTURE before any SEND. Its
// data registers need no reset; protocol/control/TX registers have reset.
always @(posedge clk) begin
    if(phase==CAPTURE) snapshot<=status;
    else if(phase==SEND&&!tx_busy&&!tx_start&&send_index>=4&&send_index<14)
        snapshot<={8'd0,snapshot[79:8]};
end
endmodule
