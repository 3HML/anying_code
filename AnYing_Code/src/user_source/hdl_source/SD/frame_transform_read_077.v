`timescale 1ns/1ps

// Four-line ping/pong cache. All transactions use the existing queued SDRAM

// interface. A frame ACK is issued only after every old read has returned.

// fixed orientation; selected zoom is preserved and excess pixels are center-cropped.
// Input transform bundle is synchronous to mem_clk and held across read_req.

// zoom:0=100%,1=200%,2=50%,3=25%,4=75%,5=125%,6=150%,7=175%.
// read_rotate remains an ignored compatibility port; rotation is not implemented.

module frame_transform_read_077 #(

    parameter ADDR_BITS=21, parameter integer THUMB_ENABLE=0

)(

    input wire rst,mem_clk,Sdr_init_done,App_wr_busy,

    input wire Sdr_rd_en,input wire [31:0] Sdr_rd_dout,

    output wire O_rd_busy,output reg App_rd_en,

    output reg [ADDR_BITS-1:0] App_rd_addr,

    input wire read_req,output reg read_req_ack,output reg read_finish,

    input wire [ADDR_BITS-1:0] read_addr_0,read_addr_1,read_addr_2,read_addr_3,

    input wire [1:0] read_addr_index,read_rotate,
    input wire [2:0] read_zoom,
    input wire read_thumbnail,
    input wire [3:0] read_ready_banks,

    output reg fifo_aclr,input wire [9:0] wrusedw,

    output reg fifo_we,output reg [31:0] fifo_data

);

    localparam IDLE=0,ACK=1,TILE=2,WAIT_BUS=3,ISSUE=4,DRAIN=5,FINISH_TILE=6,DONE=7;

    reg [2:0] state;

    reg [2:0] req_sync;

    reg [ADDR_BITS-1:0] frame_base;

    reg [2:0] zoom;

    reg [9:0] left_edge,right_edge;

    reg [8:0] top_edge,bottom_edge;

    reg [9:0] map_u_start;
    reg [8:0] map_v_head;

    reg [2:0] map_u_start_rem,map_v_head_rem;

    reg [2:0] step_whole;
    reg [2:0] denominator,head_step_rem;
    reg [4:0] head_step_whole;

    reg [2:0] step_rem;

    reg [1:0] ready;

    reg fill_bank,drain_bank;

    reg [8:0] fill_y,drain_y;

    reg [9:0] emit_x;

    reg [1:0] emit_line;

    reg [9:0] issue_x,return_x;

    reg [1:0] issue_line,return_line;

    reg [9:0] map_u;
    reg [8:0] map_v;

    reg [2:0] map_u_rem,map_v_rem;

    reg [8:0] burst_issued,burst_returned;

    reg issue_complete;

    reg [23:0] tile_memory [0:8191]; /* fehdl force_ram=1, ram_style="bram" */
    reg [23:0] tile_read_data;
    reg tile_read_black;
    // Explicit output stage breaks the tile-BRAM to FIFO-BRAM path.
    // Data, valid and last-pixel finish advance together; ACK flushes both stages.
    reg pixel_pending, finish_pending;
    always @(posedge mem_clk) fifo_data<=tile_read_black?32'd0:{tile_read_data,7'd0,1'b1};




    wire [3:0] u_rem_sum={1'b0,map_u_rem}+{1'b0,step_rem};
    wire [3:0] v_rem_sum={1'b0,map_v_rem}+{1'b0,step_rem};
    wire [9:0] next_u=map_u+step_whole+(u_rem_sum>=denominator);
    wire [8:0] next_v=map_v+step_whole+(v_rem_sum>=denominator);
    wire [2:0] next_u_rem=(u_rem_sum>=denominator)?u_rem_sum-denominator:u_rem_sum;
    wire [2:0] next_v_rem=(v_rem_sum>=denominator)?v_rem_sum-denominator:v_rem_sum;
    // Four-row increment is precomputed in the mode table; no divider or multiplier.
    wire [3:0] head_rem_sum={1'b0,map_v_head_rem}+{1'b0,head_step_rem};
    wire [8:0] next_head=map_v_head+head_step_whole+(head_rem_sum>=denominator);
    wire [2:0] next_head_rem=(head_rem_sum>=denominator)?head_rem_sum-denominator:head_rem_sum;

    reg thumbnail;
    reg [3:0] ready_banks;
    // fill_y is a four-row tile origin. Capture the row reduction in TILE,
    // before WAIT_BUS/ISSUE, so the address path has no fill_y subtract/compare.
    // The 0/240/480 thumbnail boundaries are all four-row aligned.
    reg [5:0] thumb_tile_row;
    reg thumb_tile_bank;
    wire [1:0] issue_bank={thumb_tile_bank,issue_x>=320};
    wire [1:0] emit_bank={drain_y>=240,emit_x>=320};
    wire [9:0] thumb_x=(issue_x-((issue_x>=320)?10'd320:10'd0))<<1;
    wire [8:0] thumb_y={thumb_tile_row,issue_line,1'b0};
    wire [9:0] source_x=thumbnail?thumb_x:map_u;
    wire [8:0] source_y=thumbnail?thumb_y:map_v[8:0];
    // Base inputs are fixed memory-map constants in the integration contract.
    wire [ADDR_BITS-1:0] thumb_base=issue_bank==0?read_addr_0:issue_bank==1?read_addr_1:issue_bank==2?read_addr_2:read_addr_3;
    wire [ADDR_BITS-1:0] source_base=(thumbnail&&ready_banks[issue_bank])?thumb_base:frame_base;
    wire [ADDR_BITS-1:0] source_offset=({{(ADDR_BITS-9){1'b0}},source_y}<<9)+

                                                     ({{(ADDR_BITS-9){1'b0}},source_y}<<7)+source_x;

    wire last_issue=issue_x==right_edge && issue_line==3;

    wire tile_black=fill_y<top_edge || fill_y>=bottom_edge;

    wire emit_black=emit_x<left_edge || emit_x>right_edge || drain_y<top_edge || drain_y>=bottom_edge || (thumbnail&&!ready_banks[emit_bank]);

    wire consume=ready[drain_bank] && wrusedw<10'd480 && !fifo_aclr && state!=ACK && !req_sync[2];

    assign O_rd_busy=(state==ISSUE)||(state==DRAIN)||App_rd_en;



    // A single clocked write and clocked read permit native block-RAM inference.

    // Entries outside the active rectangle are never inspected; output is black.

    always @(posedge mem_clk)begin

        if(Sdr_rd_en && (state==ISSUE || state==DRAIN))

            tile_memory[{fill_bank,return_line,return_x}]<=Sdr_rd_dout[31:8];

        if(consume) tile_read_data<=tile_memory[{drain_bank,emit_line,emit_x}];
    end
    always @(posedge mem_clk)begin
        if(consume) tile_read_black<=emit_black;

    end

    always @(posedge mem_clk or posedge rst)begin

        if(rst)begin

            req_sync<=0;state<=IDLE;read_req_ack<=0;read_finish<=0;fifo_aclr<=1;

            App_rd_en<=0;App_rd_addr<=0;fifo_we<=0;pixel_pending<=0;finish_pending<=0;frame_base<=0;zoom<=0;thumbnail<=0;ready_banks<=0;

            left_edge<=0;right_edge<=639;top_edge<=0;bottom_edge<=480;

            map_u_start<=0;map_v_head<=0;map_u_start_rem<=0;map_v_head_rem<=0;step_whole<=1;step_rem<=0;denominator<=1;head_step_whole<=4;head_step_rem<=0;

            ready<=0;fill_bank<=0;drain_bank<=0;fill_y<=0;drain_y<=0;emit_x<=0;emit_line<=0;

            issue_x<=0;return_x<=0;issue_line<=0;return_line<=0;map_u<=0;map_v<=0;map_u_rem<=0;map_v_rem<=0;

            burst_issued<=0;burst_returned<=0;issue_complete<=0;
            thumb_tile_row<=0;thumb_tile_bank<=0;

        end else begin

            req_sync<={req_sync[1:0],read_req};

            App_rd_en<=0;read_finish<=finish_pending;fifo_we<=pixel_pending;
            pixel_pending<=consume;finish_pending<=consume && emit_x==639 && drain_y==479;

            if(consume)begin

                if(emit_x==639)begin

                    emit_x<=0;emit_line<=emit_line+1'b1;drain_y<=drain_y+1'b1;

                    if(emit_line==3)begin ready[drain_bank]<=0;drain_bank<=!drain_bank;end

                    // Last-pixel finish is aligned with the extra output stage above.

                end else emit_x<=emit_x+1'b1;

            end

            if(Sdr_rd_en && (state==ISSUE || state==DRAIN))begin

                burst_returned<=burst_returned+1'b1;

                if(return_x==right_edge)begin

                    return_x<=left_edge;return_line<=return_line+1'b1;

                end else return_x<=return_x+1'b1;

            end

            case(state)

                IDLE:if(req_sync[2] && Sdr_init_done)state<=ACK;

                ACK:begin

                    fifo_aclr<=1;fifo_we<=0;pixel_pending<=0;finish_pending<=0;read_finish<=0;ready<=0;read_req_ack<=1;

                    fill_bank<=0;drain_bank<=0;fill_y<=0;drain_y<=0;emit_x<=0;emit_line<=0;

                    burst_issued<=0;burst_returned<=0;issue_complete<=0;

                    if(!read_req_ack)begin

                    case(read_addr_index)

                        0:frame_base<=read_addr_0;1:frame_base<=read_addr_1;

                        2:frame_base<=read_addr_2;3:frame_base<=read_addr_3;

                    endcase

                    zoom<=read_zoom;
                    thumbnail<=THUMB_ENABLE&&read_thumbnail;ready_banks<=read_ready_banks;

                    if(THUMB_ENABLE&&read_thumbnail)begin
                        left_edge<=0;right_edge<=639;top_edge<=0;bottom_edge<=480;
                        map_u_start<=0;map_v_head<=0;map_u_start_rem<=0;map_v_head_rem<=0;
                        step_whole<=0;step_rem<=0;denominator<=1;head_step_whole<=0;head_step_rem<=0;
                    end else case(read_zoom)
                        3'd0:begin // 100%
                            left_edge<=0;right_edge<=639;top_edge<=0;bottom_edge<=480;
                            map_u_start<=0;map_u_start_rem<=0;map_v_head<=0;map_v_head_rem<=0;
                            step_whole<=1;step_rem<=0;denominator<=1;head_step_whole<=4;head_step_rem<=0;
                        end
                        3'd1:begin // 200%
                            left_edge<=0;right_edge<=639;top_edge<=0;bottom_edge<=480;
                            map_u_start<=160;map_u_start_rem<=0;map_v_head<=120;map_v_head_rem<=0;
                            step_whole<=0;step_rem<=1;denominator<=2;head_step_whole<=2;head_step_rem<=0;
                        end
                        3'd2:begin // 50%
                            left_edge<=160;right_edge<=479;top_edge<=120;bottom_edge<=360;
                            map_u_start<=0;map_u_start_rem<=0;map_v_head<=0;map_v_head_rem<=0;
                            step_whole<=2;step_rem<=0;denominator<=1;head_step_whole<=8;head_step_rem<=0;
                        end
                        3'd3:begin // 25%
                            left_edge<=240;right_edge<=399;top_edge<=180;bottom_edge<=300;
                            map_u_start<=0;map_u_start_rem<=0;map_v_head<=0;map_v_head_rem<=0;
                            step_whole<=4;step_rem<=0;denominator<=1;head_step_whole<=16;head_step_rem<=0;
                        end
                        3'd4:begin // 75%
                            left_edge<=80;right_edge<=559;top_edge<=60;bottom_edge<=420;
                            map_u_start<=0;map_u_start_rem<=0;map_v_head<=0;map_v_head_rem<=0;
                            step_whole<=1;step_rem<=1;denominator<=3;head_step_whole<=5;head_step_rem<=1;
                        end
                        3'd5:begin // 125%
                            left_edge<=0;right_edge<=639;top_edge<=0;bottom_edge<=480;
                            map_u_start<=64;map_u_start_rem<=0;map_v_head<=48;map_v_head_rem<=0;
                            step_whole<=0;step_rem<=4;denominator<=5;head_step_whole<=3;head_step_rem<=1;
                        end
                        3'd6:begin // 150%
                            left_edge<=0;right_edge<=639;top_edge<=0;bottom_edge<=480;
                            map_u_start<=106;map_u_start_rem<=2;map_v_head<=80;map_v_head_rem<=0;
                            step_whole<=0;step_rem<=2;denominator<=3;head_step_whole<=2;head_step_rem<=2;
                        end
                        3'd7:begin // 175%
                            left_edge<=0;right_edge<=639;top_edge<=0;bottom_edge<=480;
                            map_u_start<=137;map_u_start_rem<=1;map_v_head<=102;map_v_head_rem<=6;
                            step_whole<=0;step_rem<=4;denominator<=7;head_step_whole<=2;head_step_rem<=2;
                        end
                    endcase

                    end

                    if(!req_sync[2])begin read_req_ack<=0;fifo_aclr<=0;state<=TILE;end

                end

                TILE:begin

                    if(req_sync[2])state<=ACK;

                    else if(!ready[fill_bank])begin

                        if(tile_black)state<=FINISH_TILE;

                        else begin

                            issue_x<=left_edge;return_x<=left_edge;issue_line<=0;return_line<=0;
                            thumb_tile_row<=fill_y[8:2]-((fill_y>=240)?7'd60:7'd0);
                            thumb_tile_bank<=fill_y>=240;

                            map_u<=map_u_start;map_u_rem<=map_u_start_rem;

                            map_v<=map_v_head;map_v_rem<=map_v_head_rem;

                            issue_complete<=0;state<=WAIT_BUS;

                        end

                    end

                end

                WAIT_BUS:begin

                    burst_issued<=0;burst_returned<=0;

                    if(req_sync[2])state<=ACK;

                    else if(!App_wr_busy)state<=ISSUE;

                end

                ISSUE:begin

                    if(req_sync[2])state<=DRAIN;

                    else begin

                        App_rd_en<=1;App_rd_addr<=source_base+source_offset;burst_issued<=burst_issued+1'b1;

                        if(issue_x==right_edge)begin

                            issue_x<=left_edge;issue_line<=issue_line+1'b1;

                            map_u<=map_u_start;map_u_rem<=map_u_start_rem;map_v<=next_v;map_v_rem<=next_v_rem;

                        end else begin issue_x<=issue_x+1'b1;map_u<=next_u;map_u_rem<=next_u_rem;end

                        if(last_issue)begin issue_complete<=1;state<=DRAIN;end

                        else if(burst_issued==255)state<=DRAIN;

                    end

                end

                DRAIN:if(!App_rd_en && burst_returned==burst_issued)begin

                    if(req_sync[2])state<=ACK;

                    else if(issue_complete)state<=FINISH_TILE;

                    else state<=WAIT_BUS;

                end

                FINISH_TILE:begin

                    if(req_sync[2])state<=ACK;

                    else begin

                        ready[fill_bank]<=1;fill_bank<=!fill_bank;fill_y<=fill_y+4;

                        if(!tile_black)begin map_v_head<=next_head;map_v_head_rem<=next_head_rem;end

                        state<=(fill_y==476)?DONE:TILE;

                    end

                end

                DONE:if(req_sync[2])state<=ACK;

                default:state<=IDLE;

            endcase

        end

    end

endmodule

