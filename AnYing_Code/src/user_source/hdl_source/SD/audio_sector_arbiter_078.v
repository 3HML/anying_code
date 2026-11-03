// Entire physical sector ownership is retained through END, even if a client
// abandons its request. Two quiet clocks let synchronous clients retire END.
module audio_sector_arbiter_078(
 input wire clk,rst,storage_ready,
 input wire bmp_req,input wire [31:0] bmp_lba,
 input wire audio_req,input wire [31:0] audio_lba,input wire audio_urgent,
 output wire physical_req,output reg [31:0] physical_lba,
 input wire physical_valid,physical_end,
 output wire bmp_valid,bmp_end,audio_valid,audio_end,
 output wire audio_owner,output wire bmp_active
);
reg [1:0] state;reg owner,last_audio;
assign physical_req=state==1;
assign bmp_active=state==1&&!owner;
assign audio_owner=state==1&&owner;
assign bmp_valid=state==1&&!owner&&physical_valid;
assign audio_valid=state==1&&owner&&physical_valid;
assign bmp_end=state==1&&!owner&&physical_end;
assign audio_end=state==1&&owner&&physical_end;
always @(posedge clk or posedge rst)begin
 if(rst)begin state<=0;owner<=0;last_audio<=0;physical_lba<=0;end
 else case(state)
  0:if(storage_ready&&(bmp_req||audio_req))begin
   if(audio_req&&(!bmp_req||audio_urgent||!last_audio))begin owner<=1;physical_lba<=audio_lba;last_audio<=1;end
   else begin owner<=0;physical_lba<=bmp_lba;last_audio<=0;end
   state<=1;
  end
  1:if(physical_end)state<=2;
  2:state<=3;
  3:state<=0;
 endcase
end
endmodule
