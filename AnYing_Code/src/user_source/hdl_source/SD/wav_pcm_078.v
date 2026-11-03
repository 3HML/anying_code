// RIFF/WAVE chunk parser. Supports PCM format 1, 48 kHz, signed 16-bit mono.
// Chunk sizes and padding are checked against both RIFF and directory size.
// Valid PCM is held until accepted; file byte input is backpressured.
module wav_pcm_078(
 input wire clk,rst,start,
 input wire [31:0] file_size,
 input wire byte_valid,input wire [7:0] byte_data,
 output wire byte_ready,
 input wire file_done,file_error,
 output reg pcm_valid,output reg [15:0] pcm_data,input wire pcm_ready,
 output reg format_ok,done,output reg [3:0] error
);
localparam HEADER=0,CHUNK=1,CHECK=2,FMT=3,SKIP=4,PCM=5,PAD=6,TAIL=7,STOP=8;
reg [3:0] state;
reg [31:0] offset,limit,size_q,chunk_size;
reg [3:0] field;
reg [31:0] riff_size;
reg header_bad,fmt_bad;
reg fmt_id,data_id;
function [7:0] fmt_id_byte;input [1:0] n;begin case(n)0:fmt_id_byte="f";1:fmt_id_byte="m";2:fmt_id_byte="t";3:fmt_id_byte=" ";endcase end endfunction
function [7:0] data_id_byte;input [1:0] n;begin case(n)0:data_id_byte="d";1,3:data_id_byte="a";2:data_id_byte="t";endcase end endfunction
function [7:0] fmt_byte;input [3:0] n;begin
 case(n)0,2:fmt_byte=8'd1;4:fmt_byte=8'h80;5:fmt_byte=8'hbb;9:fmt_byte=8'h77;10:fmt_byte=8'h01;12:fmt_byte=8'd2;14:fmt_byte=8'd16;default:fmt_byte=0;endcase
end endfunction
function [7:0] header_byte;input [3:0] n;begin
 case(n)0:header_byte="R";1:header_byte="I";2,3:header_byte="F";8:header_byte="W";9:header_byte="A";10:header_byte="V";11:header_byte="E";default:header_byte=0;endcase
end endfunction
reg fmt_seen,have_low,chunk_odd;
reg [7:0] low;
wire take=byte_valid&&byte_ready;
assign byte_ready=(state!=CHECK&&state!=STOP)&&(!pcm_valid||pcm_ready);
task fail;input [3:0] code;begin error<=code;state<=STOP;format_ok<=0;end endtask
always @(posedge clk or posedge rst)begin
 if(rst)begin
  state<=STOP;offset<=0;limit<=0;size_q<=0;fmt_id<=0;data_id<=0;chunk_size<=0;field<=0;
  riff_size<=0;header_bad<=0;fmt_bad<=0;
  fmt_seen<=0;have_low<=0;chunk_odd<=0;low<=0;pcm_valid<=0;pcm_data<=0;format_ok<=0;done<=0;error<=0;
 end else if(start)begin
  state<=HEADER;header_bad<=0;fmt_bad<=0;offset<=0;size_q<=file_size;field<=0;fmt_seen<=0;have_low<=0;
  pcm_valid<=0;format_ok<=0;done<=0;error<=0;
 end else begin
  if(pcm_valid&&pcm_ready)pcm_valid<=0;
  if(file_error)fail(4'd1);
  else if(file_done)begin
   if(state==TAIL&&!have_low)begin done<=1;state<=STOP;end
   else fail(4'd2);
  end else if(state==CHECK)begin
   if(offset>limit || {1'b0,chunk_size}+{1'b0,offset}> {1'b0,limit})fail(4'd3);
   else begin
    field<=0;chunk_odd<=chunk_size[0];
    if(fmt_id)begin // "fmt " little endian
     if(chunk_size<16||fmt_seen)fail(4'd4);else begin state<=FMT;fmt_bad<=0;end
    end else if(data_id)begin // "data"
     if(!fmt_seen||chunk_size==0||chunk_size[0])fail(4'd5);
     else begin format_ok<=1;state<=PCM;end
    end else state<=chunk_size==0?CHUNK:SKIP;
   end
  end else if(take)begin
   offset<=offset+1'b1;
   case(state)
    HEADER:begin
     if(offset>=4&&offset<8)riff_size<={byte_data,riff_size[31:8]};
     else if(byte_data!=header_byte(offset[3:0]))header_bad<=1;
     if(offset==11)begin
      if(header_bad || byte_data!="E" ||
         riff_size<36 || {1'b0,riff_size}+33'd8>{1'b0,size_q})fail(4'd6);
      else begin limit<=riff_size+32'd8;state<=CHUNK;field<=0;end
     end
    end
    CHUNK:begin
     if(offset>=limit)fail(4'd7);
     else begin
      if(field<4)begin fmt_id<=(field==0 || fmt_id)&&(byte_data==fmt_id_byte(field[1:0]));data_id<=(field==0 || data_id)&&(byte_data==data_id_byte(field[1:0]));end
      else chunk_size<={byte_data,chunk_size[31:8]};
      if(field==7)begin state<=CHECK;field<=0;end else field<=field+1'b1;
     end
    end
    FMT:begin
     if(byte_data!=fmt_byte(field))fmt_bad<=1;
     field<=field+1'b1;chunk_size<=chunk_size-1'b1;
     if(field==15)begin
      if(fmt_bad||byte_data!=fmt_byte(field))fail(4'd8);
      else begin fmt_seen<=1;field<=0;state<=chunk_size==1?(chunk_odd?PAD:CHUNK):SKIP;end
     end
    end
    SKIP:begin chunk_size<=chunk_size-1'b1;if(chunk_size==1)begin state<=chunk_odd?PAD:CHUNK;field<=0;end end
    PAD:begin if(offset>=limit)fail(4'd3);else begin state<=CHUNK;field<=0;end end
    PCM:begin
     chunk_size<=chunk_size-1'b1;
     if(!have_low)begin low<=byte_data;have_low<=1;end
     else begin pcm_data<={byte_data,low};pcm_valid<=1;have_low<=0;end
     if(chunk_size==1)state<=TAIL;
    end
    TAIL:; // Consume legal trailing metadata; never emit it as samples.
    default:;
   endcase
  end
 end
end
endmodule
