module video_timing_data
#(
	parameter DATA_WIDTH = 16,                      // Video data one clock data width
    parameter SLEEP_ENABLE = 0
)
(
	input                       video_clk,          // Video pixel clock
	input                       rst,
	output reg                  read_req,           // Start reading a frame of data     
	input                       read_req_ack,       // Read request response
    input                       sleep,              // Same video clock domain
    output wire                 read_active,        // Whole-frame FIFO consumption permission
    output wire                 resume_black,       // Keep final RGB black through warm-up
	//output                      read_en,            // Read data enable
	//input[DATA_WIDTH - 1:0]     read_data,          // Read data
	output                      hs,                 // horizontal synchronization
	output                      vs,                 // vertical synchronization
	output                      de                  // video valid
	//output[DATA_WIDTH - 1:0]    vout_data           // video data
);
wire                   video_hs;
wire                   video_vs;
wire                   video_de;
//delay video_hs video_vs  video_de 2 clock cycles
reg                    video_hs_d0;
reg                    video_vs_d0;
reg                    video_de_d0;
reg                    video_hs_d1;
reg                    video_vs_d1;
reg                    video_de_d1;

//reg[DATA_WIDTH - 1:0]  vout_data_r;
//assign read_en = video_de;
assign hs = video_hs_d1;
assign vs = video_vs_d1;
assign de = video_de_d1;
//assign vout_data = vout_data_r;
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		video_hs_d0 <= 1'b0;
		video_vs_d0 <= 1'b0;
		video_de_d0 <= 1'b0;
		video_hs_d1 <= 1'b0;
		video_vs_d1 <= 1'b0;
		video_de_d1 <= 1'b0;
	end
	else
	begin
		//delay video_hs video_vs  video_de 2 clock cycles
		video_hs_d0 <= video_hs;
		video_vs_d0 <= video_vs;
		video_de_d0 <= video_de;
		video_hs_d1 <= video_hs_d0;
		video_vs_d1 <= video_vs_d0;
		video_de_d1 <= video_de_d0;		
	end
end
/*
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		vout_data_r <= {DATA_WIDTH{1'b0}};
	else if(video_de_d0)
		vout_data_r <= read_data;
	else
		vout_data_r <= {DATA_WIDTH{1'b0}};
end
*/
// The raster itself never stops. Only new framebuffer requests and FIFO
// consumption are parked. Existing request/ACK levels always drain normally.
wire frame_edge=video_vs_d0 & ~video_vs;
generate if(!SLEEP_ENABLE) begin:g_legacy
assign read_active=1'b1;
assign resume_black=1'b0;
always@(posedge video_clk or posedge rst)
begin
	if(rst == 1'b1)
		read_req <= 1'b0;
	else if(video_vs_d0 & ~video_vs) //vertical synchronization edge (the rising or falling edges are OK)
		read_req <= 1'b1;
	else if(read_req_ack)
		read_req <= 1'b0;
end
end else begin:g_sleep
localparam [2:0] RUN=3'd0,STOP_FRAME=3'd1,PARK=3'd2,PRIME=3'd3,WARMUP=3'd4;
reg [2:0] sleep_state;
reg read_active_q,resume_black_q;
reg ack_seen,first_pixel_seen;
assign read_active=read_active_q;
assign resume_black=resume_black_q;
always @(posedge video_clk or posedge rst) begin
    if(rst) begin
        read_req<=0;sleep_state<=RUN;read_active_q<=1;resume_black_q<=0;
        ack_seen<=0;first_pixel_seen<=0;
    end else begin
        // Never cancel an outstanding request on sleep. The memory-domain
        // bridge/reader still drain returns, ACK, flush and release the ACK.
        if(read_req_ack)read_req<=0;
        case(sleep_state)
            RUN:begin
                if(sleep)begin
                    resume_black_q<=1;
                    if(frame_edge)begin read_active_q<=0;sleep_state<=PARK;end
                    else sleep_state<=STOP_FRAME;
                end else if(frame_edge)read_req<=1;
            end
            STOP_FRAME:begin
                // If entered from PRIME, consumption was already off and
                // stays off. Otherwise finish the current complete raster.
                if(frame_edge)begin read_active_q<=0;sleep_state<=PARK;end
            end
            PARK:begin
                if(frame_edge && !sleep && !read_req && !read_req_ack)begin
                    read_req<=1;ack_seen<=0;first_pixel_seen<=0;sleep_state<=PRIME;
                end
            end
            PRIME:begin
                if(read_req_ack)ack_seen<=1;
                if(sleep)begin
                    if(frame_edge)begin read_active_q<=0;sleep_state<=PARK;end
                    else sleep_state<=STOP_FRAME;
                end else if(frame_edge)begin
                    // A late ACK must never start consumption halfway through
                    // a raster. Retry with a new flush at a later safe VS.
                    if(!read_req && !read_req_ack)begin
                        read_req<=1;ack_seen<=0;first_pixel_seen<=0;
                    end
                end else if(video_de && !first_pixel_seen)begin
                    first_pixel_seen<=1;
                    if(ack_seen && !read_req && !read_req_ack)begin
                        // Raw DE leads the FIFO read strobe by the
                        // unchanged video_delay pipeline (more than18 clocks).
                        read_active_q<=1;sleep_state<=WARMUP;
                    end
                end
            end
            WARMUP:begin
                if(sleep)begin
                    if(frame_edge)begin read_active_q<=0;sleep_state<=PARK;end
                    else sleep_state<=STOP_FRAME;
                end else if(frame_edge)begin
                    read_req<=1;resume_black_q<=0;sleep_state<=RUN;
                end
            end
            default:begin
                read_active_q<=0;resume_black_q<=1;sleep_state<=PARK;
            end
        endcase
    end
end
end endgenerate

color_bar color_bar_m0(
	.clk(video_clk),
	.rst(rst),
	.hs(video_hs),
	.vs(video_vs),
	.de(video_de),
	.rgb_r(),
	.rgb_g(),
	.rgb_b()
);
endmodule 