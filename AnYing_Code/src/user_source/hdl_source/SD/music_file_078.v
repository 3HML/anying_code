module music_file_078 #(
 parameter integer VALIDATED_GEOMETRY=0,
 parameter integer REQUEST_TIMEOUT_CYCLES=100000000
)(
 input wire clk,rst,storage_ready,music_found,
 input wire next_track,audio_owner,
 input wire [5:0] track_count,
 output reg [4:0] track_index,
 output wire next_ready,
 input wire [27:0] first_cluster,
 input wire [31:0] size_bytes,data_lba,fat_lba,cluster_count,
 input wire [7:0] sectors_per_cluster,
 input wire [32:0] validated_data_end,
 output wire sector_req,output wire [31:0] sector_lba,
 input wire [7:0] sector_byte,input wire sector_valid,sector_end,
 output reg urgent,
 input wire audio_clk,audio_reset,pcm_read,
 output wire [15:0] pcm_data,output wire pcm_valid,pcm_empty,
 output wire [11:0] pcm_level,
 output reg [3:0] error,output wire format_ok
);
reg [1:0] wr_reset,rd_reset;
wire common_reset=rst||audio_reset;
reg flush;
wire stream_reset=wr_reset[1]||flush;
wire audio_flush_reset=common_reset||flush;
(* ASYNC_REG="TRUE" *) reg [1:0] flush_ack;
always @(posedge clk or posedge common_reset)begin
 if(common_reset)flush_ack<=0;else flush_ack<={flush_ack[0],rd_reset[1]};
end
always @(posedge clk or posedge common_reset)begin
 if(common_reset)wr_reset<=3;else wr_reset<={wr_reset[0],1'b0};
end
always @(posedge audio_clk or posedge audio_flush_reset)begin
 if(audio_flush_reset)rd_reset<=3;else rd_reset<={rd_reset[0],1'b0};
end
wire file_busy,file_done,file_valid,file_ready,file_end,file_abort;
wire [7:0] file_error,file_byte;
wire [31:0] file_offset;
wire parser_done,parser_valid,fifo_ready;
wire [3:0] parser_error;
wire [15:0] parser_sample;
wire [11:0] write_level;
reg start;
localparam [2:0] WAIT=0,PLAY=1,STOP=2,FLUSH=3,RELEASE=4,START=5,PARK=6;
reg [2:0] state;
reg [5:0] fail_count;
wire [5:0] next_index={1'b0,track_index}+6'd1;
assign next_ready=music_found&&storage_ready&&track_count!=0&&(state==PLAY||state==PARK);
reg ended,advance,park_after,abort_track;
reg [2:0] quiet;
wire failed=(parser_error!=0)||(file_done&&file_error!=0);
// Advisory arbitration priority is registered in the SD clock domain.
// The FIFO full/empty and parser backpressure remain immediate and unchanged.
// A one-clock priority delay is covered by the existing 768-sample reserve;
// sector ownership still stays locked until END.
always @(posedge clk or posedge wr_reset[1])begin
 if(wr_reset[1])urgent<=1'b1;
 else urgent<=write_level<12'd768;
end
fat32_audio_reader_078 #(.VALIDATED_GEOMETRY(VALIDATED_GEOMETRY),.REQUEST_TIMEOUT_CYCLES(REQUEST_TIMEOUT_CYCLES)) reader(
 .clk(clk),.rst(stream_reset),.start(start),.abort(abort_track||parser_error!=0),.storage_ready(storage_ready),.storage_error(1'b0),
 .validated_data_end(validated_data_end),.prefix_only(1'b0),.first_cluster(first_cluster),.size_bytes(size_bytes),.data_lba(data_lba),.active_fat_lba(fat_lba),
 .cluster_count(cluster_count),.sectors_per_cluster(sectors_per_cluster),.sector_req(sector_req),.sector_lba(sector_lba),
 .sector_byte(sector_byte),.sector_valid(sector_valid),.sector_end(sector_end),.sector_abort(file_abort),
 .busy(file_busy),.done(file_done),.error(file_error),.file_valid(file_valid),.file_ready(file_ready),
 .file_byte(file_byte),.file_byte_offset(file_offset),.file_end(file_end));
wav_pcm_078 parser(.clk(clk),.rst(stream_reset),.start(start),.file_size(size_bytes),
 .byte_valid(file_valid),.byte_data(file_byte),.byte_ready(file_ready),.file_done(file_end),.file_error(file_done&&file_error!=0),
 .pcm_valid(parser_valid),.pcm_data(parser_sample),.pcm_ready(fifo_ready),.format_ok(format_ok),.done(parser_done),.error(parser_error));
audio_fifo_078 fifo(.wr_clk(clk),.wr_rst(stream_reset),.wr_valid(parser_valid&&!abort_track),.wr_data(parser_sample),
 .wr_ready(fifo_ready),.wr_level(write_level),.rd_clk(audio_clk),.rd_rst(rd_reset[1]),.rd_enable(pcm_read),
 .rd_data(pcm_data),.rd_valid(pcm_valid),.rd_empty(pcm_empty),.rd_level(pcm_level));
// Changing a track never resets the physical arbiter. Abort the logical
// reader, wait for the owned sector's real END, then flush both FIFO ports.
// The read-domain reset assertion and release are acknowledged before restart.
always @(posedge clk or posedge wr_reset[1])begin
 if(wr_reset[1])begin
  start<=0;error<=0;state<=WAIT;flush<=1;abort_track<=0;
  track_index<=0;fail_count<=0;ended<=0;advance<=0;park_after<=0;quiet<=0;
 end else begin
  start<=0;
  if(file_done&&file_error==0)ended<=1;
  if(next_track&&music_found&&track_count!=0&&(state==PLAY||state==PARK))begin
   advance<=1;park_after<=0;fail_count<=0;abort_track<=1;quiet<=0;state<=STOP;
  end else case(state)
   WAIT:if(music_found&&storage_ready&&track_count!=0)begin advance<=0;park_after<=0;state<=FLUSH;end
   PLAY:begin
    if(failed)begin
     error<=parser_error!=0?parser_error:4'd9;
     fail_count<=fail_count+6'd1;park_after<=(fail_count+6'd1>=track_count);
     advance<=1;abort_track<=1;quiet<=0;state<=STOP;
    end else if(ended&&parser_done&&!parser_valid&&write_level==0)begin
     fail_count<=0;advance<=1;park_after<=0;abort_track<=1;quiet<=0;state<=STOP;
    end
   end
   STOP:begin
    if(quiet!=7)quiet<=quiet+1'b1;
    if(quiet==7&&!file_busy&&!sector_req&&!audio_owner)begin
     flush<=1;
     if(advance)track_index<=(next_index>=track_count)?5'd0:next_index[4:0];
     state<=FLUSH;
    end
   end
   FLUSH:if(flush_ack[1])begin flush<=0;state<=RELEASE;end
   RELEASE:if(!flush_ack[1])begin
    abort_track<=0;ended<=0;state<=park_after?PARK:START;
   end
   START:if(storage_ready)begin error<=0;start<=1;state<=PLAY;end
   PARK:; // All selected tracks failed: wait for an explicit next-track request.
   default:state<=WAIT;
  endcase
 end
end
endmodule
