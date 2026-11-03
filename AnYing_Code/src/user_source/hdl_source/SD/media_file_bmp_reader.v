// One physical sector port shared by FAT32 discovery and FAT32 file streaming.
// FAT directory events are staged; only successful discovery publishes slot IDs.
// The existing BMP loader still owns header checks, write ACK and BGR assembly.
// In FAT mode its sequential addresses are virtual file sectors, never card LBAs.
// Physical requests are not abandoned on cancellation: ready waits for real end.
module media_file_bmp_reader #(
    parameter integer REQUEST_TIMEOUT_CYCLES=100_000_000,
    parameter integer TARGET_FILES=4,
    parameter integer STREAM_PAGES=0,
    parameter integer BMP_ADAPT_ENABLE=0,
    parameter integer AUDIO_ENABLE=0
)(
    input wire clk,rst,
    output wire ready,
    input wire scan_start,scan_pause_after_found,scan_resume,
    input wire scan_next,
    output reg page_done,
    output wire page_last,all_images_active,
    output wire [15:0] file_ordinal,
    output wire scan_paused,
    input wire [31:0] scan_start_sector,scan_max_sector,
    input wire [2:0] scan_target_count,
    output wire scan_done,scan_found_valid,
    output wire [31:0] scan_found_sector,
    output wire [2:0] scan_found_total,
    input wire load_start,load_abort,
    input wire [31:0] load_sector,
    output wire load_error,load_data_error,
    output wire [7:0] load_data_detail,
    output wire [2:0] bmp_error,
    input wire sd_init_done,
    output wire [3:0] state_code,
    input wire [15:0] bmp_width,bmp_height,
    output wire write_req,
    input wire write_req_ack,
    output wire sd_sec_read,
    output wire [31:0] sd_sec_read_addr,
    input wire [7:0] sd_sec_read_data,
    input wire sd_sec_read_data_valid,sd_sec_read_end,
    input wire sector_active,
    output wire bmp_data_wr_en,
    output wire [23:0] bmp_data,
    output reg music_found,
    input wire [4:0] music_index,
    output reg [5:0] music_count,
    output reg [27:0] music_cluster,
    output reg [31:0] music_size,
    output reg [32:0] music_volume_end,
    output reg [31:0] music_data_lba,music_fat_lba,music_cluster_count,
    output reg [7:0] music_spc,
    output reg storage_fault
);
localparam [2:0] IDLE=0,PROBE=1,PUBLISH=2;
reg [2:0] control;
reg music_scan,music_scanned;
// Up to 32 catalogue records; PCM remains streamed through the existing FIFO. Storage is uninitialized until music_count commits.
// No reset on the data array: the valid count owns all publication.
reg [59:0] songs[0:31];
reg [59:0] song_pending;

reg fat_mode,cat_start,cat_next_page,cat_scan_done,cat_found_valid;
localparam integer METADATA_SLOTS=STREAM_PAGES ? 1 : 4;
reg [15:0] file_ordinals[0:METADATA_SLOTS-1];
wire [15:0] cat_file_ordinal;
reg [2:0] publish_slot,cat_found_total;
reg [27:0] file_clusters[0:METADATA_SLOTS-1];reg [31:0] file_sizes[0:METADATA_SLOTS-1];
reg [1:0] selected_slot;
wire [27:0] selected_file_cluster;
wire [31:0] selected_file_size;
generate if(STREAM_PAGES)begin:g_single_metadata
 assign selected_file_cluster=selected_slot==0 ? file_clusters[0]:28'd0;
 assign selected_file_size=selected_slot==0 ? file_sizes[0]:32'd0;
end else begin:g_legacy_metadata
 assign selected_file_cluster=file_clusters[selected_slot];
 assign selected_file_size=file_sizes[selected_slot];
end endgenerate
reg physical_pending;
reg ready_q;
wire cat_busy,cat_done,cat_mounted,cat_file_valid,cat_sector_req,cat_sector_abort;
wire [7:0] cat_error,cat_spc;
wire [31:0] cat_sector_lba,cat_file_size,cat_data_lba,cat_fat_lba,cat_clusters;
wire [27:0] cat_file_cluster;
wire [32:0] cat_volume_end;
wire [1:0] cat_file_slot;
wire [2:0] cat_count;
wire raw_ready;
wire [2:0] raw_bmp_error;
wire [3:0] raw_state_code;
wire raw_load_error,raw_data_error,raw_read,raw_write_req,raw_pixel_valid;
wire raw_skip_data_sector;
wire [23:0] raw_pixel;
wire stream_busy,stream_done,stream_end,stream_sector_req,stream_sector_abort,stream_valid;
wire [31:0] stream_lba,stream_offset;
wire [7:0] stream_error,stream_byte;
reg stream_start,stream_prefix,stream_active,stream_complete;
reg [31:0] stream_limit,stream_received;
reg [9:0] virtual_count;
reg virtual_end,virtual_error;
reg [7:0] virtual_data;
reg virtual_valid,wait_request_low;
assign all_images_active=STREAM_PAGES && fat_mode;
assign file_ordinal=file_ordinals[0];
wire stream_ready=fat_mode && stream_active && raw_read && !wait_request_low && virtual_count<512;
wire stream_failed=stream_done && stream_error!=0;
wire invalid_slot=load_start && (!fat_mode || load_sector>3 || {1'b0,load_sector[1:0]}>=cat_count);
wire internal_abort=load_abort || virtual_error || stream_failed || invalid_slot;
// Read-only debug aliases expose parser state for simulation.
wire [2:0] state;
wire [9:0] rd_cnt;
wire [31:0] bmp_len_cnt,header_length;
// Cancellation also covers local virtual-sector padding, when the physical
// reader is already idle and cannot produce a later failed-done event.
// Register the cancellation before driving the local parser reset.
reg raw_cancel_q;
always @(posedge clk or posedge rst)begin
    if(rst)raw_cancel_q<=0;
    else raw_cancel_q<=fat_mode && (load_abort || stream_failed || invalid_slot || virtual_error);
end
wire raw_reset=rst || raw_cancel_q;
wire use_cat=(control==PROBE);
// Catalogue and file streaming have mutually exclusive transport ownership.
// Each ISSUE clears this watchdog before its first RECEIVE cycle. Old count
// outside the selected receiver is not consumed and does not affect timeout.
localparam integer SHARED_TIMER_BITS=(REQUEST_TIMEOUT_CYCLES>1)?$clog2(REQUEST_TIMEOUT_CYCLES):1;
reg [SHARED_TIMER_BITS-1:0] shared_timer;
wire cat_timer_clear,cat_timer_tick,file_timer_clear,file_timer_tick;
wire shared_timer_expired=(shared_timer>=REQUEST_TIMEOUT_CYCLES-1);
wire shared_timer_clear=use_cat ? cat_timer_clear : file_timer_clear;
wire shared_timer_tick=use_cat ? cat_timer_tick : file_timer_tick;
always @(posedge clk or posedge rst)begin
    if(rst)shared_timer<=0;
    else if(shared_timer_clear)shared_timer<=0;
    else if(shared_timer_tick)shared_timer<=shared_timer+1'b1;
end




assign sd_sec_read=use_cat ? cat_sector_req : stream_sector_req;
assign sd_sec_read_addr=use_cat ? cat_sector_lba : stream_lba;
// Register source completion before it enters the host's recovery/search paths.
// Starts suppress ready on that same edge; no inherited IDLE may end a load.
assign ready=ready_q;
always @(posedge clk or posedge rst)begin
    if(rst)ready_q<=0;
    else ready_q<=(control==IDLE) && raw_ready && !stream_busy &&
        !physical_pending && !scan_start && !(STREAM_PAGES && scan_next) && !load_start && !load_abort && !internal_abort;
end
assign scan_done=fat_mode && cat_scan_done;
assign scan_paused=1'b0;
assign scan_found_valid=fat_mode && cat_found_valid;
assign scan_found_sector={29'd0,publish_slot};
assign scan_found_total=cat_found_total;
assign state_code=(control==PROBE || control==PUBLISH) ? 4'd2 : raw_state_code;
assign load_error=raw_load_error;
assign load_data_error=raw_data_error || virtual_error || stream_failed || invalid_slot;
// Read-only diagnostic context, sampled by the host on its actual failure.
// High nibble: 1=raw sector/pixel ending, 2=BMP/directory length mismatch,
// 3=FAT file reader, 4=invalid slot. Low nibble preserves FAT reader cause
// (1=config, 2=bounds, 3=chain, 4=I/O, 5=timeout, 6=sector, 7=abort).
// This does not alter error detection, cancellation or recovery scheduling.
assign load_data_detail=raw_data_error ? 8'h10 :
                        virtual_error ? 8'h20 :
                        stream_failed ? {4'h3,stream_error[3:0]} :
                        invalid_slot ? 8'h40 : 8'h00;
assign bmp_error=raw_bmp_error;
assign write_req=raw_write_req;
assign bmp_data_wr_en=raw_pixel_valid && !internal_abort;
assign bmp_data=raw_pixel;
fat32_catalogue #(.EXTERNAL_WATCHDOG(1),.REQUEST_TIMEOUT_CYCLES(REQUEST_TIMEOUT_CYCLES),.TARGET_FILES(STREAM_PAGES ? 1 : TARGET_FILES),.STREAM_PAGES(STREAM_PAGES),.AUDIO_SCAN_ENABLE(AUDIO_ENABLE)) u_catalogue(
    .watchdog_expired(shared_timer_expired),.watchdog_clear(cat_timer_clear),.watchdog_tick(cat_timer_tick),
    .clk(clk),.rst(rst),.start(cat_start),.next_page(cat_next_page),.audio_scan(music_scan),
    .page_last(page_last),.file_ordinal(cat_file_ordinal),.abort(load_abort),.storage_ready(sd_init_done),.storage_error(1'b0),
    .sector_req(cat_sector_req),.sector_lba(cat_sector_lba),.sector_byte(sd_sec_read_data),
    .sector_valid(use_cat && sd_sec_read_data_valid),.sector_end(use_cat && sd_sec_read_end),
    .sector_abort(cat_sector_abort),.busy(cat_busy),.done(cat_done),.mounted(cat_mounted),.error(cat_error),
    .file_valid(cat_file_valid),.file_slot(cat_file_slot),.file_short_name(),
    .file_first_cluster(cat_file_cluster),.file_size(cat_file_size),.found_count(cat_count),
    .validated_volume_end(cat_volume_end),.volume_lba(),.data_lba(cat_data_lba),.active_fat_lba(cat_fat_lba),
    .cluster_count(cat_clusters),.sectors_per_cluster(cat_spc)
);
fat32_file_reader #(.SKIP_DATA_SECTORS(BMP_ADAPT_ENABLE),.MAX_FILE_BYTES(BMP_ADAPT_ENABLE ? 4_194_304 : 2_097_152),.MAX_FILE_CLUSTERS(BMP_ADAPT_ENABLE ? 8192 : 4096),.EXTERNAL_WATCHDOG(1),.VALIDATED_GEOMETRY(1),.REQUEST_TIMEOUT_CYCLES(REQUEST_TIMEOUT_CYCLES)) u_file(
    .watchdog_expired(shared_timer_expired),.watchdog_clear(file_timer_clear),.watchdog_tick(file_timer_tick),
    .clk(clk),.rst(rst),.start(stream_start),.abort(load_abort),.storage_ready(sd_init_done),.storage_error(1'b0),
    .validated_data_end(cat_volume_end),.prefix_only(stream_prefix),.skip_data_sector(raw_skip_data_sector),
    .first_cluster(selected_file_cluster),.size_bytes(selected_file_size),
    .data_lba(cat_data_lba),.active_fat_lba(cat_fat_lba),.cluster_count(cat_clusters),.sectors_per_cluster(cat_spc),
    .sector_req(stream_sector_req),.sector_lba(stream_lba),.sector_byte(sd_sec_read_data),
    .sector_valid(fat_mode && !use_cat && sd_sec_read_data_valid),.sector_end(fat_mode && !use_cat && sd_sec_read_end),
    .sector_abort(stream_sector_abort),.busy(stream_busy),.done(stream_done),.error(stream_error),
    .file_valid(stream_valid),.file_ready(stream_ready),.file_byte(stream_byte),
    .file_byte_offset(stream_offset),.file_end(stream_end)
);
// The shared BMP loader receives only virtual sectors from validated FAT files.
// Historical instance name u_raw is retained for existing CDC/path references;
// RAW discovery and its separate skip/locator arithmetic have been removed.
bmp_read #(.ADAPT_ENABLE(BMP_ADAPT_ENABLE)) u_raw(
    .clk(clk),.rst(raw_reset),.ready(raw_ready),.loader_phase(state),.sector_byte_count(rd_cnt),
    .source_byte_count(bmp_len_cnt),.header_length(header_length),.scan_start(1'b0),
    .scan_pause_after_found(1'b0),.scan_resume(1'b0),
    .scan_paused(),.scan_start_sector(32'd0),.scan_max_sector(32'd0),
    .scan_target_count(3'd0),.scan_done(),.scan_found_valid(),
    .scan_found_sector(),.scan_found_total(),
    .load_start(load_start && !invalid_slot),.load_abort(internal_abort),.load_sector(32'd0),
    .load_error(raw_load_error),.load_data_error(raw_data_error),.bmp_error(raw_bmp_error),
    .sd_init_done(sd_init_done),.state_code(raw_state_code),.bmp_width(bmp_width),.bmp_height(bmp_height),
    .write_req(raw_write_req),.write_req_ack(write_req_ack),.sd_sec_read(raw_read),.sd_sec_read_addr(),
    .sd_sec_read_data(virtual_data),
    .sd_sec_read_data_valid(virtual_valid),
    .sd_sec_read_end(virtual_end),
    .bmp_data_wr_en(raw_pixel_valid),.bmp_data(raw_pixel),.skip_data_sector(raw_skip_data_sector)
);
always @(posedge clk)begin
 if(cat_file_valid&&music_scan)song_pending<={cat_file_cluster,cat_file_size};
 if(cat_done&&music_scan&&cat_error==0&&cat_mounted&&cat_count!=0&&music_count<6'd32)
  songs[music_count[4:0]]<=song_pending;
 if(music_found&&{1'b0,music_index}<music_count){music_cluster,music_size}<=songs[music_index];
 else begin music_cluster<=0;music_size<=0;end
end
integer i;
always @(posedge clk or posedge rst)begin
    if(rst)begin
        control<=IDLE;music_scan<=0;music_scanned<=0;music_found<=0;music_count<=0;music_volume_end<=0;music_data_lba<=0;music_fat_lba<=0;music_cluster_count<=0;music_spc<=0;fat_mode<=0;cat_start<=0;cat_next_page<=0;page_done<=0;cat_scan_done<=0;
        cat_found_valid<=0;cat_found_total<=0;publish_slot<=0;selected_slot<=0;
        physical_pending<=0;storage_fault<=0;
        for(i=0;i<METADATA_SLOTS;i=i+1)begin file_clusters[i]<=0;file_sizes[i]<=0;file_ordinals[i]<=0;end
    end else begin
        cat_start<=0;cat_found_valid<=0;storage_fault<=0;page_done<=0;
        if(sd_sec_read_end)physical_pending<=0;
        // Track an accepted sector, not a request still queued behind audio.
        else if(sector_active)physical_pending<=1;
        if(cat_file_valid&&!music_scan)begin file_clusters[STREAM_PAGES ? 2'd0 : cat_file_slot]<=cat_file_cluster;
            file_sizes[STREAM_PAGES ? 2'd0 : cat_file_slot]<=cat_file_size;file_ordinals[STREAM_PAGES ? 2'd0 : cat_file_slot]<=cat_file_ordinal;end
        if(load_start && fat_mode)selected_slot<=load_sector[1:0];
        // Only the TF supervisor may reset a stuck physical source.
        // File failures use the existing per-resource recovery. If a physical
        // read never ends, ready remains low and that recovery stops safely;
        // K2/K4 then use the existing TF-local manual reset. Do not automatically
        // rescan here: successful rediscovery would replenish a bad-file budget.
        if(scan_start && ready)begin
            cat_scan_done<=0;cat_found_total<=0;publish_slot<=0;fat_mode<=0;cat_next_page<=0;
            if(scan_start_sector==0)begin
                cat_start<=1;control<=PROBE;music_scan<=AUDIO_ENABLE&&!music_scanned;
            end
            // A nonzero RAW scan offset is no longer a supported storage mode.
            else begin storage_fault<=1;control<=IDLE;end
        end else if(STREAM_PAGES && scan_next && ready && fat_mode)begin
            // Physical storage is idle here; resume the root cursor, not the volume probe.
            cat_found_total<=0;publish_slot<=0;cat_next_page<=1;cat_start<=1;control<=PROBE;
        end else case(control)
            PROBE:if(cat_done)begin
                if(music_scan)begin
                    if(cat_error==0&&cat_mounted)begin
                        if(cat_count!=0&&music_count<6'd32)music_count<=music_count+6'd1;
                        if(STREAM_PAGES&&cat_count!=0&&!page_last&&music_count<6'd31)begin
                            cat_next_page<=1;cat_start<=1;
                        end else begin
                            music_scanned<=1;music_scan<=0;
                            music_found<=(music_count!=0||cat_count!=0);
                            music_volume_end<=cat_volume_end;music_data_lba<=cat_data_lba;music_fat_lba<=cat_fat_lba;music_cluster_count<=cat_clusters;music_spc<=cat_spc;
                            cat_next_page<=0;cat_start<=1;
                        end
                    end else begin
                        // A failed directory transaction cannot publish a partial catalogue.
                        music_count<=0;music_found<=0;music_scanned<=1;music_scan<=0;
                        cat_next_page<=0;cat_start<=1;
                    end
                end else if(cat_error==0 && cat_mounted)begin fat_mode<=1;publish_slot<=0;control<=PUBLISH;end
                // Unsupported FAT32, malformed media and transport failures terminate
                // explicitly. physical_pending still prevents reuse before real END.
                else begin storage_fault<=1;control<=IDLE;end
            end
            PUBLISH:begin
                // Emit one slot, then one quiet clock for the host to accept it.
                if(cat_found_valid)begin
                    if(publish_slot+1>=cat_count)begin cat_scan_done<=1;page_done<=1;control<=IDLE;end
                    else publish_slot<=publish_slot+1'b1;
                end else if(cat_count!=0)begin cat_found_valid<=1;cat_found_total<=cat_found_total+1'b1;end
                else begin cat_scan_done<=1;page_done<=1;control<=IDLE;end
            end
            default:;
        endcase
    end
end
// File stream -> virtual 512-byte sectors for the unchanged two-pass BMP loader.
// Tail bytes outside directory size are local padding and never read from card.
// A final sector-end is withheld until file-reader done with a clean FAT EOC.
always @(posedge clk or posedge rst)begin
    if(rst)begin
        stream_start<=0;stream_prefix<=0;stream_active<=0;stream_complete<=0;
        stream_limit<=0;stream_received<=0;virtual_count<=0;virtual_end<=0;
        virtual_error<=0;virtual_data<=0;virtual_valid<=0;wait_request_low<=0;
    end else begin
        stream_start<=0;virtual_end<=0;virtual_valid<=0;virtual_error<=0;
        if(load_abort || stream_failed || invalid_slot || virtual_error)begin
            stream_active<=0;stream_complete<=0;virtual_count<=0;wait_request_low<=0;
        end else if(fat_mode && !use_cat)begin
            if(!stream_active && raw_read && !stream_busy && !physical_pending &&
                (state==3'd2 || state==3'd4))begin
                stream_start<=1;stream_prefix<=(state==3'd2);stream_active<=1;stream_complete<=0;
                stream_limit<=(state==3'd2 && selected_file_size>512)?512:selected_file_size;
                stream_received<=0;virtual_count<=0;wait_request_low<=0;
            end else if(stream_active)begin
                if(stream_done && stream_end)stream_complete<=1;
                if(wait_request_low)begin
                    if(!raw_read)begin virtual_count<=0;wait_request_low<=0;end
                end else if(raw_read)begin
                    if(stream_valid && stream_ready)begin
                        virtual_data<=stream_byte;virtual_valid<=1;
                        stream_received<=stream_received+1'b1;virtual_count<=virtual_count+1'b1;
                    end else if(stream_complete && virtual_count<512 && stream_received==stream_limit)begin
                        virtual_data<=0;virtual_valid<=1;virtual_count<=virtual_count+1'b1;
                    end else if(virtual_count==512 && (stream_received<stream_limit || stream_complete))begin
                        // Header declares bytes within this directory entry, never past EOF.
                        if(state==3'd2 && (header_length!=selected_file_size || header_length<54))
                            virtual_error<=1;
                        else virtual_end<=1;
                        wait_request_low<=1;
                    end
                end
                if(stream_complete && !raw_read && (state!=3'd2 && state!=3'd4 && state!=3'd6 && state!=3'd7))
                    stream_active<=0;
            end
        end
    end
end
endmodule
