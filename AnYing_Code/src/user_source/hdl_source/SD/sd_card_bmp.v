
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [4:0]   DEFAULT_INTERVAL_S = 5'd5,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    parameter integer TF_INIT_TIMEOUT_MS = 3000,
    parameter integer TF_SCAN_READ_TIMEOUT_MS = 1000,
    parameter integer TF_RESET_HOLD_MS = 1,
    parameter integer TF_DRAIN_TIMEOUT_MS = 3000,
    parameter integer TF_MAX_RETRIES = 1,
    parameter integer FOUR_FRAME_STREAM = 1,
    parameter integer ALL_ROOT_IMAGES = 1,
    parameter integer DISPLAY_PREPARE_MS = 1000,
    parameter integer USER_SETTINGS_ENABLE = 0,
    parameter integer CONFIG_RESTORE_ENABLE = 0,
    parameter integer SESSION_CONTROL_ENABLE = 0,
    parameter integer BMP_ADAPT_ENABLE = 0,
    parameter integer USER_WAKE_ENABLE = 0,
    parameter integer UI078_ENABLE = 0,
    parameter integer REMOTE_ENABLE = 0,
    parameter integer IR_ENABLE = 0
)(
    input                       clk,
    input remote_valid,
    input ir_valid,
    input [3:0] ir_action,
    input [7:0] remote_command,remote_argument,
    output remote_reply,
    output [2:0] remote_result,
    output [4:0] remote_hours,
    output [5:0] remote_minutes,
    input                       rst,
    input                       key_next,
    input                       key_auto,       // Board K4: autoplay on/off
    input                       key_period_up,  // Board K3: +1 second in autoplay
    input                       settings_mode_in,   // SW1: 0=playback, 1=settings
    input                       settings_volume_in, // SW2: 0=brightness, 1=volume
    input audio_clk,audio_reset,audio_read,
    output [15:0] audio_pcm,
    output audio_pcm_valid,audio_empty,
    output [11:0] audio_level,
    output [3:0] audio_error,
    output audio_found,audio_format_ok,
    input switch3_in,
    input user_wake_level,
    output reg thumbnail_layout,
    output reg [3:0] thumbnail_mask,
    output [3:0] cached_banks,
    output [1:0] thumbnail_focus,
    output [5:0] ui_seconds,
    output [7:0] ui_flags,
    output wire [4:0] music_index,
    output wire [5:0] music_count,
    input                       timer_enable_in, // independent SW4: high=timed
    output [1:0]                session_state,
    output                      session_expired,session_timer_enabled,session_timer_running,
    output                      session_timer_page,session_selected_auto,session_blink,
    output [4:0]                session_hours,
    output [5:0]                session_minutes,
    output [2:0]                session_zoom,
    output [1:0]                session_rotate,
    output      [3:0]           brightness_level,
    output      [3:0]           volume_level,
    output [3:0] committed_brightness,committed_volume,
    output [2:0] contrast_level,committed_contrast,settings_focus,
    output                      settings_active,
    output                      settings_volume_selected,
    input                       config_restore_valid,
    input [15:0]                config_restore_value,
    output reg                  config_restore_ack,
    output reg                  config_ready,
    output [4:0]                current_interval_s,
    output                      osd_auto_play,
    output                      osd_activity,
    input                       period_notice_ack,
    output reg [4:0]            period_notice_seconds,
    output reg                  period_notice_req,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output reg                  media_cue_valid,
    output reg [2:0]            media_cue_note,
    output      [3:0]           state_code,
    output      [3:0]           timeout_code,
    output      [15:0]          pixel_units,

    input                       write_finish_toggle,
    input                       display_commit_ack,
    output reg                  display_commit_req,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

wire key_next_press;
wire key_auto_press;
wire key_auto_press_raw, key_auto_released;
reg auto_key_armed;
wire controls_enabled = !CONFIG_RESTORE_ENABLE || config_ready;
wire restore_apply = CONFIG_RESTORE_ENABLE && !config_ready && config_restore_valid;
wire restore_range_valid = (config_restore_value[15:13]<=3'd4) && (config_restore_value[12:9]>=4'd1) &&
                           (config_restore_value[12:9]<=4'd9) &&
                           (config_restore_value[8:5]<=4'd9) &&
                           (config_restore_value[4:0]>=5'd1) &&
                           (config_restore_value[4:0]<=5'd30);
// Whole-tuple fallback prevents a malformed producer from applying a partial setting.
wire [15:0] restore_value_safe = restore_range_valid ? config_restore_value : {3'd2,4'd9,4'd9,5'd5};
wire legacy_auto_press;
assign legacy_auto_press = CONFIG_RESTORE_ENABLE ?
                        (controls_enabled && auto_key_armed && key_auto_press_raw) : key_auto_press_raw;
always @(posedge clk or posedge rst) begin
    if(rst) begin config_ready<=!CONFIG_RESTORE_ENABLE;config_restore_ack<=0;end
    else begin
        config_restore_ack<=0;
        if(restore_apply) begin config_ready<=1;config_restore_ack<=1;end
    end
end
// A K4 press that began while restoring is discarded, including a late debounce pulse.
// Require a stable release before accepting a fresh playback/recovery request.
always @(posedge clk or posedge rst) begin
    if(rst)auto_key_armed<=0;
    else if(!controls_enabled)auto_key_armed<=0;
    else if(key_auto_press_raw)auto_key_armed<=0;
    else if(key_auto_released)auto_key_armed<=1;
end
wire session_mode_set,session_mode_value,session_play_allowed;
wire ui_thumb_request,ui_open,ui_inc,ui_dec;
wire [1:0] ui_focus;
wire [4:0] ui_live_hours,ui_edit_hours;
wire [5:0] ui_live_minutes,ui_edit_minutes;
wire ui_edit_finite,ui_finite,ui_minute,ui_subtract,ui_manual_tools,ui_auto_tools,ui_interval_subtract,ui_confirmed;
reg view_transaction;
reg [3:0] view_release_mask;
wire view_locked=UI078_ENABLE&&(ui_thumb_request||thumbnail_layout||view_transaction);
wire view_change=UI078_ENABLE&&(ui_thumb_request!=thumbnail_layout);
assign thumbnail_focus=UI078_ENABLE?ui_focus:2'd0;
wire ui_music_paused,ui_music_next;
wire music_next_ready;
assign remote_hours=ui_live_hours;
assign remote_minutes=ui_live_minutes;
wire [3:0] ui_saved_brightness,ui_saved_volume;
wire [2:0] ui_saved_contrast;
assign committed_contrast=UI078_ENABLE?ui_saved_contrast:3'd2;
assign committed_brightness=UI078_ENABLE?ui_saved_brightness:brightness_level;
assign committed_volume=UI078_ENABLE?ui_saved_volume:volume_level;
assign ui_flags={ui_confirmed,ui_interval_subtract,ui_auto_tools,ui_manual_tools,ui_music_paused,ui_minute,ui_edit_finite,ui_finite};
function [3:0] preceding_mask;
 input [1:0] current_bank,target_bank;
 reg [1:0] distance;
 reg [3:0] m;
 begin
  distance=target_bank-current_bank;m=0;
  if(distance>=1)m[current_bank]=1;
  if(distance>=2)m[(current_bank+2'd1)&2'd3]=1;
  if(distance>=3)m[(current_bank+2'd2)&2'd3]=1;
  preceding_mask=m;
 end
endfunction
wire key_period_up_press;
wire key_next_press_raw, key_period_up_press_raw;
wire key_next_released, key_period_up_released;

wire bmp_sector_req,bmp_sector_valid,bmp_sector_end,bmp_sector_active;
wire [31:0] bmp_sector_lba;
wire music_found,music_sector_req,music_valid,music_end,music_urgent,music_owner;
wire [27:0] music_cluster;
wire [31:0] music_size,music_data_lba,music_fat_lba,music_clusters,music_sector_lba;
wire [7:0] music_spc;
wire [32:0] music_volume_end;
assign audio_found=music_found;
wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
wire             file_storage_fault;
wire             bmp_load_error;
wire             bmp_load_data_error;
wire [2:0]       bmp_error;
wire             scan_done;
wire             scan_paused;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;

reg              scan_start_pulse;
reg              scan_resume_pulse;
reg              page_next_pulse,page_wait,page_consumed,round_good;
wire             page_done,page_last,all_images_active;
wire [15:0]      file_ordinal;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              tf_restart_autoplay;
reg              auto_play_en;
// Read-only OSD observation: no OSD signal feeds playback or parameter control.
assign osd_auto_play = auto_play_en;
wire parameter_activity;
// Same-cycle provenance for controller playback pulses; never masks later local actions.
wire ir_playback_event,ir_period_event;
reg osd_parameter_activity, osd_playback_activity;
assign osd_activity = osd_parameter_activity || osd_playback_activity;
localparam integer AUTO_SUBSEC_BITS = (CLK_FREQ_HZ > 1) ? $clog2(CLK_FREQ_HZ) : 1;
reg [AUTO_SUBSEC_BITS-1:0] auto_cnt;
reg [4:0]        auto_elapsed_s;
reg [4:0]        period_seconds;
assign current_interval_s = period_seconds;
reg [1:0]        period_ack_sync;
reg              period_notice_pending;
wire             auto_timer_active;
wire             period_adjust_event;
wire [4:0]       adjusted_period_seconds;
reg [2:0]        img_found_count;
reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg              next_req_pending;
reg              load_busy;
reg              prefetch_ready;
reg              prefetch_failed;
reg              switch_busy;
reg [1:0]        active_buf_idx;
reg [2:0]        commit_ack_sync;
reg              auto_req_pending;
wire             display_commit_done;
wire             display_commit_idle;
assign display_commit_idle = (commit_ack_sync[2] == display_commit_req);
assign display_commit_done = switch_busy && display_commit_idle;
// Prepare scan qualification one SD clock early. A fresh transaction always
// asserts switch_busy with its token, so live switch_busy cancels stale idle.
// Losing init/TF recovery has priority over the scan consumer below.
reg scan_mailbox_idle_q;
always @(posedge clk or posedge rst) begin
    if (rst) scan_mailbox_idle_q <= 1'b0;
    else scan_mailbox_idle_q <= !switch_busy && display_commit_idle;
end

reg [31:0]       load_timeout_cnt;

reg              load_abort;

// Four physical banks form a streaming queue. Completed frames remain owned
// until the display reader ACKs its replacement. A released bank is read again
// from TF; this is not a resident image cache. Logical image and bank IDs differ.
reg [3:0] bank_valid;
// Complete RAM ownership, including the currently displayed image.
assign cached_banks=bank_valid|(display_valid?(4'b0001<<active_buf_idx):4'd0);
reg [1:0] bank_image0, bank_image1, bank_image2, bank_image3;
reg [1:0] fill_bank_idx, show_bank_idx, fill_img_idx;
reg [1:0] commit_img_idx;
reg warmup_complete;
localparam integer PREPARE_CYCLES_PER_MS = (CLK_FREQ_HZ >= 1000) ? CLK_FREQ_HZ/1000 : 1;
localparam integer PREPARE_CYCLES = (DISPLAY_PREPARE_MS > 0) ?
                                  PREPARE_CYCLES_PER_MS*DISPLAY_PREPARE_MS : 1;
localparam integer PREPARE_BITS = (PREPARE_CYCLES > 1) ? $clog2(PREPARE_CYCLES+1) : 1;
reg [PREPARE_BITS-1:0] prepare_count;
reg screen_ready;
always @(posedge clk or posedge rst) begin
    if (rst) begin prepare_count<=0;screen_ready<=(DISPLAY_PREPARE_MS==0);end
    else if (!screen_ready) begin
        if (prepare_count >= PREPARE_CYCLES-1) screen_ready<=1'b1;
        else prepare_count<=prepare_count+1'b1;
    end
end

// Retry belongs to the resource, not to an individual load_start pulse.
// Exhausted resources remain excluded until a user starts a new recovery round.
localparam [2:0] REC_IDLE = 3'd0, REC_DRAIN = 3'd1, REC_RETRY = 3'd2,
                 REC_NEXT = 3'd3, REC_STOP = 3'd4, REC_PAGE = 3'd5;
reg [2:0]        recovery_state;
reg              retry_used;
reg              recover_same;
reg              recovery_blocked;
reg [3:0]        bad_images;
reg [1:0]        search_idx;
reg [2:0]        search_steps;
reg [1:0]        wrack_sync;
reg [2:0]        write_finish_guard;
wire             drain_ready = bmp_ready && !write_req && !wrack_sync[1];
wire             recovery_restart = (recovery_state == REC_STOP) && (scan_done || scan_paused) &&
                                     (all_images_active || (img_found_count != 3'd0)) &&
                                     ((key_next_press && !key_auto_press) ||
                                      (key_auto_press && (all_images_active || (img_found_count > 3'd1))));
wire             drain_expired = (recovery_state == REC_DRAIN) && !load_abort &&
                                    !drain_ready && (load_timeout_cnt > 32'd300_000_000);
wire             search_eligible = ({1'b0, search_idx} < img_found_count) && !bad_images[search_idx] &&
                                    (FOUR_FRAME_STREAM || !display_valid ||
                                     (img_found_count == 3'd1) || (search_idx != img_idx));
wire stream_bank_free = !bank_valid[fill_bank_idx] &&
                        (!display_valid || (fill_bank_idx != active_buf_idx)) &&
                        (!thumbnail_layout || !thumbnail_mask[fill_bank_idx]);
wire stream_head_ready = bank_valid[show_bank_idx] &&
                         (!first_image_committed || (show_bank_idx != active_buf_idx));
// Display the first fully committed frame after initialization completes.
wire stream_initial_ready = controls_enabled && screen_ready;
// Enter with the available complete images; empty cells fill in place.
wire view_change_ready=view_change;



// Latest failure: 1..7=header category; 8=neither, 9=write only, A=source only timeout.
reg [3:0]        timeout_diag;
// B=count short, C=count excess, D=abnormal sector/pixel ending.
// Count decoder pixel pulses; hold the count from the latest failure.
// This is an output-count check, not a readback verification of SDRAM.
localparam [3:0] ERR_PIXELS_SHORT = 4'hB;
localparam [3:0] ERR_PIXELS_EXTRA = 4'hC;
localparam [3:0] ERR_DATA_END     = 4'hD;
reg [18:0]       sent_pixels;
reg [31:0]       expected_pixels;
reg              pixel_count_exact_q;
reg              pixel_count_short_q;
reg              source_count_checked;
wire             pixel_capacity = ({13'd0, sent_pixels} < expected_pixels);
wire             pixel_excess = (bmp_data_wr_en && !pixel_capacity) ||
                                   (source_count_checked && !pixel_count_exact_q && !pixel_count_short_q);
wire             pixel_short = source_count_checked && pixel_count_short_q;
wire             pixel_failure = bmp_load_data_error || pixel_excess || pixel_short;
wire [3:0]       pixel_failure_code = bmp_load_data_error ? ERR_DATA_END :
                                      pixel_excess ? ERR_PIXELS_EXTRA : ERR_PIXELS_SHORT;
reg [18:0]       timeout_pixels;
wire [7:0]       bmp_load_data_detail;
reg [15:0]       data_failure_context;
reg [3:0]        data_failure_count;
reg              data_failure_event_q;
reg [11:0]       data_failure_fields_q;
wire [3:0] data_failure_count_next=(data_failure_count==4'hF) ? 4'hF : data_failure_count+4'd1;
// D's image field saturates at F for directory ordinal 15 and later.
wire [3:0] data_failure_image=all_images_active ? ((file_ordinal>=16'd14) ? 4'hF : file_ordinal[3:0]+4'd1) : {2'd0,load_idx}+4'd1;
wire [18:0]      sent_pixels_next;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              source_data_seen;
reg              write_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire             attempt_active = load_busy && !load_start_pulse && !load_abort;
// Finite adaptive-image budget: 2^30 cycles (10.737 s at 100 MHz).
// Reuse the existing counter; physical-sector and recovery limits stay unchanged.
wire             watchdog_failure = (BMP_ADAPT_ENABLE ? (|load_timeout_cnt[31:30]) :
                                    (load_timeout_cnt > 32'd300_000_000)) &&
                                    !(source_done_seen && write_done_seen);
wire             attempt_failure = attempt_active && (bmp_load_error || pixel_failure || watchdog_failure);
wire [3:0]       attempt_failure_code = bmp_load_error ? {1'b0, bmp_error} :
                                       pixel_failure ? pixel_failure_code :
                                       {2'b10, source_done_seen, write_done_seen};

wire stream_commit_now = controls_enabled && stream_head_ready && !switch_busy && display_commit_idle &&
                         !load_abort && (!UI078_ENABLE || (!view_locked && session_play_allowed)) &&
                         // A queued complete bank is independent of a failing
                         // background write in another bank. Its legal commit
                         // does not depend on that attempt's wide watchdog path.
                         ((!first_image_committed && stream_initial_ready) ||
                          (first_image_committed && (recovery_state != REC_DRAIN) &&
                           (recovery_state != REC_STOP) && (next_req_pending ||
                            (session_play_allowed && auto_req_pending && auto_play_en && !key_auto_press && !period_adjust_event))));

wire auto_tick;
wire [1:0] next_from_current;

wire             tf_raw_init_done;
wire             tf_raw_read_valid;
wire             tf_raw_read_end;
wire [7:0]       tf_raw_read_data;
// TF-local recovery never resets HDMI, SDRAM, frame ownership or UI clocks.
localparam [2:0] TF_MONITOR=3'd0, TF_RESET=3'd1, TF_REINIT=3'd2,
                 TF_DRAIN=3'd3, TF_STOP=3'd4;
localparam integer TF_CYCLES_PER_MS = (CLK_FREQ_HZ >= 1000) ? CLK_FREQ_HZ/1000 : 1;
localparam integer TF_INIT_CYCLES = (TF_INIT_TIMEOUT_MS > 0) ? TF_CYCLES_PER_MS*TF_INIT_TIMEOUT_MS : 1;
localparam integer TF_SCAN_CYCLES = (TF_SCAN_READ_TIMEOUT_MS > 0) ? TF_CYCLES_PER_MS*TF_SCAN_READ_TIMEOUT_MS : 1;
localparam integer TF_HOLD_CYCLES = (TF_RESET_HOLD_MS > 0) ? TF_CYCLES_PER_MS*TF_RESET_HOLD_MS : 1;
localparam integer TF_DRAIN_CYCLES = (TF_DRAIN_TIMEOUT_MS > 0) ? TF_CYCLES_PER_MS*TF_DRAIN_TIMEOUT_MS : 1;
localparam integer TF_WAIT_MAX0 = (TF_INIT_CYCLES > TF_SCAN_CYCLES) ? TF_INIT_CYCLES : TF_SCAN_CYCLES;
localparam integer TF_WAIT_MAX1 = (TF_HOLD_CYCLES > TF_DRAIN_CYCLES) ? TF_HOLD_CYCLES : TF_DRAIN_CYCLES;
localparam integer TF_WAIT_MAX = (TF_WAIT_MAX0 > TF_WAIT_MAX1) ? TF_WAIT_MAX0 : TF_WAIT_MAX1;
localparam integer TF_WAIT_BITS = (TF_WAIT_MAX > 1) ? $clog2(TF_WAIT_MAX+1) : 1;
localparam integer TF_RETRY_BITS = (TF_MAX_RETRIES > 0) ? $clog2(TF_MAX_RETRIES+1) : 1;
reg [2:0] tf_state;
reg [TF_WAIT_BITS-1:0] tf_wait_count;
reg [TF_RETRY_BITS-1:0] tf_retries;
reg tf_drain_blocked;
reg tf_init_due_q,tf_scan_due_q;
// Public code 2 is shared by SCAN and LOAD_HDR; loading retains its own watchdog.
wire tf_scanning_read = tf_raw_init_done && sd_sec_read && (UI078_ENABLE || ((state_code_i==4'd2) && !load_busy));
wire tf_init_expired = (TF_INIT_TIMEOUT_MS > 0) && !tf_raw_init_done &&
                      (scan_kicked || tf_init_due_q);
wire tf_scan_expired = (TF_SCAN_READ_TIMEOUT_MS > 0) && tf_scanning_read &&
                      !tf_raw_read_end && tf_scan_due_q;
wire tf_fault_event = (tf_state==TF_MONITOR) && (tf_init_expired || tf_scan_expired || file_storage_fault);
wire tf_manual_restart = ((TF_INIT_TIMEOUT_MS > 0) || (TF_SCAN_READ_TIMEOUT_MS > 0)) &&
                         (tf_state==TF_MONITOR) && (recovery_state==REC_STOP) &&
                         recovery_blocked && !drain_ready && (key_next_press || key_auto_press);
wire tf_hold = (tf_state!=TF_MONITOR) || tf_fault_event;
wire tf_card_reset = rst || (tf_state==TF_RESET) || (tf_state==TF_STOP);
// Reset is driven by the registered recovery state, never by a combinational
// timeout which observes the parser's own state (that would erase its cause).
wire tf_parser_reset = rst || (tf_state!=TF_MONITOR);
// Keep the host's reset-dependent settings across a deliberate card reset.
// The parser and supervisor always use the actual card initialization result.
assign sd_init_done = tf_raw_init_done || tf_hold;
// Keep the qualified sector tuple together across one SD clock. The watchdog
// still observes the physical service directly, and write_en rejects a fault
// on its first edge before parser recovery can consume the queued tuple.
reg [9:0] tf_read_tuple_q;
always @(posedge clk or posedge rst) begin
    if (rst) tf_read_tuple_q <= 10'd0;
    else if (tf_hold || !tf_raw_init_done) tf_read_tuple_q <= 10'd0;
    else tf_read_tuple_q <= {tf_raw_read_end, tf_raw_read_valid, tf_raw_read_data};
end
assign sd_sec_read_data = tf_read_tuple_q[7:0];
assign sd_sec_read_data_valid = tf_read_tuple_q[8];
assign sd_sec_read_end = tf_read_tuple_q[9];
// The physical controller returns to WAIT one clock after raw END. Hold its
// request low through the queued END as well, so delayed parser withdrawal
// cannot accidentally launch the same sector again. Live fault isolation stays.
wire tf_physical_read = sd_sec_read && !tf_hold &&
                        !tf_raw_read_end && !sd_sec_read_end;

// Audio metadata follows the physical bank, independently of the two-bit
// scheduling labels. Only an acknowledged display replacement emits a cue.
// Preload, retry and rejected BMPs cannot sound on their own.
reg [2:0] bank_cue0, bank_cue1, bank_cue2, bank_cue3;
wire [2:0] loading_cue_note = all_images_active ? file_ordinal[2:0] : {1'b0, load_idx};
wire cue_commit_accepted = display_commit_done &&
                           (!UI078_ENABLE||!view_transaction||(!thumbnail_layout&&disp_buf_idx!=active_buf_idx)) &&
                           (tf_hold || tf_manual_restart || sd_init_done);
reg [2:0] displayed_cue_note;
always @* begin
    case (disp_buf_idx)
        2'd0: displayed_cue_note = bank_cue0;
        2'd1: displayed_cue_note = bank_cue1;
        2'd2: displayed_cue_note = bank_cue2;
        default: displayed_cue_note = bank_cue3;
    endcase
end
always @(posedge clk or posedge rst) begin
    if (rst) begin
        bank_cue0<=0; bank_cue1<=0; bank_cue2<=0; bank_cue3<=0;
        media_cue_valid<=1'b0; media_cue_note<=0;
    end else begin
        media_cue_valid<=1'b0;
        if (load_start_pulse) begin
            case (write_buf_idx)
                2'd0: bank_cue0<=loading_cue_note;
                2'd1: bank_cue1<=loading_cue_note;
                2'd2: bank_cue2<=loading_cue_note;
                default: bank_cue3<=loading_cue_note;
            endcase
        end
        if (cue_commit_accepted) begin
            media_cue_valid<=1'b1;
            media_cue_note<=displayed_cue_note;
        end
    end
end


// Register wide comparisons one count before expiration. Deadline completion
// still has priority, and timer arithmetic is removed from the parser's path.
always @(posedge clk or posedge rst) begin
    if (rst) begin tf_init_due_q<=1'b0;tf_scan_due_q<=1'b0;end
    else begin
        tf_init_due_q<=((tf_state==TF_MONITOR)||(tf_state==TF_REINIT)) && !tf_raw_init_done &&
                       (tf_wait_count >= ((TF_INIT_CYCLES>1) ? TF_INIT_CYCLES-2 : 0));
        tf_scan_due_q<=(tf_state==TF_MONITOR) && tf_scanning_read && !tf_raw_read_end &&
                       (tf_wait_count >= ((TF_SCAN_CYCLES>1) ? TF_SCAN_CYCLES-2 : 0));
    end
end

// Shared counter times one pending sector, never the full-card scan duration.
// A successful reinitialization or readable scan prefix does not replenish
// the retry budget. Only a finished catalogue ends this discovery round.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        tf_state<=TF_MONITOR; tf_wait_count<=0; tf_retries<=0;
        tf_drain_blocked<=1'b0;
    end else begin
        case (tf_state)
            TF_MONITOR: begin
                if (tf_fault_event || tf_manual_restart) begin
                    tf_wait_count<=0;
                    if (tf_manual_restart) begin
                        tf_state<=TF_RESET; tf_retries<=0; tf_drain_blocked<=1'b0;
                    end else if (tf_retries < TF_MAX_RETRIES) begin
                        tf_state<=TF_RESET; tf_retries<=tf_retries+1'b1;
                    end else tf_state<=TF_STOP;
                end else if (!tf_raw_init_done) begin
                    if (TF_INIT_TIMEOUT_MS > 0) tf_wait_count<=tf_wait_count+1'b1;
                    else tf_wait_count<=0;
                end else if (tf_scanning_read && !tf_raw_read_end) begin
                    if (TF_SCAN_READ_TIMEOUT_MS > 0) tf_wait_count<=tf_wait_count+1'b1;
                    else tf_wait_count<=0;
                end else begin
                    tf_wait_count<=0;
                    // A descriptor page is only a readable prefix, not a completed root walk.
                    if (all_images_active ? (page_done && page_last) : scan_done) tf_retries<=0;
                end
            end
            TF_RESET: begin
                if (tf_wait_count>=TF_HOLD_CYCLES-1) begin tf_state<=TF_REINIT;tf_wait_count<=0;end
                else tf_wait_count<=tf_wait_count+1'b1;
            end
            TF_REINIT: begin
                if (tf_raw_init_done) begin tf_state<=TF_DRAIN;tf_wait_count<=0;end
                else if (tf_init_due_q) begin
                    tf_wait_count<=0;
                    if (tf_retries < TF_MAX_RETRIES) begin tf_state<=TF_RESET;tf_retries<=tf_retries+1'b1;end
                    else tf_state<=TF_STOP;
                end else tf_wait_count<=tf_wait_count+1'b1;
            end
            TF_DRAIN: begin
                // Parser reset drops write_req. Wait for the real writer ACK
                // and display mailbox to drain; never reset those domains here.
                if (!write_req && !wrack_sync[1] && display_commit_idle) begin
                    tf_state<=TF_MONITOR;tf_wait_count<=0;
                end else if (tf_wait_count>=TF_DRAIN_CYCLES-1) begin
                    tf_state<=TF_STOP;tf_wait_count<=0;tf_drain_blocked<=1'b1;
                end else tf_wait_count<=tf_wait_count+1'b1;
            end
            TF_STOP: begin
                tf_wait_count<=0;
                if (key_next_press || key_auto_press) begin
                    tf_state<=TF_RESET;tf_retries<=0;tf_drain_blocked<=1'b0;
                end
            end
            default: begin tf_state<=TF_STOP;tf_wait_count<=0;end
        endcase
    end
end


// Stop the first excess pixel before it reaches the unchanged write FIFO.
assign write_en   = !tf_hold && load_busy && !load_abort && !load_start_pulse && bmp_data_wr_en && pixel_capacity;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
assign auto_timer_active = session_play_allowed && (!FOUR_FRAME_STREAM || warmup_complete) && sd_init_done && scan_kicked && (scan_done || all_images_active) && auto_play_en &&
                           display_valid && first_image_committed && !switch_busy &&
                           (recovery_state != REC_STOP) && !next_req_pending && !auto_req_pending &&
                           (all_images_active || (img_found_count > 3'd1));
// K4 has priority over adjusting the period; simultaneous +/- leaves it unchanged.
assign period_adjust_event = UI078_ENABLE ? (ui_inc||ui_dec) : sd_init_done && first_image_committed && display_valid && auto_play_en &&
                             !key_auto_press &&
                             (key_next_press || key_period_up_press);
assign adjusted_period_seconds = UI078_ENABLE ?
    (ui_inc ? ((period_seconds<30)?period_seconds+5'd1:5'd1) : ((period_seconds>1)?period_seconds-5'd1:period_seconds)) : (key_next_press && key_period_up_press) ? period_seconds :
                                 key_period_up_press ? ((period_seconds < 5'd30) ? period_seconds + 5'd1 : period_seconds) :
                                 ((period_seconds > 5'd1) ? period_seconds - 5'd1 : period_seconds);
// Stop/adjustment has priority over requesting an automatic display switch.
assign auto_tick = auto_timer_active && !key_auto_press && !period_adjust_event &&
                   (auto_cnt == (CLK_FREQ_HZ - 1)) &&
                   (auto_elapsed_s == (period_seconds - 5'd1));
assign next_from_current = next_index_limited(img_idx[1:0], img_found_count);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
// E: no candidate left; F: old source/write acknowledgement did not drain.
// 6=reinitializing TF; 7=TF retry budget exhausted; F=memory/mailbox drain blocked.
// timeout_code E=initialization timeout, F=scan sector timeout. Existing codes retain meaning.
assign state_code = tf_hold ? ((tf_state==TF_STOP) ? (tf_drain_blocked ? 4'hF : 4'd7) : 4'd6) :
                    (recovery_state == REC_STOP) ? (recovery_blocked ? 4'hF : 4'hE) : state_code_i;
assign timeout_code = timeout_diag;
// Four hexadecimal digits represent pixels / 16: 307200 pixels -> 4B00.
// D: left-to-right source, FAT subcode, image slot and saturating event count.
// Other codes use the failed-pixels/16 snapshot.
assign pixel_units = (timeout_diag==ERR_DATA_END) ? data_failure_context :
                     {1'b0, timeout_pixels[18:4]};
assign sent_pixels_next = (load_busy && bmp_data_wr_en && (sent_pixels != 19'h7FFFF))
                          ? (sent_pixels + 19'd1) : sent_pixels;

// Compare the registered count rather than count+1 in the READY path.
// A separate settled-count stage waits past the last pixel pulse, including
// coincidence with source/write completion. Expectations stay fixed per attempt.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        expected_pixels     <= 32'd0;
        pixel_count_exact_q <= 1'b0;
        pixel_count_short_q <= 1'b0;
        source_count_checked <= 1'b0;
    end else if (!sd_init_done || load_abort || !load_busy) begin
        pixel_count_exact_q <= 1'b0;
        pixel_count_short_q <= 1'b0;
        source_count_checked <= 1'b0;
    end else if (load_start_pulse) begin
        expected_pixels <= {16'd0, bmp_width} * {16'd0, bmp_height};
        pixel_count_exact_q <= 1'b0;
        pixel_count_short_q <= 1'b0;
        source_count_checked <= 1'b0;
    end else begin
        pixel_count_exact_q <= ({13'd0, sent_pixels} == expected_pixels);
        pixel_count_short_q <= ({13'd0, sent_pixels} < expected_pixels);
        if (bmp_data_wr_en)
            source_count_checked <= 1'b0;
        else if (source_done_seen)
            source_count_checked <= 1'b1;
    end
end

// Qualify completion with this attempt's actual pixel-transfer phase.
always @(posedge clk or posedge rst) begin
    if (rst)
        source_data_seen <= 1'b0;
    else if (!sd_init_done || load_abort || load_start_pulse || !load_busy)
        source_data_seen <= 1'b0;
    else if (state_code_i == 4'd4)
        source_data_seen <= 1'b1;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sent_pixels    <= 19'd0;
        timeout_pixels <= 19'd0;
    end else if (!sd_init_done) begin
        sent_pixels    <= 19'd0;
        timeout_pixels <= 19'd0;
    end else begin
        if (load_start_pulse)
            sent_pixels <= 19'd0;
        else
            sent_pixels <= sent_pixels_next;

        if (attempt_failure)
            timeout_pixels <= sent_pixels_next;
    end
end


// 107v6: settled-count completion has no live capacity-comparator dependency.
// checked && exact means the current count is unchanged and equals expectation;
// therefore any current pixel pulse is excess. Keep error handling unchanged.
wire bank_ready_clean = attempt_active && source_done_seen && write_done_seen &&
                        source_count_checked && pixel_count_exact_q &&
                        !bmp_load_error && !bmp_load_data_error && !bmp_data_wr_en;
// Preserve last-assignment priority: rescan > whole-mask release > bit updates.
always @(posedge clk or posedge rst) begin
    if (rst) bank_valid <= 4'b0000;
    else if (tf_hold || tf_manual_restart || !sd_init_done)
        bank_valid <= 4'b0000;
    else if (!scan_kicked && bmp_ready && scan_mailbox_idle_q && !switch_busy)
        bank_valid <= 4'b0000;
    else if (display_commit_done && UI078_ENABLE && view_transaction && !thumbnail_layout)
        bank_valid <= bank_valid & ~view_release_mask;
    else begin
        if (FOUR_FRAME_STREAM && bank_ready_clean)
            bank_valid[pending_buf_idx] <= 1'b1;
        if (display_commit_done && !(UI078_ENABLE && view_transaction) &&
            FOUR_FRAME_STREAM && display_valid && (active_buf_idx != disp_buf_idx))
            bank_valid[active_buf_idx] <= 1'b0;
    end
end

// Observe the accepted D event through one pipeline stage. Counting and
// formatting run from that local register, never on the recovery control path.
// Context is sampled alongside the event, before parser cancellation clears it.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        data_failure_event_q<=0; data_failure_fields_q<=0;
        data_failure_context<=0; data_failure_count<=0;
    end else if (!sd_init_done) begin
        data_failure_event_q<=0; data_failure_fields_q<=0;
        data_failure_context<=0; data_failure_count<=0;
    end else begin
        data_failure_event_q<=attempt_active && !bmp_load_error && bmp_load_data_error;
        data_failure_fields_q<={data_failure_image,bmp_load_data_detail[3:0],bmp_load_data_detail[7:4]};
        if (data_failure_event_q) begin
            data_failure_count<=data_failure_count_next;
            data_failure_context<={data_failure_count_next,data_failure_fields_q};
        end
    end
end

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press_raw),
    .released   (key_next_released)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press_raw),
    .released   (key_auto_released)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_period_up (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_period_up),
    .press_pulse(key_period_up_press_raw),
    .released   (key_period_up_released)
);

// handles the three key intents when enabled. The alternate controller stays
// available for standalone configurations.
generate if (UI078_ENABLE) begin : g_ui078
 player_control_078 #(.REMOTE_ENABLE(REMOTE_ENABLE),.IR_ENABLE(IR_ENABLE),.USER_WAKE_ENABLE(USER_WAKE_ENABLE),.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_CYCLES((CLK_FREQ_HZ/20)>0?CLK_FREQ_HZ/20:1)) u_control(
  .clk(clk),.rst(rst),.switches({timer_enable_in,switch3_in,settings_volume_in,settings_mode_in}),
  .remote_valid(remote_valid),.remote_command(remote_command),.remote_argument(remote_argument),
  .ir_valid(ir_valid),.ir_action(ir_action),.ir_playback_event(ir_playback_event),.ir_period_event(ir_period_event),
  .remote_reply(remote_reply),.remote_result(remote_result),
  .music_available(audio_found&&music_count!=0),.music_next_ready(music_next_ready),
  .wake_level(user_wake_level),.k2(key_next_press_raw),.k3(key_period_up_press_raw),.k4(key_auto_press_raw),
  .keys_released(key_next_released&&key_period_up_released&&key_auto_released),
  .k3_held(!key_period_up_released&&key_next_released&&key_auto_released),
  .controls_enable(controls_enabled),.restore_apply(restore_apply),
  .restore_brightness(restore_value_safe[12:9]),.restore_volume(restore_value_safe[8:5]),
  .restore_contrast(restore_value_safe[15:13]),
  .recovery_priority((tf_state==TF_STOP)||(recovery_state==REC_STOP)),
  .auto_play(auto_play_en),.image_visible(display_valid&&first_image_committed&&!switch_busy&&screen_ready),
  .image_changed(display_commit_done&&(active_buf_idx!=disp_buf_idx)),
  .thumb_visible(thumbnail_layout),.view_busy(switch_busy||view_change),.cancel_thumbnail(tf_hold||!sd_init_done),
  .ready_banks(thumbnail_layout?thumbnail_mask:(bank_valid|(display_valid?(4'b0001<<active_buf_idx):4'd0))),.active_bank(active_buf_idx),
  .next_image(key_next_press),.auto_toggle(key_auto_press),.period_inc(ui_inc),.period_dec(ui_dec),
  .thumb_request(ui_thumb_request),.open_request(ui_open),.focus_bank(ui_focus),
  .brightness(brightness_level),.volume(volume_level),.settings_active(settings_active),
  .contrast(contrast_level),.settings_focus(settings_focus),.committed_contrast(ui_saved_contrast),
  .timer_page(session_timer_page),.volume_selected(settings_volume_selected),.minute_selected(ui_minute),.subtract(ui_subtract),
  .manual_tools(ui_manual_tools),.auto_tools(ui_auto_tools),.interval_subtract(ui_interval_subtract),
  .finite_mode(ui_finite),.sleeping(session_expired),.timer_running(session_timer_running),.play_allowed(session_play_allowed),
  .hours(ui_live_hours),.minutes(ui_live_minutes),.seconds(ui_seconds),
  .committed_brightness(ui_saved_brightness),.committed_volume(ui_saved_volume),
  .music_paused(ui_music_paused),.music_next(ui_music_next),.zoom(session_zoom),.rotation(session_rotate),.activity(parameter_activity),.confirmed(ui_confirmed),
  .edit_hours(ui_edit_hours),.edit_minutes(ui_edit_minutes),.edit_finite(ui_edit_finite));
 assign key_period_up_press=0;
 assign session_mode_set=0;assign session_mode_value=0;
 assign session_state=session_expired?2'd3:2'd0;
 assign session_timer_enabled=settings_active?ui_edit_finite:ui_finite;
 assign session_hours=settings_active?ui_edit_hours:ui_live_hours;
 assign session_minutes=settings_active?ui_edit_minutes:ui_live_minutes;
 assign session_selected_auto=auto_play_en;assign session_blink=0;
end else if (SESSION_CONTROL_ENABLE) begin : g_session
    wire [1:0] legacy_zoom;
    assign session_zoom={1'b0,legacy_zoom};
    player_session_control #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(50),
        .CONFIG_RESTORE_ENABLE(CONFIG_RESTORE_ENABLE)) u_control (
        .clk(clk),.rst(rst),.settings_mode_in(settings_mode_in),.settings_volume_in(settings_volume_in),
        .timer_enable_in(timer_enable_in),.next_press(key_next_press_raw),.up_press(key_period_up_press_raw),
        .auto_press(key_auto_press_raw),.next_released(key_next_released),.up_released(key_period_up_released),
        .auto_released(key_auto_released),.controls_enable(controls_enabled),.restore_apply(restore_apply),
        .restore_brightness(restore_value_safe[12:9]),.restore_volume(restore_value_safe[8:5]),
        .recovery_priority((tf_state==TF_STOP)||(recovery_state==REC_STOP)),
        .auto_play(auto_play_en),.image_visible(display_valid && first_image_committed && !switch_busy && screen_ready && !tf_hold && !drain_expired),
        .play_next_press(key_next_press),.play_up_press(key_period_up_press),.play_auto_press(key_auto_press),
        .mode_set(session_mode_set),.mode_value(session_mode_value),.play_allowed(session_play_allowed),
        .brightness_level(brightness_level),.volume_level(volume_level),
        .settings_active(settings_active),.settings_volume_selected(settings_volume_selected),
        .parameter_activity(parameter_activity),.session_state(session_state),.session_expired(session_expired),
        .session_timer_enabled(session_timer_enabled),.session_timer_running(session_timer_running),
        .session_timer_page(session_timer_page),.session_selected_auto(session_selected_auto),
        .session_hours(session_hours),.session_minutes(session_minutes),.session_blink(session_blink),
        .session_zoom(legacy_zoom),.session_rotate(session_rotate)
    );
end else if (USER_SETTINGS_ENABLE) begin : g_user_settings
    player_parameter_control #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(50),
        .CONFIG_RESTORE_ENABLE(CONFIG_RESTORE_ENABLE)) u_control (
        .clk(clk),.rst(rst),.settings_mode_in(settings_mode_in),
        .controls_enable(controls_enabled),.restore_apply(restore_apply),
        .restore_brightness(restore_value_safe[12:9]),.restore_volume(restore_value_safe[8:5]),
        .settings_volume_in(settings_volume_in),
        .next_press(key_next_press_raw),.up_press(key_period_up_press_raw),
        .auto_press(key_auto_press),.next_released(key_next_released),
        .up_released(key_period_up_released),
        .recovery_priority((tf_state==TF_STOP) || (recovery_state==REC_STOP)),
        .play_next_press(key_next_press),.play_up_press(key_period_up_press),
        .brightness_level(brightness_level),.volume_level(volume_level),
        .settings_active(settings_active),
        .settings_volume_selected(settings_volume_selected),
        .parameter_activity(parameter_activity)
    );
end else begin : g_legacy_keys
    // Unconnected new ports in existing standalone fixtures are not consumed.
    assign key_next_press=controls_enabled && key_next_press_raw;
    assign key_period_up_press=controls_enabled && key_period_up_press_raw;
    assign brightness_level=4'd9;
    assign volume_level=4'd9;
    assign settings_active=1'b0;
    assign settings_volume_selected=1'b0;
    assign parameter_activity=1'b0;
end endgenerate
generate if (!UI078_ENABLE) begin : g_no_ir_help
    assign ir_playback_event=1'b0;assign ir_period_event=1'b0;
end endgenerate
generate if (!SESSION_CONTROL_ENABLE && !UI078_ENABLE) begin : g_no_session
    assign key_auto_press=legacy_auto_press;
    assign session_mode_set=1'b0;
    assign session_mode_value=1'b0;
    assign session_play_allowed=1'b1;
    assign session_state=2'd0;
    assign session_expired=1'b0;
    assign session_timer_enabled=1'b0;
    assign session_timer_running=1'b0;
    assign session_timer_page=1'b0;
    assign session_selected_auto=auto_play_en;
    assign session_hours=5'd0;
    assign session_minutes=6'd1;
    assign session_blink=1'b0;
    assign session_zoom=2'd0;
    assign session_rotate=2'd0;
end endgenerate

generate if(!UI078_ENABLE)begin : g_no_ui078
 assign remote_reply=0;assign remote_result=3;
 assign ui_music_paused=0;assign ui_music_next=0;
 assign ui_thumb_request=0;assign ui_open=0;assign ui_inc=0;assign ui_dec=0;assign ui_focus=0;
 assign ui_seconds=0;assign ui_edit_finite=0;assign ui_finite=0;assign ui_minute=0;assign ui_subtract=0;
 assign ui_saved_brightness=0;assign ui_saved_volume=0;
 assign ui_saved_contrast=3'd2;assign contrast_level=3'd2;assign settings_focus=0;
 assign ui_manual_tools=0;assign ui_auto_tools=0;assign ui_interval_subtract=0;assign ui_confirmed=0;
 assign ui_live_hours=0;assign ui_live_minutes=0;assign ui_edit_hours=0;assign ui_edit_minutes=0;
end endgenerate
// Register accepted parameter intent after the same edge that updates its state.
// A fresh bound-limit press still refreshes OSD; restore and rejected keys do not.
always @(posedge clk or posedge rst) begin
    if (rst) osd_parameter_activity <= 1'b0;
    else osd_parameter_activity <= parameter_activity || (!restore_apply && period_adjust_event && !ir_period_event);
end

// Keep a one-second divider plus a bounded seconds counter, not a 30-second
// high-frequency counter or a new clock. The configured period survives stop/start.
always @(posedge clk or posedge rst) begin
    if (rst)
        period_seconds <= DEFAULT_INTERVAL_S;
    else if (restore_apply)
        period_seconds <= restore_value_safe[4:0];
    else if (period_adjust_event)
        period_seconds <= adjusted_period_seconds;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        auto_cnt       <= 0;
        auto_elapsed_s <= 5'd0;
    end else if(UI078_ENABLE&&auto_play_en&&(settings_active||session_expired||view_locked)&&
                 !restore_apply&&!key_auto_press&&!period_adjust_event&&!display_commit_done)begin
        auto_cnt<=auto_cnt;auto_elapsed_s<=auto_elapsed_s;
    end else if (restore_apply || !auto_timer_active || key_auto_press || period_adjust_event ||
                 display_commit_done) begin
        auto_cnt       <= 0;
        auto_elapsed_s <= 5'd0;
    end else if (auto_cnt == (CLK_FREQ_HZ - 1)) begin
        auto_cnt <= 0;
        if (auto_elapsed_s == (period_seconds - 5'd1))
            auto_elapsed_s <= 5'd0;
        else
            auto_elapsed_s <= auto_elapsed_s + 5'd1;
    end else begin
        auto_cnt <= auto_cnt + 1'b1;
    end
end

// Bundled-data mailbox to the 50 MHz digit-display domain. Hold the payload
// unchanged until acknowledgement; if presses overlap a transfer, send latest next.
always @(posedge clk or posedge rst) begin
    if (rst)
        period_ack_sync <= 2'b00;
    else
        period_ack_sync <= {period_ack_sync[0], period_notice_ack};
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        period_notice_seconds <= DEFAULT_INTERVAL_S;
        period_notice_req     <= 1'b0;
        period_notice_pending <= 1'b0;
    end else if (period_adjust_event) begin
        if (period_ack_sync[1] == period_notice_req) begin
            period_notice_seconds <= adjusted_period_seconds;
            period_notice_req     <= ~period_notice_req;
            period_notice_pending <= 1'b0;
        end else begin
            period_notice_pending <= 1'b1;
        end
    end else if (period_notice_pending && (period_ack_sync[1] == period_notice_req)) begin
        period_notice_seconds <= period_seconds;
        period_notice_req     <= ~period_notice_req;
        period_notice_pending <= 1'b0;
    end
end

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] bank_image_lut;
    input [1:0] bank;
    begin
        case (bank)
            2'd0: bank_image_lut=bank_image0;
            2'd1: bank_image_lut=bank_image1;
            2'd2: bank_image_lut=bank_image2;
            default: bank_image_lut=bank_image3;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

// The unchanged writer ACKs a new request only after an old burst ends/cancels.
// Accept completion only after that fresh ACK and a synchronizer flush window.
// An old finish before the ACK (or during abort/drain) cannot finish the next load.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrack_sync <= 2'b00;
        write_finish_guard <= 3'b000;
    end else begin
        wrack_sync <= {wrack_sync[0], write_req_ack};
        if (!sd_init_done || !load_busy || load_abort || load_start_pulse)
            write_finish_guard <= 3'b000;
        else if (write_req && wrack_sync[1])
            write_finish_guard <= 3'b001;
        else
            write_finish_guard <= {write_finish_guard[1:0], write_finish_guard[0]};
    end
end

// Memory acknowledgement is a held toggle, not a pulse crossing clock domains.
always @(posedge clk or posedge rst) begin
    if (rst)
        commit_ack_sync <= 3'b000;
    else
        commit_ack_sync <= {commit_ack_sync[1:0], display_commit_ack};
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        thumbnail_layout<=0;thumbnail_mask<=0;view_transaction<=0;view_release_mask<=0;
        scan_start_pulse      <= 1'b0;
        scan_resume_pulse     <= 1'b0;
        page_next_pulse<=0;page_wait<=0;page_consumed<=0;round_good<=0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        tf_restart_autoplay <= 1'b0;
        auto_play_en          <= 1'b0;
        osd_playback_activity <= 1'b0;
        img_found_count       <= 3'd0;
        img_idx               <= 2'd0;
        load_idx              <= 2'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        active_buf_idx        <= 2'd0;
        display_commit_req    <= 1'b0;
        switch_busy           <= 1'b0;
        prefetch_ready        <= 1'b0;
        prefetch_failed       <= 1'b0;
        auto_req_pending      <= 1'b0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        load_timeout_cnt      <= 32'd0;
        load_abort            <= 1'b0;
        source_done_seen      <= 1'b0;
        write_done_seen       <= 1'b0;
        display_valid         <= 1'b0;
        timeout_diag          <= 4'd0;
        recovery_state        <= REC_IDLE;
        retry_used            <= 1'b0;
        recover_same          <= 1'b0;
        recovery_blocked      <= 1'b0;
        bad_images            <= 4'b0000;
        search_idx            <= 2'd0;
        search_steps          <= 3'd0;
        bank_image0<=0;bank_image1<=0;bank_image2<=0;bank_image3<=0;
        fill_bank_idx<=0;show_bank_idx<=0;fill_img_idx<=0;commit_img_idx<=0;warmup_complete<=0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        scan_resume_pulse <= 1'b0;page_next_pulse<=0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;
        osd_playback_activity <= 1'b0;

        if (tf_hold || tf_manual_restart) begin
            page_wait<=0;page_consumed<=0;round_good<=0;
            // Cancel only pending work. The active buffer and its display-valid
            // flag stay owned by the reader throughout TF reset and rescanning.
            scan_kicked<=1'b0; auto_play_en<=1'b0;
            img_found_count<=0; next_req_pending<=1'b0; auto_req_pending<=1'b0;
            load_busy<=1'b0; load_timeout_cnt<=0; load_abort<=1'b1;
            prefetch_ready<=1'b0;prefetch_failed<=1'b0;
            source_done_seen<=1'b0;write_done_seen<=1'b0;
            recovery_state<=REC_IDLE;retry_used<=1'b0;recover_same<=1'b0;
            recovery_blocked<=1'b0;bad_images<=0;search_steps<=0;
            warmup_complete<=0;fill_img_idx<=0;
            fill_bank_idx<=display_valid ? ((display_commit_done ? disp_buf_idx : active_buf_idx)+2'd1) : 2'd0;
            show_bank_idx<=display_valid ? ((display_commit_done ? disp_buf_idx : active_buf_idx)+2'd1) : 2'd0;
            if (tf_fault_event) begin
                timeout_diag<=tf_init_expired ? 4'hE : 4'hF;
                tf_restart_autoplay<=1'b0;
            end
            if (((tf_state==TF_STOP) || tf_manual_restart) && (key_next_press || key_auto_press)) begin
                tf_restart_autoplay<=key_auto_press;
                osd_playback_activity<=!ir_playback_event;
            end
            if (tf_state==TF_REINIT && !tf_raw_init_done && tf_init_due_q)
                timeout_diag<=4'hE;
            // An already-issued display commit must still be acknowledged.
            if (display_commit_done) begin
                switch_busy<=1'b0;view_transaction<=0;active_buf_idx<=disp_buf_idx;img_idx<=FOUR_FRAME_STREAM ? commit_img_idx : load_idx;
                display_valid<=1'b1;first_image_committed<=1'b1;
            end
        end else if (!sd_init_done) begin
            page_wait<=0;page_consumed<=0;round_good<=0;
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            active_buf_idx        <= 2'd0;
            // Do not reset an in-flight mailbox independently of its receiver.
            // Hold disp_buf_idx and display_commit_req until the receiver ACKs.
            switch_busy           <= 1'b0;
            prefetch_ready        <= 1'b0;
            prefetch_failed       <= 1'b0;
            auto_req_pending      <= 1'b0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            source_done_seen      <= 1'b0;
            write_done_seen       <= 1'b0;
            display_valid         <= 1'b0;
            timeout_diag          <= 4'd0;
        recovery_state        <= REC_IDLE;
        retry_used            <= 1'b0;
        recover_same          <= 1'b0;
        recovery_blocked      <= 1'b0;
        bad_images            <= 4'b0000;
        search_idx            <= 2'd0;
        search_steps          <= 3'd0;
            warmup_complete<=0;fill_bank_idx<=0;show_bank_idx<=0;fill_img_idx<=0;
        end else begin
            if (FOUR_FRAME_STREAM && (&bank_valid)) warmup_complete<=1'b1;
            // Monotonic additions while a thumbnail view owns its slots. Never
            // recycle a displayed cell on a TF recovery; leaving the view releases it.
            if(UI078_ENABLE && thumbnail_layout && !view_transaction && !switch_busy)
                thumbnail_mask<=thumbnail_mask|cached_banks;
            if(page_done && page_wait)begin
                page_wait<=0;page_consumed<=0;retry_used<=0;recovery_state<=REC_IDLE;
            end
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    default: ;
                endcase
                if (img_found_count < 3'd4)
                    img_found_count <= img_found_count + 3'd1;
            end

            if (load_busy && source_data_seen && bmp_ready)
                source_done_seen <= 1'b1;
            if (attempt_active && source_data_seen && write_finish_guard[2] && write_finish_pulse)
                write_done_seen <= 1'b1;

            if (attempt_failure) begin
                timeout_diag     <= attempt_failure_code;
                load_busy        <= 1'b0;
                load_timeout_cnt <= 32'd0;
                source_done_seen <= 1'b0;
                write_done_seen  <= 1'b0;
                prefetch_ready   <= 1'b0;
                prefetch_failed  <= 1'b1;
                load_abort       <= 1'b1;
                recovery_state   <= REC_DRAIN;
                recovery_blocked <= 1'b0;
                if (!retry_used) begin
                    retry_used   <= 1'b1;
                    recover_same <= 1'b1;
                end else begin
                    if(all_images_active)page_consumed<=1;
                    else bad_images[load_idx[1:0]] <= 1'b1;
                    recover_same <= 1'b0;
                    search_idx   <= next_index_limited(load_idx[1:0], img_found_count);
                    search_steps <= 3'd0;
                end
            end else if (attempt_active && source_done_seen && write_done_seen &&
                         source_count_checked && pixel_count_exact_q) begin
                // Exact, settled pixel count + clean source + memory completion grant READY.
                load_busy        <= 1'b0;
                load_timeout_cnt <= 32'd0;
                source_done_seen <= 1'b0;
                write_done_seen  <= 1'b0;
                prefetch_ready   <= FOUR_FRAME_STREAM ? 1'b0 : 1'b1;
                prefetch_failed  <= 1'b0;
                if (FOUR_FRAME_STREAM) begin
                    if(all_images_active)begin page_consumed<=1;round_good<=1;end

                    case (pending_buf_idx)
                        2'd0:bank_image0<=load_idx;
                        2'd1:bank_image1<=load_idx;
                        2'd2:bank_image2<=load_idx;
                        2'd3:bank_image3<=load_idx;
                    endcase
                    fill_bank_idx<=pending_buf_idx+2'd1;
                    fill_img_idx<=next_index_limited(load_idx[1:0],img_found_count);
                end
            end else if (load_busy) begin
                load_timeout_cnt <= load_timeout_cnt + 32'd1;
            end else if ((recovery_state == REC_DRAIN) && !load_abort) begin
                if (drain_ready) begin
                    recovery_state <= recover_same ? REC_RETRY : REC_NEXT;
                    load_timeout_cnt <= 32'd0;
                end else if (load_timeout_cnt > 32'd300_000_000) begin
                    // No bottom-level cancel interface: stop without overlapping SD reads.
                    recovery_state   <= REC_STOP;
                    recovery_blocked <= 1'b1;
                    auto_play_en     <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_req_pending <= 1'b0;
                end else
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
            end else
                load_timeout_cnt <= 32'd0;

            // This ACK follows the reader selecting a complete new frame and,
            // when enabled, its first nonzero transition frame boundary.
            if (display_commit_done) begin
                switch_busy           <= 1'b0;
                active_buf_idx        <= disp_buf_idx;
                img_idx               <= FOUR_FRAME_STREAM ? commit_img_idx : load_idx;
                if(UI078_ENABLE&&view_transaction)begin
                    view_transaction<=0;
                    if(!thumbnail_layout)begin

                        show_bank_idx<=disp_buf_idx+2'd1;
                        // Preserve the next free write position when leaving a partial snapshot.
                        // Completed queued banks must not become the next write target.
                    end
                end
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
                if (tf_restart_autoplay) begin
                    auto_play_en<=1'b1;tf_restart_autoplay<=1'b0;
                end
            end

            // A longer visible transaction keeps its target bank held through TF recovery.
            if (!scan_kicked && bmp_ready && scan_mailbox_idle_q && !switch_busy) begin
                page_wait<=0;page_consumed<=0;round_good<=0;
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                img_found_count       <= 3'd0;
                // A recovery scan starts a fresh catalogue but retains a visible
                // old frame until a complete replacement commits at a frame boundary.
                if (!display_valid) img_idx <= 2'd0;
                load_idx              <= 2'd0;
                pending_buf_idx       <= 2'd0;
                if (!display_valid) begin
                    write_buf_idx<=2'd0;active_buf_idx<=2'd0;
                end
                next_req_pending      <= 1'b0;
                auto_req_pending      <= 1'b0;
                prefetch_ready        <= 1'b0;
                prefetch_failed       <= 1'b0;
                switch_busy           <= 1'b0;
                // display_valid and active_buf_idx are preserved on recovery.
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                recovery_state        <= REC_IDLE;
                retry_used            <= 1'b0;
                recover_same          <= 1'b0;
                recovery_blocked      <= 1'b0;
                bad_images            <= 4'b0000;
                search_idx            <= 2'd0;
                search_steps          <= 3'd0;
                warmup_complete<=0;fill_img_idx<=0;
                fill_bank_idx<=display_valid ? active_buf_idx+2'd1 : 2'd0;
                show_bank_idx<=display_valid ? active_buf_idx+2'd1 : 2'd0;
            end else begin
                // Preserve one queued manual NEXT even when prefetch is busy.
                if (!drain_expired && key_next_press && !auto_play_en && !key_auto_press &&
                    first_image_committed && (all_images_active || (img_found_count > 3'd0))) begin
                    next_req_pending <= 1'b1;
                    osd_playback_activity <= !ir_playback_event;
                end

                // Settings are available as soon as a complete first frame is visible.
                // Actual automatic switching still waits for the discovered catalogue.
                if (!drain_expired && session_mode_set) begin
                    auto_play_en<=session_mode_value;
                    auto_req_pending<=1'b0;
                    osd_playback_activity<=1'b1;
                end else if (!drain_expired && key_auto_press && (first_image_committed || recovery_restart) &&
                    (all_images_active || (img_found_count > 3'd0)) &&
                    ((recovery_state != REC_STOP) || recovery_restart)) begin
                    auto_play_en     <= ~auto_play_en;
                    auto_req_pending <= 1'b0;
                    osd_playback_activity <= !ir_playback_event;
                end else if (period_adjust_event)
                    auto_req_pending <= 1'b0;
                else if (!drain_expired && auto_tick)
                    auto_req_pending <= 1'b1;

                if (recovery_restart) begin
                    // The stopped cursor is at end-of-directory; allow one fresh walk.
                    if(all_images_active)begin page_consumed<=1;round_good<=1;page_wait<=0;end
                    bad_images       <= 4'b0000;
                    retry_used       <= 1'b0;
                    recover_same     <= 1'b0;
                    recovery_blocked <= 1'b0;
                    search_idx       <= FOUR_FRAME_STREAM ? fill_img_idx :
                                        (first_image_committed ? next_from_current : 2'd0);
                    search_steps     <= 3'd0;
                    load_timeout_cnt <= 32'd0;
                    recovery_state   <= REC_DRAIN;
                end

                if (FOUR_FRAME_STREAM) begin
                    if(view_change_ready && !switch_busy && display_commit_idle && !load_busy && !load_abort &&
                       display_valid && !recovery_restart)begin
                        thumbnail_layout<=ui_thumb_request;
                        if(ui_thumb_request)begin
                            thumbnail_mask<=bank_valid|(4'b0001<<active_buf_idx);
                            disp_buf_idx<=active_buf_idx;commit_img_idx<=img_idx;view_release_mask<=0;
                        end else begin
                            disp_buf_idx<=ui_focus;commit_img_idx<=bank_image_lut(ui_focus);
                            view_release_mask<=preceding_mask(active_buf_idx,ui_focus);
                        end
                        view_transaction<=1;display_commit_req<=~display_commit_req;switch_busy<=1;
                        next_req_pending<=0;auto_req_pending<=0;
                    end else if (stream_commit_now && !recovery_restart) begin
                        disp_buf_idx<=show_bank_idx;
                        commit_img_idx<=bank_image_lut(show_bank_idx);
                        display_commit_req<=~display_commit_req;
                        switch_busy<=1'b1;
                        show_bank_idx<=show_bank_idx+2'd1;
                        next_req_pending<=1'b0;auto_req_pending<=1'b0;
                    end else if (!load_abort && !attempt_failure && !load_busy &&
                                 !switch_busy && display_commit_idle && bmp_ready &&
                                 !scan_start_pulse && !scan_resume_pulse && scan_done &&
                                 !recovery_restart && stream_bank_free && !view_change_ready &&
                                 (!view_locked || (ui_thumb_request && !view_transaction && !view_change))) begin
                        if(all_images_active)begin
                            if(!page_wait && (recovery_state!=REC_STOP) && (recovery_state!=REC_DRAIN))begin
                                if(page_consumed || img_found_count==0)begin
                                    if(page_last && !round_good)begin
                                        recovery_state<=REC_STOP;recovery_blocked<=0;auto_play_en<=0;
                                        next_req_pending<=0;auto_req_pending<=0;
                                    end else begin
                                        page_next_pulse<=1;page_wait<=1;img_found_count<=0;
                                        page_consumed<=0;retry_used<=0;bad_images<=0;
                                        recovery_state<=REC_PAGE;
                                        if(page_last)round_good<=0;
                                    end
                                end else if((recovery_state==REC_IDLE)||(recovery_state==REC_NEXT)||(recovery_state==REC_RETRY))begin
                                    // Metadata slot zero contains the next cursor result;
                                    // Full identity remains in file_ordinal; the control label is modulo four.
                                    load_idx<=file_ordinal[1:0];load_sector<=0;
                                    pending_buf_idx<=fill_bank_idx;write_buf_idx<=fill_bank_idx;
                                    load_start_pulse<=1;load_busy<=1;
                                    source_done_seen<=0;write_done_seen<=0;prefetch_failed<=0;
                                    recovery_state<=REC_IDLE;
                                end
                            end
                        end else if ((recovery_state==REC_RETRY) ||
                            ((recovery_state==REC_NEXT) && search_eligible)) begin
                            if (recovery_state==REC_NEXT) begin
                                load_idx<=search_idx;load_sector<=sector_lut(search_idx);retry_used<=1'b0;
                            end
                            pending_buf_idx<=fill_bank_idx;write_buf_idx<=fill_bank_idx;
                            load_start_pulse<=1'b1;load_busy<=1'b1;
                            source_done_seen<=1'b0;write_done_seen<=1'b0;prefetch_failed<=1'b0;
                            recovery_state<=REC_IDLE;
                        end else if (recovery_state==REC_NEXT) begin
                            if (search_steps==3'd3) begin
                                recovery_state<=REC_STOP;recovery_blocked<=1'b0;auto_play_en<=1'b0;
                                next_req_pending<=1'b0;auto_req_pending<=1'b0;
                            end else begin
                                search_idx<=next_index_limited(search_idx,img_found_count);
                                search_steps<=search_steps+3'd1;
                            end
                        end else if (recovery_state==REC_IDLE) begin
                            if (img_found_count!=0) begin
                                search_idx<=fill_img_idx;search_steps<=0;recovery_state<=REC_NEXT;
                            end else begin
                                recovery_state<=REC_STOP;recovery_blocked<=1'b0;auto_play_en<=1'b0;
                            end
                        end
                    end
                end else begin
                // The first READY frame shows automatically. Subsequent READY
                // frames wait for a manual request or an uncancelled deadline.
                if (controls_enabled && prefetch_ready && !load_busy && !switch_busy && display_commit_idle &&
                    (recovery_state == REC_IDLE) && !load_abort &&
                    (!first_image_committed || next_req_pending ||
                     (session_play_allowed && auto_req_pending && auto_play_en && !key_auto_press && !period_adjust_event))) begin
                    disp_buf_idx       <= pending_buf_idx;
                    display_commit_req <= ~display_commit_req;
                    switch_busy        <= 1'b1;
                    prefetch_ready     <= 1'b0;
                    next_req_pending   <= 1'b0;
                    auto_req_pending   <= 1'b0;
                end
                else if (!load_abort && !attempt_failure && !load_busy && !prefetch_ready &&
                         !switch_busy && display_commit_idle && bmp_ready &&
                         !scan_start_pulse && !scan_resume_pulse &&
                         (scan_done || scan_paused)) begin
                    if (scan_paused && first_image_committed && (recovery_state == REC_IDLE)) begin
                        // Publish the first complete frame before further discovery.
                        // Finish the catalogue before starting normal background prefetch.
                        scan_resume_pulse <= 1'b1;
                    end else if ((recovery_state == REC_RETRY) ||
                        ((recovery_state == REC_NEXT) && search_eligible)) begin
                        // Fresh resource clears its budget; a retry retains the used bit.
                        if (recovery_state == REC_NEXT) begin
                            load_idx    <= search_idx;
                            load_sector <= sector_lut(search_idx);
                            retry_used  <= 1'b0;
                        end
                        pending_buf_idx  <= next_buf_lut(active_buf_idx, display_valid);
                        write_buf_idx    <= next_buf_lut(active_buf_idx, display_valid);
                        load_start_pulse <= 1'b1;
                        load_busy        <= 1'b1;
                        source_done_seen <= 1'b0;
                        write_done_seen  <= 1'b0;
                        prefetch_failed  <= 1'b0;
                        recovery_state  <= REC_IDLE;
                    end else if (recovery_state == REC_NEXT) begin
                        if (search_steps == 3'd3) begin
                            if (scan_paused) begin
                                // Exhausted discovered entries do not exhaust the SD scan.
                                // Keep their blacklist and find the next candidate to try.
                                scan_resume_pulse <= 1'b1;
                                recovery_state    <= REC_IDLE;
                            end else begin
                                recovery_state   <= REC_STOP;
                                recovery_blocked <= 1'b0;
                                auto_play_en     <= 1'b0;
                                next_req_pending <= 1'b0;
                                auto_req_pending <= 1'b0;
                            end
                        end else begin
                            search_idx   <= next_index_limited(search_idx, img_found_count);
                            search_steps <= search_steps + 3'd1;
                        end
                    end else if ((recovery_state == REC_IDLE) && bmp_ready &&
                                 (img_found_count != 3'd0) &&
                                 (!first_image_committed || (display_valid &&
                                  ((img_found_count > 3'd1) || next_req_pending)))) begin
                        // One candidate per clock avoids a long four-way search path.
                        search_idx     <= first_image_committed ? next_from_current : 2'd0;
                        search_steps   <= 3'd0;
                        recovery_state <= REC_NEXT;
                    end
                end
                end
            end
        end
    end
end


media_file_bmp_reader #(.BMP_ADAPT_ENABLE(BMP_ADAPT_ENABLE),.AUDIO_ENABLE(UI078_ENABLE),.REQUEST_TIMEOUT_CYCLES(TF_SCAN_CYCLES),.TARGET_FILES(SCAN_TARGET_COUNT),.STREAM_PAGES(FOUR_FRAME_STREAM && ALL_ROOT_IMAGES)) bmp_read_m0(
    .storage_fault(file_storage_fault),
    .music_index(music_index),.music_count(music_count),.music_volume_end(music_volume_end),.music_found(music_found),.music_cluster(music_cluster),.music_size(music_size),
    .music_data_lba(music_data_lba),.music_fat_lba(music_fat_lba),.music_cluster_count(music_clusters),.music_spc(music_spc),
    .clk                    (clk),
    .rst                    (tf_parser_reset),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_pause_after_found (FOUR_FRAME_STREAM ? 1'b0 : !first_image_committed),
    .scan_resume            (scan_resume_pulse),
    .scan_next              (page_next_pulse),
    .page_done              (page_done),
    .page_last              (page_last),
    .all_images_active      (all_images_active),
    .file_ordinal           (file_ordinal),
    .scan_paused            (scan_paused),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),
    .load_error             (bmp_load_error),
    .load_data_error        (bmp_load_data_error),
    .load_data_detail       (bmp_load_data_detail),
    .bmp_error              (bmp_error),

    .sd_init_done           (tf_raw_init_done),
    .state_code             (state_code_i),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (bmp_sector_req),
    .sd_sec_read_addr       (bmp_sector_lba),
    .sd_sec_read_data       (sd_sec_read_data),
    .sector_active          (bmp_sector_active),
    .sd_sec_read_data_valid (bmp_sector_valid),
    .sd_sec_read_end        (bmp_sector_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);

generate if(UI078_ENABLE)begin:g_music
 music_file_078 #(.VALIDATED_GEOMETRY(1),.REQUEST_TIMEOUT_CYCLES(TF_SCAN_CYCLES)) player(
  .clk(clk),.rst(tf_parser_reset),.storage_ready(tf_raw_init_done&&!tf_hold),.music_found(music_found),.next_track(ui_music_next),.audio_owner(music_owner),.track_count(music_count),.track_index(music_index),.next_ready(music_next_ready),
  .validated_data_end(music_volume_end),.first_cluster(music_cluster),.size_bytes(music_size),.data_lba(music_data_lba),.fat_lba(music_fat_lba),
  .cluster_count(music_clusters),.sectors_per_cluster(music_spc),
  .sector_req(music_sector_req),.sector_lba(music_sector_lba),.sector_byte(sd_sec_read_data),
  .sector_valid(music_valid),.sector_end(music_end),.urgent(music_urgent),
  .audio_clk(audio_clk),.audio_reset(audio_reset),.pcm_read(audio_read),.pcm_data(audio_pcm),
  .pcm_valid(audio_pcm_valid),.pcm_empty(audio_empty),.pcm_level(audio_level),.error(audio_error),.format_ok(audio_format_ok));
 audio_sector_arbiter_078 arbiter(.clk(clk),.rst(tf_parser_reset),.storage_ready(tf_raw_init_done&&!tf_hold),
  .bmp_req(bmp_sector_req),.bmp_lba(bmp_sector_lba),.audio_req(music_sector_req),.audio_lba(music_sector_lba),.audio_urgent(music_urgent),
  .physical_req(sd_sec_read),.physical_lba(sd_sec_read_addr),.physical_valid(sd_sec_read_data_valid),.physical_end(sd_sec_read_end),
  .bmp_valid(bmp_sector_valid),.bmp_end(bmp_sector_end),.audio_valid(music_valid),.audio_end(music_end),.audio_owner(music_owner),.bmp_active(bmp_sector_active));
end else begin:g_no_music
 assign sd_sec_read=bmp_sector_req;assign sd_sec_read_addr=bmp_sector_lba;
 assign bmp_sector_active=tf_physical_read;
 assign bmp_sector_valid=sd_sec_read_data_valid;assign bmp_sector_end=sd_sec_read_end;
 assign music_next_ready=0;
 assign music_index=0;assign music_owner=0;assign music_valid=0;assign music_end=0;assign music_sector_req=0;assign music_sector_lba=0;assign music_urgent=0;
 assign audio_pcm=0;assign audio_pcm_valid=0;assign audio_empty=1;assign audio_level=0;assign audio_error=0;assign audio_format_ok=0;
end endgenerate

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (tf_card_reset),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (tf_raw_init_done),
    .sd_sec_read            (tf_physical_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (tf_raw_read_data),
    .sd_sec_read_data_valid (tf_raw_read_valid),
    .sd_sec_read_end        (tf_raw_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (8'd0),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse,
    output wire released
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;
// A pending press/release transition is not a stable release.
assign released=button_stable && button_sync1 && (cnt==32'd0);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule


// Only controls parameter intent; pixel/audio domains apply the held levels
// through their own mailboxes. No generated clock or storage reset is involved.
module player_parameter_control #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer DEBOUNCE_MS=50,
    parameter integer CONFIG_RESTORE_ENABLE=0
)(
    input wire clk,rst,
    input wire settings_mode_in,settings_volume_in,
    input wire next_press,up_press,auto_press,
    input wire next_released,up_released,recovery_priority,
    input wire controls_enable,restore_apply,
    input wire [3:0] restore_brightness,restore_volume,
    output wire play_next_press,play_up_press,
    output reg [3:0] brightness_level,volume_level,
    output wire settings_active,settings_volume_selected,
    output wire parameter_activity
);
localparam integer CYCLES_PER_MS=(CLK_FREQ_HZ>=1000) ? CLK_FREQ_HZ/1000 : 1;
localparam integer STABLE_CYCLES=(DEBOUNCE_MS>0) ? CYCLES_PER_MS*DEBOUNCE_MS : 1;
localparam integer COUNT_BITS=(STABLE_CYCLES>1) ? $clog2(STABLE_CYCLES+1) : 1;
reg [1:0] switch_sync0,switch_sync1;
reg [1:0] switch_observed,switch_stable;
reg [COUNT_BITS-1:0] stable_count;
reg switch_ready,keys_armed,recovery_observed;
wire switch_changed=(switch_sync1!=switch_observed);
wire recovery_changed=(recovery_priority!=recovery_observed);
wire parameter_controls_enabled=!CONFIG_RESTORE_ENABLE || controls_enable;
wire accept_press=parameter_controls_enabled && switch_ready && keys_armed && !switch_changed && !recovery_changed;
wire set_decrease=next_press && !up_press && up_released;
wire set_increase=up_press && !next_press && next_released;
assign settings_active=switch_stable[1];
assign settings_volume_selected=switch_stable[0];
assign parameter_activity=accept_press && settings_active && !auto_press && !recovery_priority &&
                          !(CONFIG_RESTORE_ENABLE && restore_apply) && (set_decrease || set_increase);
assign play_next_press=accept_press && next_press && !auto_press &&
                       (!settings_active || recovery_priority);
assign play_up_press=accept_press && up_press && !settings_active;
always @(posedge clk or posedge rst) begin
    if(rst) begin switch_sync0<=0;switch_sync1<=0;end
    else begin
        switch_sync0<={settings_mode_in,settings_volume_in};
        switch_sync1<=switch_sync0;
    end
end
// Entering or leaving STOP also requires release before a new K2/K3 event.
// An old press still awaiting debounce must not automatically recover a fault.
always @(posedge clk or posedge rst) begin
    if(rst)recovery_observed<=0;
    else recovery_observed<=recovery_priority;
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        switch_observed<=0;switch_stable<=0;stable_count<=0;
        switch_ready<=0;keys_armed<=0;
    end else if(switch_changed) begin
        switch_observed<=switch_sync1;stable_count<=0;
        switch_ready<=0;keys_armed<=0;
    end else if(!switch_ready) begin
        keys_armed<=0;
        if(stable_count>=STABLE_CYCLES-1) begin
            switch_stable<=switch_observed;switch_ready<=1;
        end else stable_count<=stable_count+1'b1;
    end else if(!parameter_controls_enabled || recovery_changed) begin
        keys_armed<=0;
    end else if(!keys_armed && next_released && up_released) begin
        keys_armed<=1;
    end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin brightness_level<=4'd9;volume_level<=4'd9;end
    else if(CONFIG_RESTORE_ENABLE && restore_apply) begin
        brightness_level<=restore_brightness;volume_level<=restore_volume;
    end else if(accept_press && settings_active && !auto_press && !recovery_priority) begin
        if(settings_volume_selected) begin
            if(set_decrease && volume_level>4'd0)volume_level<=volume_level-1'b1;
            else if(set_increase && volume_level<4'd9)volume_level<=volume_level+1'b1;
        end else begin
            if(set_decrease && brightness_level>4'd1)brightness_level<=brightness_level-1'b1;
            else if(set_increase && brightness_level<4'd9)brightness_level<=brightness_level+1'b1;
        end
    end
end
endmodule
