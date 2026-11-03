// Storage-independent BMP24 byte decoder. No sector requests, SDRAM handshake,
// directory lookup or frame ownership. The caller supplies file-relative offsets.
// Header and payload contexts are separate so the existing two-pass loader keeps
// its exact scheduling; payload includes file bytes before pixel_offset.
// Valid gaps preserve partial BGR pixels. The consumer accepts every pixel_valid.
module bmp24_decoder #(parameter integer ADAPT_ENABLE=0)(
    input wire clk, rst,
    input wire header_active, header_valid,
    input wire [7:0] header_byte,
    input wire [31:0] header_offset,
    input wire header_end, abort,
    input wire [15:0] expected_width, expected_height,
    input wire pixel_enable, pixel_context, pixel_byte_valid_in,
    input wire [7:0] pixel_byte,
    input wire [31:0] pixel_offset_in,
    output reg [7:0] header_0, header_1,
    output reg [31:0] file_len, pixel_offset, dib_size, width, height, compression,
    output reg [15:0] planes, bit_count,
    output reg [2:0] header_error,
    output wire header_match,
    output reg [1:0] pixel_phase,
    output reg pixel_valid,
    output reg [23:0] pixel_rgb,
    output wire skip_data_sector
);
localparam ERR_NONE=3'd0, ERR_SIGNATURE=3'd1, ERR_DIB=3'd2,
           ERR_DIMENSIONS=3'd3, ERR_FORMAT=3'd4, ERR_OFFSET=3'd5,
           ERR_LENGTH=3'd6, ERR_SHORT_HDR=3'd7;
// This decoder keeps the existing positive-height, uncompressed RGB888 path.
// Exact integer4:3 dimensions have width divisible by4, so RGB24 rows
// are already4-byte aligned. Invalid aspect/size is rejected before loading.
// Widen BEFORE addition/multiplication so malformed 32-bit fields cannot wrap.
// Hold header completeness once byte 53 has been accepted. Also recognize
// that byte when valid and sector-end coincide, without an adder on valid.
reg header_complete_q;
wire header_complete = header_complete_q ||
                       (header_valid && (header_offset == 32'd53));
always @(posedge clk or posedge rst) begin
    if (rst)
        header_complete_q <= 1'b0;
    else if (!header_active || header_end || abort)
        header_complete_q <= 1'b0;
    else if (header_valid && (header_offset == 32'd53))
        header_complete_q <= 1'b1;
end
wire [32:0] dib_end = {1'b0, dib_size} + 33'd14;
// Bound source dimensions before accepting the header; the23-bit product
// covers every supported input. Invalid high bits are rejected separately.
// Parsed dimensions are complete at byte25. Split multiply, x3 and offset
// into distinct accepted header bytes; existing byte34/35 checks are unchanged.
reg [20:0] source_pixels_q;
reg [22:0] source_pixel_bytes;
always @(posedge clk or posedge rst)begin
 if(rst)begin source_pixels_q<=0;source_pixel_bytes<=0;end
 else if(header_active&&header_valid)begin
  if(header_offset==32'd26)source_pixels_q<=width[10:0]*height[9:0];
  if(header_offset==32'd27)source_pixel_bytes<={2'd0,source_pixels_q}+{1'd0,source_pixels_q,1'b0};
 end
end
wire [33:0] expected_pixel_bytes = ADAPT_ENABLE ? {11'd0,source_pixel_bytes} :
    ({18'd0, expected_width} * {18'd0, expected_height} * 34'd3);
wire source_dimensions_ok = width>=640 && width<=1280 && height>=480 && height<=960 &&
    (({2'd0,width[10:0]}+{1'd0,width[10:0],1'b0})=={1'b0,height[9:0],2'b00}) &&
    expected_width==640 && expected_height==480;
wire [34:0] required_file_bytes = {3'd0, pixel_offset} + {1'b0, expected_pixel_bytes};
// All parsed fields have arrived at byte 33. Arithmetic at byte 34 and
// comparisons at byte 35 finish well before the 54-byte minimum header.
// Using the byte stream as enables avoids a wide check feeding the scan FSM.
reg [32:0] dib_end_q;
reg [34:0] required_file_bytes_q;
reg [5:0] header_checks_q;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        dib_end_q <= 33'd0;
        required_file_bytes_q <= 35'd0;
        header_checks_q <= 6'd0;
    end else if (header_active && header_valid) begin
        if (header_offset == 32'd34) begin
            dib_end_q <= dib_end;
            required_file_bytes_q <= required_file_bytes;
        end else if (header_offset == 32'd35) begin
            header_checks_q[0] <= (header_0 != "B") || (header_1 != "M");
            header_checks_q[1] <= (dib_size < 32'd40);
            header_checks_q[2] <= ADAPT_ENABLE ? !source_dimensions_ok :
                ((expected_width == 16'd0) || (expected_height == 16'd0) ||
                 (width != {16'd0, expected_width}) || (height != {16'd0, expected_height}));
            header_checks_q[3] <= (planes != 16'd1) || (bit_count != 16'd24) ||
                                  (compression != 32'd0) || (expected_width[1:0] != 2'd0);
            header_checks_q[4] <= (pixel_offset < 32'd54) ||
                                  ({1'b0, pixel_offset} < dib_end_q) || (pixel_offset >= file_len);
            header_checks_q[5] <= (required_file_bytes_q > {3'd0, file_len});
        end
    end
end
always @* begin
    header_error = ERR_NONE;
    if (!header_complete)
        header_error = ERR_SHORT_HDR;
    else if (header_checks_q[0])
        header_error = ERR_SIGNATURE;
    else if (header_checks_q[1])
        header_error = ERR_DIB;
    else if (header_checks_q[2])
        header_error = ERR_DIMENSIONS;
    else if (header_checks_q[3])
        header_error = ERR_FORMAT;
    else if (header_checks_q[4])
        header_error = ERR_OFFSET;
    else if (header_checks_q[5])
        header_error = ERR_LENGTH;
end
assign header_match = (header_error == ERR_NONE);
always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        dib_size     <= 32'd0;
        planes       <= 16'd0;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
    end else if (header_active && header_valid) begin
        case (header_offset)
            32'd0 : begin
                header_0     <= header_byte;
                header_1     <= 8'd0;
                file_len     <= 32'd0;
                pixel_offset <= 32'd0;
                dib_size     <= 32'd0;
                planes       <= 16'd0;
                width        <= 32'd0;
                height       <= 32'd0;
                bit_count    <= 16'd0;
                compression  <= 32'd0;
            end
            32'd1 : header_1 <= header_byte;

            32'd2 : file_len[7:0] <= header_byte;
            32'd3 : file_len[15:8] <= header_byte;
            32'd4 : file_len[23:16] <= header_byte;
            32'd5 : file_len[31:24] <= header_byte;

            32'd10: pixel_offset[7:0] <= header_byte;
            32'd11: pixel_offset[15:8] <= header_byte;
            32'd12: pixel_offset[23:16] <= header_byte;
            32'd13: pixel_offset[31:24] <= header_byte;

            32'd14: dib_size[7:0] <= header_byte;
            32'd15: dib_size[15:8] <= header_byte;
            32'd16: dib_size[23:16] <= header_byte;
            32'd17: dib_size[31:24] <= header_byte;

            32'd18: width[7:0] <= header_byte;
            32'd19: width[15:8] <= header_byte;
            32'd20: width[23:16] <= header_byte;
            32'd21: width[31:24] <= header_byte;

            32'd22: height[7:0] <= header_byte;
            32'd23: height[15:8] <= header_byte;
            32'd24: height[23:16] <= header_byte;
            32'd25: height[31:24] <= header_byte;

            32'd26: planes[7:0] <= header_byte;
            32'd27: planes[15:8] <= header_byte;

            32'd28: bit_count[7:0] <= header_byte;
            32'd29: bit_count[15:8] <= header_byte;

            32'd30: compression[7:0] <= header_byte;
            32'd31: compression[15:8] <= header_byte;
            32'd32: compression[23:16] <= header_byte;
            32'd33: compression[31:24] <= header_byte;
            default: ;
        endcase
    end
end

// Parallel half-word comparisons retain every unsigned 32-bit input value.
wire pixel_end_hi_less = pixel_offset_in[31:16] < file_len[31:16];
wire pixel_end_hi_equal = pixel_offset_in[31:16] == file_len[31:16];
wire pixel_end_lo_less = pixel_offset_in[15:0] < file_len[15:0];
wire pixel_before_end = pixel_end_hi_less || (pixel_end_hi_equal && pixel_end_lo_less);
wire pixel_in_payload = (pixel_offset_in >= pixel_offset) && pixel_before_end;
wire pixel_byte_valid = pixel_byte_valid_in && pixel_in_payload;
// Streaming nearest-neighbor selection in the existing BMP file-row order.
// Only the640x480 selected RGB samples enter the frame FIFO. No source frame.
// next_x=floor(output_x*width/640), represented by integer+remainder steps.
wire select_pixel;
generate if(ADAPT_ENABLE)begin : g_adapt
    reg [10:0] source_x,next_x;
    reg [9:0] source_y,next_y;
    reg [9:0] rem_x;
    reg [8:0] rem_y;
    wire [11:0] sum_x={2'd0,rem_x}+{1'b0,width[10:0]};
    wire [10:0] sum_y={2'd0,rem_y}+{1'b0,height[9:0]};
    assign select_pixel=(source_y<height[9:0])&&(source_x==next_x)&&(source_y==next_y);
    // The file reader samples this only before a whole aligned data sector.
    // Even phase 2 has at least 514 bytes left when 172 source pixels remain.
    // Such a sector lies wholly inside a row omitted by nearest-neighbor sampling.
    assign skip_data_sector=pixel_context && pixel_in_payload &&
        (source_y<height[9:0]) && (source_y<next_y) &&
        ({1'b0,source_x}+12'd172 <= {1'b0,width[10:0]});
    always @(posedge clk or posedge rst)begin
        if(rst)begin source_x<=0;source_y<=0;next_x<=0;next_y<=0;rem_x<=0;rem_y<=0;end
        else if(abort||!pixel_context)begin source_x<=0;source_y<=0;next_x<=0;next_y<=0;rem_x<=0;rem_y<=0;end
        else if(pixel_enable&&pixel_byte_valid&&pixel_phase==2&&source_y<height[9:0])begin
            if(source_x==width[10:0]-1'b1)begin
                source_x<=0;source_y<=source_y+1'b1;next_x<=0;rem_x<=0;
                if(source_y==next_y)begin
                    next_y<=next_y+((sum_y>=960)?10'd2:10'd1);
                    rem_y<=(sum_y>=960)?sum_y-960:sum_y-480;
                end
            end else begin
                source_x<=source_x+1'b1;
                if(source_x==next_x)begin
                    next_x<=next_x+((sum_x>=1280)?11'd2:11'd1);
                    rem_x<=(sum_x>=1280)?sum_x-1280:sum_x-640;
                end
            end
        end
    end
end else begin : g_exact
    assign select_pixel=1'b1;
    assign skip_data_sector=1'b0;
end endgenerate

always @(posedge clk or posedge rst) begin
    if (rst) begin
        pixel_phase <= 2'd0;
    end else if (pixel_enable) begin
        if (pixel_byte_valid)
            pixel_phase <= (pixel_phase == 2'd2) ? 2'd0 : (pixel_phase + 2'd1);
    end else if (!pixel_context) begin
        pixel_phase <= 2'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        pixel_valid <= 1'b0;
        pixel_rgb       <= 24'd0;
    end else if (abort) begin
        pixel_valid <= 1'b0;
    end else if (pixel_enable) begin
        if (pixel_byte_valid) begin
            case (pixel_phase)
                2'd0: begin
                    pixel_valid <= 1'b0;
                    pixel_rgb[7:0]  <= pixel_byte;
                end
                2'd1: begin
                    pixel_valid <= 1'b0;
                    pixel_rgb[15:8] <= pixel_byte;
                end
                2'd2: begin
                    pixel_valid  <= select_pixel;
                    pixel_rgb[23:16] <= pixel_byte;
                end
                default: begin
                    pixel_valid <= 1'b0;
                end
            endcase
        end else begin
            pixel_valid <= 1'b0;
        end
    end else begin
        pixel_valid <= 1'b0;
    end
end

endmodule
