// Long audio FAT chain reader. No full preflight; every next cluster is bounded,
// Brent cycle-checked and final EOC checked. Corrupt media can fail mid-play.
module fat32_audio_reader_078 #(
    // 0: standalone, capture and validate all supplied geometry.
    // 1: only for a caller that publishes immutable geometry after the real
    // FAT32 catalogue has committed its BPB/volume/FAT-capacity checks.
    // All metadata plus validated_data_end must stay stable until reset or done.
    // The caller must reset this reader before replacing any metadata.
    parameter integer VALIDATED_GEOMETRY=0,
    parameter integer REQUEST_TIMEOUT_CYCLES=100_000_000,
    parameter integer MAX_FILE_BYTES=536_870_910,
    parameter integer MAX_FILE_CLUSTERS=1_048_576,
    parameter [31:0] MAX_LBA=32'hffffffff
)(
    input wire clk,rst,start,abort,storage_ready,storage_error,
    input wire prefix_only,
    input wire [27:0] first_cluster,
    input wire [31:0] size_bytes,data_lba,active_fat_lba,cluster_count,
    input wire [7:0] sectors_per_cluster,
    // Exclusive 33-bit end from the same validated volume, including 2**32.
    // Ignored when VALIDATED_GEOMETRY=0.
    input wire [32:0] validated_data_end,
    output reg sector_req,
    output reg [31:0] sector_lba,
    input wire [7:0] sector_byte,
    input wire sector_valid,sector_end,
    output reg sector_abort,busy,done,
    output reg [7:0] error,
    output reg file_valid,
    input wire file_ready,
    output reg [7:0] file_byte,
    output reg [31:0] file_byte_offset,
    output reg file_end
);
localparam [7:0] ERR_NONE=0,ERR_CONFIG=1,ERR_BOUNDS=2,ERR_CHAIN=3,
    ERR_IO=4,ERR_TIMEOUT=5,ERR_SECTOR=6,ERR_ABORT=7;
localparam [4:0] IDLE=0,CONFIGURE=1,GEOMETRY=2,FAT_ADDRESS=3,
    ISSUE=4,RECEIVE=5,FAT_FETCH=6,FAT_BYTE=7,FAT_CHECK=8,
    DATA_ADDRESS=9,DATA_FETCH=10,DATA_BYTE=11,DATA_ADVANCE=12,FINISH=13,
    NEEDED=14,NEEDED_COUNT=15,GEOMETRY_COMMIT=16,FAT_DECIDE=17,FAT_APPLY=18,
    DATA_SHIFT=19,DATA_SUM=20,DATA_ADD=21,DATA_CHECK=22,DATA_ISSUE=23;
localparam integer TIMER_BITS=(REQUEST_TIMEOUT_CYCLES>1)?$clog2(REQUEST_TIMEOUT_CYCLES):1;
// The maximum file length is a checked parameter. Keep enough bits for
// every valid offset and ceil(bytes / 512), plus the invalid-input flag.
localparam integer FILE_BITS=(MAX_FILE_BYTES>0 && MAX_FILE_BYTES<2147483647)?$clog2(MAX_FILE_BYTES+1):32;
localparam integer COUNT_BITS=(FILE_BITS>9)?FILE_BITS-8:1;
reg size_bad_q,clusters_bad_q;
reg [4:0] state;
reg prefix_q,preflight,read_fat;
reg [27:0] first_q_held,current_cluster;
reg [FILE_BITS-1:0] size_q_held;
reg [31:0] data_q_held,fat_q_held;
reg [27:0] clusters_q_held;
reg [COUNT_BITS-1:0] needed_clusters;
reg [COUNT_BITS-1:0] links_left;
// predecode the wide terminal-count compare before FAT_CHECK.
// links_left is stable throughout FAT_FETCH/FAT_BYTE; no request/byte latency changes.
reg last_link_q;
always @(posedge clk or posedge rst) begin
    if(rst) last_link_q<=0;
    else last_link_q<=(links_left==1);
end
reg [27:0] checkpoint;
reg [20:0] chain_power,chain_distance;
reg [7:0] spc_q_held,cluster_sector;
reg [3:0] cluster_shift;
reg [9:0] received;
reg [TIMER_BITS-1:0] timer;
reg [7:0] data_ram[0:511],fat_ram[0:511];
reg [1:0] fat_byte_index;
// RAM indices are already represented by the public byte offset and the
// FAT byte phase; deriving them avoids two duplicate counters.
wire [8:0] data_index=file_byte_offset[8:0];
wire [8:0] fat_index={current_cluster[6:0],fat_byte_index};
reg [7:0] data_ram_q,fat_ram_q;
reg cache_valid;
reg [31:0] cached_lba,fat_value;

reg [FILE_BITS-1:0] output_limit;
reg [FILE_BITS-1:0] size_minus_q,last_offset_q;
reg [27:0] max_cluster_q;
reg [34:0] data_span_q;
reg [35:0] data_end_q;
reg [27:0] data_relative_q;
reg [34:0] data_offset_q;
reg [35:0] data_address_q;
reg [32:0] fat_address_q;
reg geometry_bad_q,fat_bad_q,cache_hit_q,data_bad_q;
wire [27:0] first_q=VALIDATED_GEOMETRY ? first_cluster : first_q_held;
wire [FILE_BITS-1:0] size_q=VALIDATED_GEOMETRY ? size_bytes[FILE_BITS-1:0] : size_q_held;
wire [31:0] data_q=VALIDATED_GEOMETRY ? data_lba : data_q_held;
wire [31:0] fat_q=VALIDATED_GEOMETRY ? active_fat_lba : fat_q_held;
wire [27:0] clusters_q=VALIDATED_GEOMETRY ? cluster_count[27:0] : clusters_q_held;
wire [7:0] spc_q=VALIDATED_GEOMETRY ? sectors_per_cluster : spc_q_held;
wire [35:0] checked_data_end=VALIDATED_GEOMETRY ? {3'd0,validated_data_end} : data_end_q;
wire [27:0] next_cluster=fat_value[27:0];
wire [32:0] fat_address_wide={1'b0,fat_q}+{12'd0,current_cluster[27:7]};
wire [32:0] address_limit={1'b0,MAX_LBA}+33'd1;
wire valid_spc=spc_q!=0 && spc_q<=128 && (spc_q & (spc_q-8'd1))==0;
wire valid_link=next_cluster>=2 && next_cluster<28'hffffff0 &&
    {4'd0,next_cluster}<=max_cluster_q;
wire end_link=next_cluster>=28'hffffff8;
wire last_byte=(file_byte_offset==last_offset_q);
always @* begin
    case(spc_q)
        1:cluster_shift=0;2:cluster_shift=1;4:cluster_shift=2;8:cluster_shift=3;
        16:cluster_shift=4;32:cluster_shift=5;64:cluster_shift=6;default:cluster_shift=7;
    endcase
end
// Exact power-of-two scaling into the existing registered stages.
wire [7:0] scale_up=spc_q; // admitted SPC is one-hot
wire [7:0] scale_down={spc_q[0],spc_q[1],spc_q[2],spc_q[3],spc_q[4],spc_q[5],spc_q[6],spc_q[7]};
wire [39:0] needed_product=size_minus_q*scale_down;
wire [34:0] span_product=clusters_q*scale_up;
wire [34:0] offset_product=data_relative_q*scale_up;
// RAM has no reset. Successful complete reads are the only way to expose it.
always @(posedge clk) begin
    if(state==RECEIVE && sector_valid && received<512) begin
        if(read_fat) fat_ram[received[8:0]]<=sector_byte;
        else data_ram[received[8:0]]<=sector_byte;
    end
    if(state==FAT_FETCH) fat_ram_q<=fat_ram[fat_index];
    if(state==DATA_FETCH) data_ram_q<=data_ram[data_index];
end
task fail;
    input [7:0] code;
    begin
        error<=code;sector_abort<=sector_req;sector_req<=0;
        file_valid<=0;cache_valid<=0;state<=FINISH;
    end
endtask
// the address datapath can compute even when this transaction aborts.
// Error priority and all requests stay in the main FSM; FAT_DECIDE/APPLY
// are unreachable after abort. Every later transaction overwrites this
// private register in FAT_ADDRESS before consuming it. No latency change.
always @(posedge clk or posedge rst) begin
    if(rst) fat_address_q<=0;
    else if(state==FAT_ADDRESS) fat_address_q<=fat_address_wide;
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        size_bad_q<=0;clusters_bad_q<=0;state<=IDLE;prefix_q<=0;preflight<=0;read_fat<=0;
        first_q_held<=0;current_cluster<=0;size_q_held<=0;data_q_held<=0;fat_q_held<=0;clusters_q_held<=0;
        needed_clusters<=0;links_left<=0;checkpoint<=0;chain_power<=1;chain_distance<=0;spc_q_held<=0;cluster_sector<=0;
        received<=0;timer<=0;fat_byte_index<=0;
        cache_valid<=0;cached_lba<=0;fat_value<=0;output_limit<=0;
        size_minus_q<=0;last_offset_q<=0;max_cluster_q<=0;data_span_q<=0;data_end_q<=0;
        data_relative_q<=0;data_offset_q<=0;data_address_q<=0;
        geometry_bad_q<=0;fat_bad_q<=0;cache_hit_q<=0;data_bad_q<=0;
        sector_req<=0;sector_lba<=0;sector_abort<=0;busy<=0;done<=0;error<=0;
        file_valid<=0;file_byte<=0;file_byte_offset<=0;file_end<=0;
    end else begin
        done<=0;file_end<=0;sector_abort<=0;
        if(abort && busy && state!=FINISH) fail(ERR_ABORT);
        else if(busy && state!=FINISH && (!storage_ready || storage_error)) fail(ERR_IO);
        else case(state)
            IDLE: if(start && !abort) begin
                busy<=1;error<=0;file_valid<=0;file_byte_offset<=0;cache_valid<=0;
                first_q_held<=first_cluster;current_cluster<=first_cluster;
                size_q_held<=size_bytes;data_q_held<=data_lba;fat_q_held<=active_fat_lba;
                size_bad_q<=size_bytes==0 || size_bytes>MAX_FILE_BYTES;
                clusters_bad_q<=cluster_count<1 || cluster_count>32'h0fffffee;
                clusters_q_held<=cluster_count;spc_q_held<=sectors_per_cluster;
                prefix_q<=prefix_only;preflight<=0;checkpoint<=first_cluster;chain_power<=1;chain_distance<=0;cluster_sector<=0;
                output_limit<=prefix_only && size_bytes>512 ? 512 : size_bytes;
                state<=CONFIGURE;
            end
            CONFIGURE: begin
                if(!storage_ready || size_bad_q || (!VALIDATED_GEOMETRY && !valid_spc) ||
                    MAX_FILE_CLUSTERS<1 || MAX_FILE_CLUSTERS>1_048_576 || REQUEST_TIMEOUT_CYCLES<1)
                    fail(ERR_CONFIG);
                else begin
                    size_minus_q<=size_q-1;last_offset_q<=output_limit-1;
                    state<=NEEDED;
                end
            end
            NEEDED:begin
                needed_clusters<=needed_product[39:16];
                data_span_q<=span_product;state<=NEEDED_COUNT;
            end
            NEEDED_COUNT:begin
                needed_clusters<=needed_clusters+1'b1;max_cluster_q<=clusters_q+1'b1;
                data_end_q<={1'b0,data_span_q}+{4'd0,data_q};state<=GEOMETRY;
            end
            GEOMETRY: begin
                geometry_bad_q<=(first_q<2 ||
                    {4'd0,first_q}>max_cluster_q || needed_clusters>MAX_FILE_CLUSTERS ||
                    needed_clusters>clusters_q ||
                    (!VALIDATED_GEOMETRY && (clusters_bad_q || data_q==0 || fat_q>=data_q ||
                    data_end_q>{3'd0,address_limit})));state<=GEOMETRY_COMMIT;
            end
            GEOMETRY_COMMIT:begin
                if(geometry_bad_q)fail(ERR_BOUNDS);
                else begin
                    links_left<=needed_clusters;
                    state<=DATA_ADDRESS;
                end
            end
            FAT_ADDRESS: begin
                fat_byte_index<=0;fat_value<=0;
                state<=FAT_DECIDE;
            end
            FAT_DECIDE:begin
                fat_bad_q<=(fat_address_q[32] || fat_address_q[31:0]>=data_q ||
                    fat_address_q[31:0]>MAX_LBA);
                cache_hit_q<=cache_valid && cached_lba==fat_address_q[31:0];state<=FAT_APPLY;
            end
            FAT_APPLY:begin
                if(fat_bad_q)fail(ERR_BOUNDS);
                else begin
                    if(cache_hit_q) state<=FAT_FETCH;
                    else begin
                        sector_lba<=fat_address_q[31:0];read_fat<=1;cache_valid<=0;state<=ISSUE;
                    end
                end
            end
            ISSUE: begin received<=0;timer<=0;sector_req<=1;state<=RECEIVE;end
            RECEIVE: begin
                if(sector_valid && received<512) received<=received+10'd1;
                if(sector_end) begin
                    if((!sector_valid && received==512)||(sector_valid && received==511)) begin
                        sector_req<=0;
                        if(read_fat) begin cached_lba<=sector_lba;cache_valid<=1;state<=FAT_FETCH;end
                        else state<=DATA_FETCH;
                    end else fail(ERR_SECTOR);
                end else if(sector_valid && received>=512) fail(ERR_SECTOR);
                else if(timer>=REQUEST_TIMEOUT_CYCLES-1) fail(ERR_TIMEOUT);
                else timer<=timer+1'b1;
            end
            FAT_FETCH: state<=FAT_BYTE;
            FAT_BYTE: begin
                case(fat_byte_index)
                    0:fat_value[7:0]<=fat_ram_q;1:fat_value[15:8]<=fat_ram_q;
                    2:fat_value[23:16]<=fat_ram_q;3:fat_value[31:24]<=fat_ram_q;
                endcase
                if(fat_byte_index==3) state<=FAT_CHECK;
                else begin fat_byte_index<=fat_byte_index+1'b1;state<=FAT_FETCH;end
            end
            FAT_CHECK: begin
                if(last_link_q) begin
                    if(!end_link) fail(ERR_CHAIN);
                    else if(preflight) begin
                        preflight<=0;current_cluster<=first_q;links_left<=needed_clusters;
                        cluster_sector<=0;state<=DATA_ADDRESS;
                    end else state<=FINISH;
                end else if(!valid_link||next_cluster==current_cluster||next_cluster==checkpoint) fail(ERR_CHAIN);
                else begin
                    current_cluster<=next_cluster;links_left<=links_left-1'b1;cluster_sector<=0;
                    if(chain_distance+1'b1==chain_power)begin
                        checkpoint<=next_cluster;chain_distance<=0;chain_power<=chain_power<<1;
                    end else chain_distance<=chain_distance+1'b1;
                    state<=preflight ? FAT_ADDRESS : DATA_ADDRESS;
                end
            end
            DATA_ADDRESS: begin
                data_relative_q<=current_cluster-28'd2;state<=DATA_SHIFT;
            end
            // The shifted cluster offset has cluster_shift low zero bits and
            // cluster_sector < sectors_per_cluster == 2**cluster_shift.
            // Therefore OR is exactly addition, without a wide second adder.
            DATA_SHIFT:begin data_offset_q<=offset_product|{27'd0,cluster_sector};state<=DATA_SUM;end
            DATA_SUM:begin data_address_q<={4'd0,data_q}+{1'b0,data_offset_q};state<=DATA_CHECK;end
            DATA_CHECK:begin
                data_bad_q<=(data_address_q>{4'd0,MAX_LBA} || data_address_q>=checked_data_end);state<=DATA_ISSUE;
            end
            DATA_ISSUE:begin
                if(data_bad_q)fail(ERR_BOUNDS);
                else begin sector_lba<=data_address_q[31:0];read_fat<=0;state<=ISSUE;end
            end
            DATA_FETCH: state<=DATA_BYTE;
            DATA_BYTE: begin
                if(!file_valid) begin file_byte<=data_ram_q;file_valid<=1;end
                else if(file_ready) begin
                    file_valid<=0;
                    if(last_byte) begin
                        if(prefix_q) state<=FINISH;
                        else state<=FAT_ADDRESS;
                    end else begin
                        file_byte_offset<={{(32-FILE_BITS){1'b0}},(file_byte_offset[FILE_BITS-1:0]+1'b1)};
                        if(data_index==511) state<=DATA_ADVANCE;
                        else state<=DATA_FETCH;
                    end
                end
            end
            DATA_ADVANCE: begin
                if(cluster_sector+8'd1<spc_q) begin cluster_sector<=cluster_sector+1'b1;state<=DATA_ADDRESS;end
                else state<=FAT_ADDRESS;
            end
            FINISH: begin
                sector_req<=0;file_valid<=0;busy<=0;done<=1;file_end<=(error==0);state<=IDLE;
            end
            default: fail(ERR_CONFIG);
        endcase
    end
end
endmodule
