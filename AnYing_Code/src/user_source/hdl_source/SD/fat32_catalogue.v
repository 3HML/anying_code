// Independent read-only FAT32 root catalogue.
// No SD commands, writes, BMP pixels, frame ownership, or clock changes.
// A request holds its LBA until exactly 512 valid bytes and sector_end.
// Candidate pulses are provisional: publish the catalogue only at done && !error.
// After sector_abort, the caller must reset/drain the old transport before start.
module fat32_catalogue #(
    parameter integer EXTERNAL_WATCHDOG=0,
    parameter integer REQUEST_TIMEOUT_CYCLES = 100_000_000,
    parameter integer MAX_DIR_SECTORS = 4096,
    parameter integer TARGET_FILES = 4,
    parameter integer STREAM_PAGES = 0,
    parameter integer AUDIO_SCAN_ENABLE = 0,
    parameter [31:0] MAX_LBA = 32'hffffffff
) (
    input wire watchdog_expired,
    output wire watchdog_clear, watchdog_tick,
    input wire clk, rst, start, abort,
    input wire next_page,
    input wire audio_scan,
    output reg page_last,
    output reg [15:0] file_ordinal,
    input wire storage_ready, storage_error,
    output reg sector_req,
    output reg [31:0] sector_lba,
    input wire [7:0] sector_byte,
    input wire sector_valid, sector_end,
    output reg sector_abort,
    output reg busy, done, mounted,
    output reg [7:0] error,
    output reg file_valid,
    output reg [1:0] file_slot,
    output reg [87:0] file_short_name,
    output reg [27:0] file_first_cluster,
    output reg [31:0] file_size,
    output reg [2:0] found_count,
    output reg [31:0] volume_lba, data_lba, active_fat_lba,
    output wire [32:0] validated_volume_end,
    output reg [31:0] cluster_count,
    output reg [7:0] sectors_per_cluster
);
localparam [7:0] ERR_NONE=0, ERR_NOT_FAT32=1, ERR_BPB=2, ERR_BOUNDS=3,
    ERR_IO=4, ERR_TIMEOUT=5, ERR_SECTOR=6, ERR_CHAIN=7,
    ERR_DIR_LIMIT=8, ERR_ABORT=9, ERR_CONFIG=10;
localparam [23:0] IDLE=24'h000001,
    ISSUE=24'h000002,
    RECEIVE=24'h000004,
    FETCH=24'h000008,
    PARSE=24'h000010,
    MBR_ENTRY=24'h000020,
    EVALUATE=24'h000040,
    GEOMETRY0=24'h000080,
    GEOMETRY1=24'h000100,
    GEOMETRY2=24'h000200,
    ROOT_REQUEST=24'h000400,
    DIR_ENTRY=24'h000800,
    ROOT_NEXT=24'h001000,
    FAT_REQUEST=24'h002000,
    FAT_EVALUATE=24'h004000,
    FINISH=24'h008000,
    ROOT_SHIFT=24'h010000,
    ROOT_SUM=24'h020000,
    ROOT_ADD=24'h040000,
    ROOT_CHECK=24'h080000,
    ROOT_ISSUE=24'h100000,
    GEOMETRY_COMMIT=24'h200000,
    FAT_SUM=24'h400000,
    FAT_CHECK=24'h800000;
localparam [1:0] FIRST=0, BOOT=1, DIRECTORY=2, FAT=3;
localparam integer TIMER_BITS=(REQUEST_TIMEOUT_CYCLES>1) ? $clog2(REQUEST_TIMEOUT_CYCLES) : 1;
// Explicit one-hot state bits avoid binary decode in shared register enables.
reg [23:0] state;
reg [23:0] cursor_state;
reg [8:0] cursor_offset, resume_offset;
reg [15:0] ordinal_count;
reg [1:0] kind;
reg [9:0] received;
reg [TIMER_BITS-1:0] timer;
wire timer_expired=EXTERNAL_WATCHDOG ? watchdog_expired : (timer>=REQUEST_TIMEOUT_CYCLES-1);
// The default uses a private counter. Shared use requires
// exclusive ISSUE/RECEIVE ownership and identical clock, reset and timeout.
wire timer_control_ok=!(abort && busy && !state[15]) &&
    !(busy && !state[15] && (!storage_ready || storage_error));
assign watchdog_clear=EXTERNAL_WATCHDOG && timer_control_ok && (state[1]);
assign watchdog_tick=EXTERNAL_WATCHDOG && timer_control_ok && (state[2]) &&
    !sector_end && !(sector_valid && received>=512) && !timer_expired;
reg [8:0] parse_index;
reg [7:0] sector_ram [0:511];
reg [7:0] ram_q;
// No reset on the RAM: it is parsed only after a complete successful read.
always @(posedge clk) begin
    if (state[2] && sector_valid && received<512)
        sector_ram[received[8:0]] <= sector_byte;
    if (state[3])
        ram_q <= sector_ram[parse_index];
end

reg [7:0] jump, sig_lo, sig_hi, spc, fats;
reg [15:0] bytes_per_sector, reserved_sectors, root_entries, total16, fat16, flags, version;
reg [31:0] total32, fat32, root_cluster;
reg [7:0] part_boot, part_type;
reg [31:0] part_start, part_length, selected_start, selected_length;
reg part_selected;
reg [32:0] partition_limit;
reg partitioned;
reg [3:0] cluster_shift;
reg [33:0] metadata_q, data_sectors_q;
reg [32:0] volume_end_q, data_start_q, fat_start_q;
assign validated_volume_end=volume_end_q; // qualified only by successful mounted publication
reg [31:0] clusters_q;
reg [27:0] directory_cluster, checkpoint;
reg [7:0] cluster_sector;
reg [12:0] directory_sectors;
reg [12:0] chain_power, chain_distance;
// Brent distance/power stay unchanged throughout sector fetch and parse.
// Calculate the next checkpoint predicate during those existing cycles;
// FAT_EVALUATE commits checkpoint, power, and distance together.
reg brent_checkpoint_q;
always @(posedge clk or posedge rst)begin
    if(rst)brent_checkpoint_q<=1'b1;
    else brent_checkpoint_q<=(chain_distance+1'b1==chain_power);
end

reg [31:0] fat_value;
reg [7:0] entry_first, entry_attr;
reg [87:0] entry_name;
reg [31:0] entry_cluster, entry_size;
reg [27:0] seen_cluster [0:3];
reg [27:0] root_relative_q;
reg [35:0] root_offset_q;
reg [36:0] root_base_q,root_address_q;
reg root_bounds_q,geometry_bad_q,fat_bounds_q;
reg [32:0] fat_address_q,fat_limit_q;
reg [31:0] max_cluster_q;
wire [7:0] scale_up=spc; // admitted SPC is one-hot
wire [7:0] scale_down={spc[0],spc[1],spc[2],spc[3],spc[4],spc[5],spc[6],spc[7]};
wire [33:0] data_difference={2'd0,total32}-metadata_q;
wire [41:0] clusters_product={2'd0,clusters_q}*scale_down;
wire [35:0] root_product=root_relative_q*scale_up;
integer i;

wire [8:0] mbr_relative = parse_index-9'd446;
wire [32:0] part_end = {1'b0,part_start}+{1'b0,part_length};
wire [32:0] address_limit = {1'b0,MAX_LBA}+33'd1;
wire boot_signature = sig_lo==8'h55 && sig_hi==8'haa;
wire boot_jump = jump==8'heb || jump==8'he9;
wire valid_spc = spc!=0 && (spc & (spc-8'd1))==0 && spc<=128;
wire [39:0] fat_capacity = {8'd0,fat32} << 7;
wire [32:0] needed_fat_entries = {1'b0,clusters_q}+33'd2;
wire [31:0] max_cluster = max_cluster_q;
wire [32:0] fat_lba_wide = {1'b0,active_fat_lba}+{12'd0,directory_cluster[27:7]};
wire [8:0] fat_byte_offset = {directory_cluster[6:0],2'b00};
wire [27:0] next_cluster = fat_value[27:0];
// The lower 24 FAT bits finish at least two clocks before FAT_EVALUATE,
// even for the final FAT entry at offsets508..511. Compare that stable
// prefix early; leave the last-byte upper nibble live for the same-cycle
// final-byte/sector-end case. Reserved FAT bits31..28 remain ignored.
reg next_low_small_q,next_low_reserved_q,next_low_eoc_q;
reg next_low_gt_max_q,next_low_eq_dir_q,next_low_eq_checkpoint_q;
always @(posedge clk or posedge rst)begin
 if(rst)begin
  next_low_small_q<=0;next_low_reserved_q<=0;next_low_eoc_q<=0;
  next_low_gt_max_q<=0;next_low_eq_dir_q<=0;next_low_eq_checkpoint_q<=0;
 end else begin
  next_low_small_q<=fat_value[23:0]<24'd2;
  next_low_reserved_q<=fat_value[23:0]>=24'hfffff0;
  next_low_eoc_q<=fat_value[23:0]>=24'hfffff8;
  next_low_gt_max_q<=fat_value[23:0]>max_cluster[23:0];
  next_low_eq_dir_q<=fat_value[23:0]==directory_cluster[23:0];
  next_low_eq_checkpoint_q<=fat_value[23:0]==checkpoint[23:0];
 end
end
wire next_is_eoc=(next_cluster[27:24]==4'hf)&&next_low_eoc_q;
wire next_is_bad=((next_cluster[27:24]==0)&&next_low_small_q) ||
 ((next_cluster[27:24]==4'hf)&&next_low_reserved_q) ||
 ({4'd0,next_cluster[27:24]}>max_cluster[31:24]) ||
 (({4'd0,next_cluster[27:24]}==max_cluster[31:24])&&next_low_gt_max_q) ||
 ((next_cluster[27:24]==directory_cluster[27:24])&&next_low_eq_dir_q) ||
 ((next_cluster[27:24]==checkpoint[27:24])&&next_low_eq_checkpoint_q);

wire duplicate_file = TARGET_FILES==1 ? 1'b0 : (found_count>0 && seen_cluster[0]==entry_cluster[27:0]) ||
    (found_count>1 && seen_cluster[1]==entry_cluster[27:0]) ||
    (found_count>2 && seen_cluster[2]==entry_cluster[27:0]);
// The cluster bytes finish at directory offset 27. DIR_ENTRY is reached
// only after offsets 28..31 each pass FETCH/PARSE, so the duplicate
// result is stable well before consumption. Keep metadata CE off the
// same-cycle 28-bit comparisons without changing any request/output cycle.
reg duplicate_file_q;
always @(posedge clk or posedge rst) begin
    if (rst) duplicate_file_q <= 1'b0;
    else duplicate_file_q <= duplicate_file;
end
wire bmp_extension = (entry_name[23:16]=="B" || entry_name[23:16]=="b") &&
    (entry_name[15:8]=="M" || entry_name[15:8]=="m") &&
    (entry_name[7:0]=="P" || entry_name[7:0]=="p");
// These fields finish by directory byte27, eight clocks before DIR_ENTRY.
// Keep entry_size live: its final byte is written immediately before use.
reg entry_cluster_valid_q;
always @(posedge clk or posedge rst) begin
    if (rst) entry_cluster_valid_q <= 1'b0;
    else entry_cluster_valid_q <= entry_cluster[31:28]==0 &&
        entry_cluster>=2 && entry_cluster<=max_cluster;
end
// Low24 size bits settle at directory byte30. A shared registered
// magnitude prefix removes the wide reduction from both size predicates.
// Low6 bits and the final high8 byte remain live; no cycle/interface change.
reg entry_size_middle_q;
always @(posedge clk or posedge rst) begin
 if(rst)entry_size_middle_q<=0;
 else entry_size_middle_q<=|entry_size[23:6];
end
wire entry_size_big=(|entry_size[31:24])||entry_size_middle_q;
wire candidate_file = entry_first!=8'he5 && entry_first!=0 &&
    (entry_attr & 8'h18)==0 &&
    ((AUDIO_SCAN_ENABLE&&audio_scan)?(((entry_name[23:16]==8'h57||entry_name[23:16]==8'h77)&&(entry_name[15:8]==8'h41||entry_name[15:8]==8'h61)&&(entry_name[7:0]==8'h56||entry_name[7:0]==8'h76))&&(entry_size_big || entry_size[5:0]>=6'd44)):(bmp_extension&&(entry_size_big || entry_size[5:0]>=6'd54))) &&
    entry_cluster_valid_q && !duplicate_file_q;

// FIRST/MBR classification uses fields completed by boot byte12.
// Keep boot_signature live: byte511 is written immediately before EVALUATE.
reg boot_header_q;
always @(posedge clk or posedge rst) begin
    if (rst) boot_header_q <= 1'b0;
    else boot_header_q <= boot_jump && bytes_per_sector==512;
end

// BPB fields end at byte 47; the sector signature ends at byte 511.
// Pre-evaluate the settled fields while keeping the final signature live.
wire bpb_fields_bad = !boot_jump || bytes_per_sector!=512 || !valid_spc ||
                    reserved_sectors==0 || (fats!=1 && fats!=2) || root_entries!=0 ||
                    total16!=0 || fat16!=0 || total32==0 || fat32==0 || version!=0 ||
                    (flags[7] && flags[3:0]>=fats) || root_cluster<2 || root_cluster[31:28]!=0;
reg bpb_fields_bad_q;
always @(posedge clk or posedge rst) begin
    if (rst) bpb_fields_bad_q <= 1'b1;
    else bpb_fields_bad_q <= bpb_fields_bad;
end

task fail;
    input [7:0] code;
    begin
        error<=code; mounted<=0; found_count<=0;
        sector_abort<=sector_req; sector_req<=0; file_valid<=0;
        state<=FINISH;
    end
endtask

always @* begin
    case (spc)
        1: cluster_shift=0; 2: cluster_shift=1; 4: cluster_shift=2;
        8: cluster_shift=3; 16: cluster_shift=4; 32: cluster_shift=5;
        64: cluster_shift=6; default: cluster_shift=7;
    endcase
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        cursor_state<=ROOT_REQUEST;cursor_offset<=0;resume_offset<=0;ordinal_count<=0;
        page_last<=1;file_ordinal<=0;
        state<=IDLE; kind<=FIRST; received<=0; timer<=0; parse_index<=0;
        sector_req<=0; sector_lba<=0; sector_abort<=0;
        busy<=0; done<=0; mounted<=0; error<=ERR_NONE;
        file_valid<=0; file_slot<=0; file_short_name<=0; file_first_cluster<=0; file_size<=0;
        found_count<=0; volume_lba<=0; data_lba<=0; active_fat_lba<=0;
        cluster_count<=0; sectors_per_cluster<=0;
        jump<=0; sig_lo<=0; sig_hi<=0; spc<=0; fats<=0; bytes_per_sector<=0;
        reserved_sectors<=0; root_entries<=0; total16<=0; fat16<=0; flags<=0; version<=0;
        total32<=0; fat32<=0; root_cluster<=0;
        part_boot<=0; part_type<=0; part_start<=0; part_length<=0;
        selected_start<=0; selected_length<=0; part_selected<=0;
        partition_limit<=0; partitioned<=0;
             
        directory_cluster<=0; checkpoint<=0; cluster_sector<=0; directory_sectors<=0;
        chain_power<=1; chain_distance<=0; fat_value<=0;
        entry_first<=0; entry_attr<=0; entry_name<=0; entry_cluster<=0; entry_size<=0;
        for (i=0;i<4;i=i+1) seen_cluster[i]<=0;
        
        
        
    end else begin
        done<=0; file_valid<=0; sector_abort<=0;
        if (abort && busy && !state[15]) begin
            fail(ERR_ABORT);
        end else if (busy && !state[15] && (!storage_ready || storage_error)) begin
            fail(ERR_IO);
        end else case (1'b1)
            state[0]: if (start && !abort) begin
                if(STREAM_PAGES && next_page && mounted)begin
                    busy<=1;error<=ERR_NONE;found_count<=0;file_valid<=0;
                    for(i=0;i<4;i=i+1)seen_cluster[i]<=0;
                    page_last<=0;
                    if(page_last)begin
                        // Rewind only at a verified end of the previous walk.
                        directory_cluster<=root_cluster[27:0];checkpoint<=root_cluster[27:0];
                        cluster_sector<=0;directory_sectors<=0;chain_power<=1;chain_distance<=0;
                        ordinal_count<=0;resume_offset<=0;state<=ROOT_REQUEST;
                    end else begin
                        resume_offset<=cursor_offset;state<=cursor_state;
                    end
                end else begin
                busy<=1; mounted<=0; error<=ERR_NONE; found_count<=0;
                volume_lba<=0; data_lba<=0; active_fat_lba<=0; cluster_count<=0; sectors_per_cluster<=0;
                page_last<=0;ordinal_count<=0;resume_offset<=0;cursor_offset<=0;
                partitioned<=0; partition_limit<=0; part_selected<=0;
                selected_start<=0; selected_length<=0;
                directory_sectors<=0; chain_power<=1; chain_distance<=0;
                for (i=0;i<4;i=i+1) seen_cluster[i]<=0;
                kind<=FIRST; sector_lba<=0;
                if (!storage_ready) begin error<=ERR_IO; state<=FINISH; end
                else if (TARGET_FILES<1 || TARGET_FILES>4 || MAX_DIR_SECTORS<1 || MAX_DIR_SECTORS>4096 || REQUEST_TIMEOUT_CYCLES<1)
                    begin error<=ERR_CONFIG; state<=FINISH; end
                else state<=ISSUE;
                end
            end
            state[1]: begin
                received<=0; if(!EXTERNAL_WATCHDOG)timer<=0; parse_index<=0; sector_req<=1;
                fat_value<=0; entry_first<=0; entry_attr<=0; entry_name<=0; entry_cluster<=0; entry_size<=0;
                if (kind==FIRST || kind==BOOT) begin
                    jump<=0; sig_lo<=0; sig_hi<=0; spc<=0; fats<=0; bytes_per_sector<=0;
                    reserved_sectors<=0; root_entries<=0; total16<=0; fat16<=0; flags<=0; version<=0;
                    total32<=0; fat32<=0; root_cluster<=0;
                    part_boot<=0; part_type<=0; part_start<=0; part_length<=0;
                end
                state<=RECEIVE;
            end
            state[2]: begin
                if (sector_valid && received<512) received<=received+10'd1;
                // End and the last valid byte may arrive together.
                if (sector_end) begin
                    if ((!sector_valid && received==512) || (sector_valid && received==511)) begin
                        sector_req<=0; parse_index<=(kind==DIRECTORY) ? resume_offset : 9'd0;
                        resume_offset<=0;state<=FETCH;
                    end else fail(ERR_SECTOR);
                end else if (sector_valid && received>=512) fail(ERR_SECTOR);
                else if (timer_expired) fail(ERR_TIMEOUT);
                else if(!EXTERNAL_WATCHDOG)timer<=timer+1'b1;
            end
            state[3]: state<=PARSE;
            state[4]: begin
                if (kind==FIRST || kind==BOOT) begin
                    case (parse_index)
                        0: jump<=ram_q;
                        11: bytes_per_sector[7:0]<=ram_q; 12: bytes_per_sector[15:8]<=ram_q;
                        13: spc<=ram_q;
                        14: reserved_sectors[7:0]<=ram_q; 15: reserved_sectors[15:8]<=ram_q;
                        16: fats<=ram_q;
                        17: root_entries[7:0]<=ram_q; 18: root_entries[15:8]<=ram_q;
                        19: total16[7:0]<=ram_q; 20: total16[15:8]<=ram_q;
                        22: fat16[7:0]<=ram_q; 23: fat16[15:8]<=ram_q;
                        32: total32[7:0]<=ram_q; 33: total32[15:8]<=ram_q;
                        34: total32[23:16]<=ram_q; 35: total32[31:24]<=ram_q;
                        36: fat32[7:0]<=ram_q; 37: fat32[15:8]<=ram_q;
                        38: fat32[23:16]<=ram_q; 39: fat32[31:24]<=ram_q;
                        40: flags[7:0]<=ram_q; 41: flags[15:8]<=ram_q;
                        42: version[7:0]<=ram_q; 43: version[15:8]<=ram_q;
                        44: root_cluster[7:0]<=ram_q; 45: root_cluster[15:8]<=ram_q;
                        46: root_cluster[23:16]<=ram_q; 47: root_cluster[31:24]<=ram_q;
                        510: sig_lo<=ram_q; 511: sig_hi<=ram_q;
                    endcase
                    if (kind==FIRST && parse_index>=446 && parse_index<=509) begin
                        case (mbr_relative[3:0])
                            0: begin part_boot<=ram_q; part_type<=0; part_start<=0; part_length<=0; end
                            4: part_type<=ram_q;
                            8: part_start[7:0]<=ram_q; 9: part_start[15:8]<=ram_q;
                            10: part_start[23:16]<=ram_q; 11: part_start[31:24]<=ram_q;
                            12: part_length[7:0]<=ram_q; 13: part_length[15:8]<=ram_q;
                            14: part_length[23:16]<=ram_q; 15: part_length[31:24]<=ram_q;
                        endcase
                    end
                    if (kind==FIRST && parse_index>=446 && parse_index<=509 && mbr_relative[3:0]==15)
                        state<=MBR_ENTRY;
                    else if (parse_index==511) state<=EVALUATE;
                    else begin parse_index<=parse_index+9'd1; state<=FETCH; end
                end else if (kind==DIRECTORY) begin
                    case (parse_index[4:0])
                        0: begin entry_first<=ram_q; entry_name<={80'd0,ram_q}; entry_attr<=0; entry_cluster<=0; entry_size<=0; end
                        1,2,3,4,5,6,7,8,9,10: entry_name<={entry_name[79:0],ram_q};
                        11: entry_attr<=ram_q;
                        20: entry_cluster[23:16]<=ram_q; 21: entry_cluster[31:24]<=ram_q;
                        26: entry_cluster[7:0]<=ram_q; 27: entry_cluster[15:8]<=ram_q;
                        28: entry_size[7:0]<=ram_q; 29: entry_size[15:8]<=ram_q;
                        30: entry_size[23:16]<=ram_q; 31: entry_size[31:24]<=ram_q;
                    endcase
                    if (parse_index[4:0]==0 && ram_q==0) begin page_last<=1;state<=FINISH;end
                    else if (parse_index[4:0]==31) state<=DIR_ENTRY;
                    else begin parse_index<=parse_index+9'd1; state<=FETCH; end
                end else begin
                    if (parse_index==fat_byte_offset) fat_value[7:0]<=ram_q;
                    if (parse_index==fat_byte_offset+9'd1) fat_value[15:8]<=ram_q;
                    if (parse_index==fat_byte_offset+9'd2) fat_value[23:16]<=ram_q;
                    if (parse_index==fat_byte_offset+9'd3) fat_value[31:24]<=ram_q;
                    if (parse_index==511) state<=FAT_EVALUATE;
                    else begin parse_index<=parse_index+9'd1; state<=FETCH; end
                end
            end
            state[5]: begin
                if (!part_selected && (part_boot==0 || part_boot==8'h80) &&
                    (part_type==8'h0b || part_type==8'h0c) && part_start!=0 && part_length!=0 &&
                    part_end<=address_limit) begin
                    part_selected<=1; selected_start<=part_start; selected_length<=part_length;
                end
                parse_index<=parse_index+9'd1; state<=FETCH;
            end
            state[6]: begin
                if (kind==FIRST && !boot_header_q) begin
                    if (boot_signature && part_selected) begin
                        volume_lba<=selected_start;
                        partition_limit<={1'b0,selected_start}+{1'b0,selected_length};
                        partitioned<=1; sector_lba<=selected_start; kind<=BOOT; state<=ISSUE;
                    end else fail(ERR_NOT_FAT32);
                end else if (!boot_signature || bpb_fields_bad_q)
                    fail(ERR_BPB);
                else state<=GEOMETRY0;
            end
            state[7]: begin state<=GEOMETRY1;end
            state[8]: begin state<=GEOMETRY2;end
            state[9]: begin state<=GEOMETRY_COMMIT;end
            state[21]: begin
                if(geometry_bad_q) fail(ERR_BOUNDS);
                else begin
                    data_lba<=data_start_q[31:0]; active_fat_lba<=fat_start_q[31:0];
                    cluster_count<=clusters_q; sectors_per_cluster<=spc; mounted<=1;
                    directory_cluster<=root_cluster[27:0]; checkpoint<=root_cluster[27:0];
                    cluster_sector<=0; state<=ROOT_REQUEST;
                end
            end
            state[10]: begin state<=ROOT_SHIFT;end
            state[16]: begin state<=ROOT_SUM;end
            state[17]: begin state<=ROOT_ADD;end
            state[18]: begin state<=ROOT_CHECK;end
            state[19]: begin state<=ROOT_ISSUE;end
            state[20]: begin
                if (directory_sectors>=MAX_DIR_SECTORS && resume_offset==0) fail(ERR_DIR_LIMIT);
                else if (root_bounds_q) fail(ERR_BOUNDS);
                else begin
                    sector_lba<=root_address_q[31:0];
                    // Re-reading the cursor's current sector is not a new directory sector.
                    if(resume_offset==0)directory_sectors<=directory_sectors+1'b1;
                    kind<=DIRECTORY; state<=ISSUE;
                end
            end
            state[11]: begin
                if (candidate_file) begin
                    file_valid<=1;file_ordinal<=ordinal_count;ordinal_count<=ordinal_count+1'b1;
                    file_slot<=found_count[1:0]; file_short_name<=entry_name;
                    file_first_cluster<=entry_cluster[27:0]; file_size<=entry_size;
                    seen_cluster[found_count[1:0]]<=entry_cluster[27:0]; found_count<=found_count+1'b1;
                end
                if (candidate_file && found_count==TARGET_FILES-1) begin
                    cursor_state<=(parse_index==511) ? ROOT_NEXT : ROOT_REQUEST;
                    cursor_offset<=(parse_index==511) ? 9'd0 : parse_index+9'd1;
                    page_last<=!STREAM_PAGES;state<=FINISH;
                end
                else if (parse_index==511) state<=ROOT_NEXT;
                else begin parse_index<=parse_index+9'd1; state<=FETCH; end
            end
            state[12]: begin
                // At a cluster boundary permit the final FAT/EOC check even if
                // the data-sector budget is exactly consumed. ROOT_REQUEST
                // rejects another data read if the chain continues.
                if (cluster_sector+9'd1<spc) begin cluster_sector<=cluster_sector+1'b1; state<=ROOT_REQUEST; end
                else state<=FAT_REQUEST;
            end
            state[13]: begin state<=FAT_SUM;end
            state[22]: begin state<=FAT_CHECK;end
            state[23]: begin
                // Geometry validation ensures all valid clusters have a FAT entry.
                if(fat_bounds_q)fail(ERR_BOUNDS);
                else begin sector_lba<=fat_address_q[31:0]; kind<=FAT; state<=ISSUE; end
            end
            state[14]: begin
                // The upper four FAT bits are reserved and must be ignored.
                if (next_is_eoc) begin page_last<=1;state<=FINISH;end
                else if (next_is_bad)
                    fail(ERR_CHAIN);
                else begin
                    directory_cluster<=next_cluster; cluster_sector<=0;
                    // Brent cycle detector: constant memory, bounded sector walk.
                    if (brent_checkpoint_q) begin
                        checkpoint<=next_cluster; chain_distance<=0;
                        if (chain_power<4096) chain_power<=chain_power<<1;
                    end else chain_distance<=chain_distance+1'b1;
                    state<=ROOT_REQUEST;
                end
            end
            state[15]: begin busy<=0; done<=1; sector_req<=0; state<=IDLE; end
            default: fail(ERR_CONFIG);
        endcase
    end
end

// Arithmetic pipeline stages have one-hot independent enables. The same
// abort/storage failure priority is retained, without the sequential case
// priority tree in every wide arithmetic/register clock-enable cone.
wire stage_enable=!(busy && !state[15] && (abort || !storage_ready || storage_error));
always @(posedge clk or posedge rst) begin
    if(rst) begin
        metadata_q<=0;
        volume_end_q<=0;
        fat_start_q<=0;
        data_sectors_q<=0;
        data_start_q<=0;
        clusters_q<=0;
        max_cluster_q<=0;
        fat_limit_q<=0;
        geometry_bad_q<=0;
        root_relative_q<=0;
        root_offset_q<=0;
        root_base_q<=0;
        root_address_q<=0;
        root_bounds_q<=0;
        fat_address_q<=0;
        fat_bounds_q<=0;
    end else if(stage_enable) begin
        // Metadata fields are stable before EVALUATE. Advance its existing
        // sum one cycle, then reuse clusters_q in GEOMETRY0 for the data
        // sector difference; GEOMETRY1 replaces it with final scaled clusters.
        // All valid differences fit32bits. Invalid metadata>=total cases
        // receive mandatory GEOMETRY2 validation.
        if(state[6])begin
            metadata_q<={18'd0,reserved_sectors} + ((fats==2) ? ({2'd0,fat32}<<1) : {2'd0,fat32});
        end
        if(state[7])begin
            clusters_q<={2'd0,total32}-metadata_q;
                volume_end_q<={1'b0,volume_lba}+{1'b0,total32};
                fat_start_q<={1'b0,volume_lba}+{17'd0,reserved_sectors}+
                    ((flags[7] && flags[3:0]==1) ? {1'b0,fat32} : 33'd0);
        end
        if(state[8])begin
            data_sectors_q<={2'd0,total32}-metadata_q;
                data_start_q<={1'b0,volume_lba}+metadata_q;
                clusters_q<=clusters_product[38:7];
        end
        if(state[9])begin
            max_cluster_q<=clusters_q+32'd1;
                fat_limit_q<=fat_start_q+{1'b0,fat32};
                geometry_bad_q<=(metadata_q>={2'd0,total32} || volume_end_q>address_limit ||
                    (partitioned && volume_end_q>partition_limit) || data_start_q[32] || fat_start_q[32] ||
                    clusters_q<65525 || clusters_q>32'h0fffffee ||
                    fat_capacity<needed_fat_entries || {1'b0,root_cluster}>needed_fat_entries-33'd1);
        end
        if(state[10])begin
            root_relative_q<=directory_cluster-28'd2;
        end
        if(state[16])begin
            root_offset_q<=root_product;
        end
        if(state[17])begin
            root_base_q<={5'd0,data_lba}+{1'b0,root_offset_q};
        end
        if(state[18])begin
            root_address_q<=root_base_q+{29'd0,cluster_sector};
        end
        if(state[19])begin
            root_bounds_q<=(root_address_q>{5'd0,MAX_LBA} || root_address_q>={4'd0,volume_end_q});
        end
        if(state[13])begin
            fat_address_q<=fat_lba_wide;
        end
        if(state[22])begin
            fat_bounds_q<=(fat_address_q>MAX_LBA || fat_address_q>=fat_limit_q);
        end
    end
end
endmodule
