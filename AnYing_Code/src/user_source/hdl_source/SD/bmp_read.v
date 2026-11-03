// FAT-file BMP loader with header validation and pixel loading.
// Scan ports remain inert to preserve the storage-wrapper interface.
module bmp_read #(parameter integer ADAPT_ENABLE=0)(
    input                       clk,
    input                       rst,
    output                      ready,

    // Legacy scan interface: inactive; media_file_bmp_reader owns FAT discovery.
    input                       scan_start,
    input                       scan_pause_after_found,
    input                       scan_resume,
    output reg                  scan_paused,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input                       load_abort,
    input  [31:0]               load_sector,
    output reg                  load_error,      // One clock, only for a rejected load header.
    output reg                  load_data_error, // One clock: malformed sector/pixel ending.
    output reg [2:0]            bmp_error,       // Held until the next load/reset.

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output wire                 bmp_data_wr_en,
    output wire                 skip_data_sector,
    output wire [23:0]          bmp_data,
    output wire [2:0]           loader_phase,
    output wire [9:0]           sector_byte_count,
    output wire [31:0]          source_byte_count,header_length
);

// Header diagnostics occupy 1..7; upper-level timeout codes remain 8/9/A.
localparam ERR_NONE       = 3'd0;
localparam ERR_SIGNATURE  = 3'd1;
localparam ERR_DIB        = 3'd2;
localparam ERR_DIMENSIONS = 3'd3;
localparam ERR_FORMAT     = 3'd4;
localparam ERR_OFFSET     = 3'd5;
localparam ERR_LENGTH     = 3'd6;
localparam ERR_SHORT_HDR  = 3'd7;

localparam ST_IDLE      = 3'd0;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;
localparam ST_ABORT_WAIT = 3'd5;
localparam ST_DATA_CHECK = 3'd6;
localparam ST_DATA_RESULT = 3'd7;

reg [2:0]  state;
reg [9:0]  rd_cnt;
// Exact registered predicates follow the same counter events, not a relaxed
// minimum-length test. Both clear on END/inactive and reject byte513 as before.
reg rd_at_511_q, rd_at_512_q;
// Sample ACK without SD-domain combinational gating before the first FF.
// The same-edge acceptance bit forms the first acceptance stage.
reg        write_ack_raw;
reg        write_ack_accept;
wire       write_ack_meta = write_ack_accept ? write_ack_raw : 1'b0;
reg        write_ack_sync;

wire [7:0]  header_0;
wire [7:0]  header_1;
wire [31:0] file_len;
wire [31:0] pixel_offset;
wire [31:0] dib_size;
wire [15:0] planes;
wire [31:0] width;
wire [31:0] height;
wire [15:0] bit_count;
wire [31:0] compression;

reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
wire [1:0] bmp_byte_idx;
// Capture sector length, then check settled file/pixel counters on a separate
// clock. No wide comparison drives the source FSM/address on sector-end.
reg sector_complete_q, file_complete_q, payload_aligned_q;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        sector_complete_q <= 1'b0;
        file_complete_q <= 1'b0;
        payload_aligned_q <= 1'b0;
    end else begin
        if ((state == ST_LOAD_DATA) && sd_sec_read_end)
            sector_complete_q <= sd_sec_read_data_valid ? (rd_cnt == 10'd511) : (rd_cnt == 10'd512);
        if (state == ST_DATA_CHECK) begin
            file_complete_q <= (bmp_len_cnt >= file_len);
            payload_aligned_q <= (bmp_byte_idx == 2'd0);
        end
    end
end

wire header_match;

assign ready = (state == ST_IDLE);
assign loader_phase=state;
assign sector_byte_count=rd_cnt;
assign source_byte_count=bmp_len_cnt;
assign header_length=file_len;
// Keep byte offsets and source scheduling in this storage wrapper.
wire [2:0] header_error;
wire decoder_header_active = (state == ST_LOAD_HDR);
bmp24_decoder #(.ADAPT_ENABLE(ADAPT_ENABLE)) u_bmp_decoder (
    .clk(clk), .rst(rst),
    .header_active(decoder_header_active), .header_valid(sd_sec_read_data_valid),
    .header_byte(sd_sec_read_data), .header_offset({22'd0,rd_cnt}),
    .header_end(sd_sec_read_end), .abort(load_abort),
    .expected_width(bmp_width), .expected_height(bmp_height),
    .pixel_enable(state == ST_LOAD_DATA),
    .pixel_context((state == ST_LOAD_DATA) || (state == ST_DATA_CHECK) || (state == ST_DATA_RESULT)),
    .pixel_byte_valid_in(sd_sec_read_data_valid), .pixel_byte(sd_sec_read_data),
    .pixel_offset_in(bmp_len_cnt),
    .header_0(header_0), .header_1(header_1), .file_len(file_len),
    .pixel_offset(pixel_offset), .dib_size(dib_size), .width(width), .height(height),
    .planes(planes), .bit_count(bit_count), .compression(compression),
    .header_error(header_error), .header_match(header_match),
    .pixel_phase(bmp_byte_idx), .pixel_valid(bmp_data_wr_en), .pixel_rgb(bmp_data),
    .skip_data_sector(skip_data_sector)
);
// The memory-domain ACK stays high until write_req is withdrawn.
// The mask follows procedural-if clear priority, including X/Z
// simulation semantics. Do not replace ?: with &: an accepted Z stays Z.
// Only the second receiving-domain stage may drive the load state machine.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        write_ack_raw <= 1'b0;
        write_ack_accept <= 1'b0;
        write_ack_sync <= 1'b0;
    end else begin
        write_ack_raw <= write_req_ack;
        if (!sd_init_done || load_abort) begin
            write_ack_accept <= 1'b0;
            write_ack_sync <= 1'b0;
        end else begin
            write_ack_accept <= 1'b1;
            write_ack_sync <= write_ack_meta;
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
        rd_at_511_q <= 1'b0;
        rd_at_512_q <= 1'b0;
    end else if ((state == ST_LOAD_HDR) || (state == ST_LOAD_DATA)) begin
        if (sd_sec_read_end) begin
            rd_cnt <= 10'd0;
            rd_at_511_q <= 1'b0;
            rd_at_512_q <= 1'b0;
        end else if (sd_sec_read_data_valid) begin
            rd_cnt <= rd_cnt + 10'd1;
            rd_at_511_q <= (rd_cnt == 10'd510);
            rd_at_512_q <= (rd_cnt == 10'd511);
        end
    end else begin
        rd_cnt <= 10'd0;
        rd_at_511_q <= 1'b0;
        rd_at_512_q <= 1'b0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else if ((state != ST_DATA_CHECK) && (state != ST_DATA_RESULT)) begin
        bmp_len_cnt <= 32'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_paused       <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        load_sector_latched <= 32'd0;
        load_error        <= 1'b0;
        load_data_error   <= 1'b0;
        bmp_error         <= ERR_NONE;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_paused       <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        load_sector_latched <= 32'd0;
        load_error        <= 1'b0;
        load_data_error   <= 1'b0;
        bmp_error         <= ERR_NONE;
    end else if (load_abort) begin
        load_error        <= 1'b0;
        load_data_error   <= 1'b0;
        // Keep the image catalog; drain an already requested SD sector before retry.
        state             <= (sd_sec_read && !sd_sec_read_end) ? ST_ABORT_WAIT : ST_IDLE;
        state_code        <= (sd_sec_read && !sd_sec_read_end) ? 4'd5 : 4'd1;
        sd_sec_read       <= 1'b0;
        write_req         <= 1'b0;
        scan_found_valid  <= 1'b0;
    end else begin
        scan_found_valid <= 1'b0;
        load_error       <= 1'b0;
        load_data_error  <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (load_start) begin
                    bmp_error           <= ERR_NONE;
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        bmp_error  <= header_error;
                        load_error <= 1'b1;
                        state      <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_ack_sync) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    state <= ST_DATA_CHECK;
                end
            end

            ST_DATA_CHECK: begin
                state_code <= 4'd4;
                sd_sec_read <= 1'b0;
                state <= ST_DATA_RESULT;
            end

            ST_DATA_RESULT: begin
                state_code <= 4'd4;
                sd_sec_read <= 1'b0;
                if (!sector_complete_q || (file_complete_q && !payload_aligned_q)) begin
                    load_data_error <= 1'b1;
                    state <= ST_IDLE;
                end else if (file_complete_q) begin
                    state <= ST_IDLE;
                end else begin
                    sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    state <= ST_LOAD_DATA;
                end
            end

            ST_ABORT_WAIT: begin
                state_code  <= 4'd5;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
                if (sd_sec_read_end)
                    state <= ST_IDLE;
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
