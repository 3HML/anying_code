// Dual-clock PCM FIFO. Reset must be asserted to both ports together; each
// port releases locally. Extra pointer bit distinguishes full from empty.
module audio_fifo_078 #(parameter integer AW=11)(
 input wire wr_clk,wr_rst,wr_valid,
 input wire [15:0] wr_data,
 output wire wr_ready,
 output wire [AW:0] wr_level,
 input wire rd_clk,rd_rst,rd_enable,
 output reg [15:0] rd_data,
 output reg rd_valid,
 output wire rd_empty,
 output wire [AW:0] rd_level
);
reg [15:0] ram[0:(1<<AW)-1];
reg [AW:0] wb,rb,wg,rg;
(* ASYNC_REG="TRUE" *) reg [AW:0] rg_meta,rg_sync,wg_meta,wg_sync;
function [AW:0] binary;
 input [AW:0] g;integer n;
 begin binary[AW]=g[AW];for(n=AW-1;n>=0;n=n-1)binary[n]=binary[n+1]^g[n];end
endfunction
wire full=wg=={~rg_sync[AW:AW-1],rg_sync[AW-2:0]};
assign wr_ready=!full&&!wr_rst;
assign rd_empty=rg==wg_sync;
assign wr_level=wb-binary(rg_sync);
assign rd_level=binary(wg_sync)-rb;
wire [AW:0] wn=wb+1'b1,rn=rb+1'b1;
always @(posedge wr_clk)if(wr_valid&&wr_ready)ram[wb[AW-1:0]]<=wr_data;
always @(posedge rd_clk)if(rd_enable&&!rd_empty&&!rd_rst)rd_data<=ram[rb[AW-1:0]];
always @(posedge wr_clk or posedge wr_rst)begin
 if(wr_rst)begin wb<=0;wg<=0;rg_meta<=0;rg_sync<=0;end
 else begin
  rg_meta<=rg;rg_sync<=rg_meta;
  if(wr_valid&&wr_ready)begin wb<=wn;wg<=wn^(wn>>1);end
 end
end
always @(posedge rd_clk or posedge rd_rst)begin
 if(rd_rst)begin rb<=0;rg<=0;wg_meta<=0;wg_sync<=0;rd_valid<=0;end
 else begin
  wg_meta<=wg;wg_sync<=wg_meta;rd_valid<=rd_enable&&!rd_empty;
  if(rd_enable&&!rd_empty)begin rb<=rn;rg<=rn^(rn>>1);end
 end
end
endmodule
