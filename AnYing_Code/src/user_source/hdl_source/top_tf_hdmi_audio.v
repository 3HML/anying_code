
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // Board K2: next (manual), -1s (auto)
    input                       key2,           // Board K4: autoplay on/off
    input                       key3,           // Board K3: +1s (auto only)
    input                       sw1,            // Board SW1: 0 playback, 1 settings
    input                       sw2,            // Board SW2: context selection
    input                       sw3,
    input                       sw4,            // Board SW4/C5: 0 unlimited, 1 timed

	output [7:0]                seg_sel,
	output [7:0]                seg_data,
    output reg [3:0] cache_led,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso,

    // Independent U33 user Flash; the U39 FPGA configuration Flash is untouched.
    output                      user_flash_cs_n,
    output                      user_flash_sck,
    output                      user_flash_mosi,
    input                       user_flash_miso,
    output                      user_flash_wp_n,
    output                      user_flash_hold_n,
    input                       uart_rx,
    input                       ir_rx, // J1 pin1 GPIOA_0/D14;3.3V receiver only
    output                      uart_tx
);

parameter TRANSITION_ENABLE = 1;
parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;
parameter BUF2_ADDR     = FRAME_PIXELS * 2;
parameter BUF3_ADDR     = FRAME_PIXELS * 3;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

// Independent HDMI audio signals; existing image clocks are unchanged.
wire audio_mclk, audio_pll_lock;
wire media_cue_valid;
wire [2:0] media_cue_note;
wire audio_valid, acr_valid;
wire [23:0] audio_left_data, audio_right_data;
wire [19:0] acr_cts, acr_n;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [24:0] vout_picture;
assign vout_data_raw=vout_picture[24:1];
wire contrast_hs,contrast_vs,contrast_de;
wire [23:0] contrast_rgb;
wire [23:0] vout_data;
wire        display_valid;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;
wire [3:0]  timeout_code;
wire [15:0] pixel_units;
wire [3:0] state_digits;
wire indicator_sleep;
wire [3:0] cached_banks;
wire [2:0] cached_count={2'd0,cached_banks[0]}+{2'd0,cached_banks[1]}+
                       {2'd0,cached_banks[2]}+{2'd0,cached_banks[3]};
wire [6:0]  seg_timeout;
wire [6:0]  seg_pixels_0, seg_pixels_1, seg_pixels_2, seg_pixels_3;
wire [4:0]  period_notice_seconds;
wire        period_notice_req, period_notice_ack;
wire        period_show;
wire [3:0]  period_tens, period_ones;
wire [6:0]  seg_period_tens, seg_period_ones;
wire [3:0]  brightness_level, volume_level;
wire [3:0] committed_brightness,committed_volume;
wire [2:0] contrast_level,committed_contrast,settings_focus;
wire [4:0]  current_interval_s;
wire        config_restore_valid, config_restore_ack, config_ready;
wire [15:0] config_restore_value;
wire        flash_init_done, flash_available, flash_cmd_busy, flash_cmd_done;
wire [23:0] flash_jedec, flash_addr;
wire        flash_cmd_start, flash_read_valid, config_store_ready, config_save_busy, config_dirty;
wire [1:0]  flash_cmd;
wire [12:0] flash_length, flash_read_index;
wire [7:0]  flash_write_data, flash_read_data, flash_write_index;
wire [3:0]  flash_cmd_error, config_store_error, flash_status_digits;
assign user_flash_wp_n=1'b1;
assign user_flash_hold_n=1'b1;
wire        settings_active, settings_volume_selected;
wire [9:0]  config_display;
wire [3:0]  brightness_video_level;
wire [6:0]  seg_brightness, seg_volume;
wire        brightness_hs, brightness_vs, brightness_de;
wire [23:0] brightness_rgb;
wire        osd_auto_play, osd_activity;
wire [16:0] osd_state_video;
wire        osd_activity_video;
wire        osd_hs, osd_vs, osd_de;
wire [23:0] osd_rgb;
// session tuple is transported atomically to each consumer clock domain.
wire audio_file_read,audio_file_valid,audio_file_empty,audio_file_found,audio_file_format;
wire [15:0] audio_file_data;
wire [11:0] audio_file_level;
wire [3:0] audio_file_error;
wire thumbnail_layout;
wire [3:0] thumbnail_mask;
wire [1:0] thumbnail_focus;
wire [5:0] ui_seconds;
wire [7:0] ui_flags;
wire [4:0] music_index;
wire [5:0] music_count;
wire [4:0] read_view_mem;
wire [1:0] session_state,session_rotate;
wire [2:0] session_zoom;
wire session_expired,session_timer_enabled,session_timer_running;
wire session_timer_page,session_selected_auto,session_blink;
wire [4:0] session_hours;
wire [5:0] session_minutes;
wire [21:0] session_tuple={session_state,session_timer_enabled,session_timer_running,
    session_timer_page,session_selected_auto,session_hours,session_minutes,
    session_blink,session_zoom[1:0],session_rotate};
// Blink/running are digit-only fields. Transport the 20 displayed session
// bits together with all 17 existing OSD bits under ONE request/ACK token.
wire [36:0] osd_state_all;
wire [80:0] osd_bundle_video;
assign osd_state_all=osd_bundle_video[36:0];
wire [21:0] session_video={osd_state_all[36:34],1'b0,osd_state_all[33:21],1'b0,osd_state_all[20:17]};
assign osd_state_video=osd_state_all[16:0];
wire [18:0] session_digits;
wire [4:0] transform_mem;
wire [8:0] transform_and_mask_mem;
wire [3:0] thumbnail_mask_mem;
reg [4:0] transform_frame;
wire session_black=(session_video[21:20]==2'd3);
// park the display reader at a frame boundary; reveal only a re-primed frame.
wire video_read_active,video_resume_black;
wire [23:0] session_rgb=(session_black || video_resume_black) ? 24'd0 : osd_rgb;
wire [15:0] audio_meter_sample;
wire [23:0] session_meter_pcm=session_black ? 24'd0 : {audio_meter_sample,8'd0};
wire [23:0] session_audio_left=session_black ? 24'd0 : audio_left_data;
wire [23:0] session_audio_right=session_black ? 24'd0 : audio_right_data;
wire [7:0] timer_digit0,timer_digit1,timer_digit2,timer_digit3,timer_digit4;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire        frame_read_req_mem, frame_read_ack_mem;
wire        video_read_ack_mem;
reg [1:0]   video_read_ack_sync;
reg [1:0]   display_valid_sync;
wire [1:0]  read_buf_idx_mem;
wire        display_commit_req, display_commit_ack;
wire        transition_reader_req, transition_reader_ack;
wire [4:0]  transition_gain;
wire        transition_rst;
wire        transition_hs, transition_vs, transition_de;
wire [23:0] transition_rgb;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 相关
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 链路
wire sys_pll_lock;
wire video_pll_lock;
wire rst_all;
wire rst_mem_source;

wire pll_reset;
wire user_reset_n,user_wake_level;
player_reset_wake_080 u_user_reset(
    .clk(clk),.key_n(rst_n),.sleeping(session_expired),
    .reset_n(user_reset_n),.wake_level(user_wake_level),
    .sleep_state(indicator_sleep)
);
clock_startup_supervisor u_clock_startup (
    .I_clk(clk), .I_rst_n(user_reset_n),
    .I_sys_lock(sys_pll_lock), .I_video_lock(video_pll_lock),
    .O_pll_reset(pll_reset), .O_rst(rst_all), .O_rst_mem(rst_mem_source)
);

// Each consumer clock domain releases its reset on its own clock edges.
// Ordered reference-domain reset; audio has an independent reset.
(* async_reg = "true" *) reg [2:0] rst_sd_sync = 3'b111;
(* async_reg = "true" *) reg [2:0] rst_video_sync = 3'b111;
wire rst_sd = rst_sd_sync[2];
wire rst_video = rst_video_sync[2];
// Board LED1..4 are active high (A4/A3/C10/B12). Register the thermometer code.
always @(posedge sd_card_clk or posedge rst_sd) begin
    if(rst_sd) cache_led<=0;
    else if(session_expired) cache_led<=0;
    else case(cached_count)
        0:cache_led<=4'b0000;1:cache_led<=4'b0001;2:cache_led<=4'b0011;
        3:cache_led<=4'b0111;default:cache_led<=4'b1111;
    endcase
end

always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) rst_sd_sync <= 3'b111;
    else rst_sd_sync <= {rst_sd_sync[1:0], 1'b0};
end
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) rst_video_sync <= 3'b111;
    else rst_video_sync <= {rst_video_sync[1:0], 1'b0};
end

// Memory control, frame arbitration and SDRAM share this existing release chain.
(* async_reg = "true" *) reg [2:0] rst_sdram_sync;
wire      rst_sdram;
always @(posedge ext_mem_clk or posedge rst_mem_source) begin
    if (rst_mem_source)
        rst_sdram_sync <= 3'b111;
    else
        rst_sdram_sync <= {rst_sdram_sync[1:0], 1'b0};
end
assign rst_sdram = rst_sdram_sync[2];

// the open controller returns read-valid and data on the same cycle.
// TF、SDRAM和视频各时钟域接口。
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (pll_reset),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (pll_reset),
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_sdram) begin
    if (rst_sdram)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// Lightweight query/control link; all application fields are in sd_card_clk.
wire remote_valid,remote_reply;
wire [7:0] remote_command,remote_argument;
wire [2:0] remote_result;
wire [4:0] remote_hours;
wire [5:0] remote_minutes;
wire [79:0] remote_status_normal={
    8'd113,{config_store_error,audio_file_error},
    {timeout_code,state_code},{2'd0,ui_seconds},
    {current_interval_s[4:3],remote_minutes},{current_interval_s[2:0],remote_hours},
    {2'd0,contrast_level[2],music_index},{contrast_level[1:0],music_count},
    {brightness_level,volume_level},
    {!ui_flags[3],config_ready,display_valid,thumbnail_layout,ui_flags[0],session_expired,settings_active,osd_auto_play}
};
// Query command0/argument1 returns diagnostic data without
// changing command0/argument0 or any existing control packet/response length.
wire ir_valid;
wire [3:0] ir_action;
wire [7:0] ir_last_command,ir_frame_count;
ir_nec_remote_100 u_ir_remote(.clk(sd_card_clk),.rst(rst_sd),.ir_rx(ir_rx),
    .action_valid(ir_valid),.action(ir_action),.last_command(ir_last_command),.frame_count(ir_frame_count));
wire [79:0] remote_status=(remote_command==0 && remote_argument==1) ?
    {8'd100,24'd0,ir_frame_count,ir_last_command,{4'd0,cached_banks},{timeout_code,state_code},pixel_units} : remote_status_normal;
uart_control_link_093 u_uart_control(
    .clk(sd_card_clk),.rst(rst_sd),.rx(uart_rx),.tx(uart_tx),
    .command_valid(remote_valid),.command(remote_command),.argument(remote_argument),
    .reply_valid(remote_reply),.reply_result(remote_result),.status(remote_status));

// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp #(
    .REMOTE_ENABLE(1),.IR_ENABLE(1),.UI078_ENABLE(1),.USER_WAKE_ENABLE(1),.BMP_ADAPT_ENABLE(1),
    .SESSION_CONTROL_ENABLE(1),
    .USER_SETTINGS_ENABLE(1),
    .CONFIG_RESTORE_ENABLE(1),
    .CLK_FREQ_HZ       (100_000_000),
    .DEFAULT_INTERVAL_S(5'd5),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_sd),
    .remote_valid(remote_valid),.remote_command(remote_command),.remote_argument(remote_argument),
    .remote_reply(remote_reply),.remote_result(remote_result),.remote_hours(remote_hours),.remote_minutes(remote_minutes),
    .ir_valid(ir_valid),.ir_action(ir_action),
    .key_next          (key1),
    .key_auto          (key2),
    .key_period_up     (key3),
    .settings_mode_in  (sw1),
    .settings_volume_in(sw2),
    .timer_enable_in(sw4),.switch3_in(sw3),.user_wake_level(user_wake_level),
    .audio_clk(audio_mclk),.audio_reset(rst_all|~audio_pll_lock),.audio_read(audio_file_read),
    .audio_pcm(audio_file_data),.audio_pcm_valid(audio_file_valid),.audio_empty(audio_file_empty),.audio_level(audio_file_level),
    .audio_error(audio_file_error),.audio_found(audio_file_found),.audio_format_ok(audio_file_format),
    .thumbnail_layout(thumbnail_layout),.thumbnail_mask(thumbnail_mask),.thumbnail_focus(thumbnail_focus),
    .cached_banks(cached_banks),
    .ui_seconds(ui_seconds),.ui_flags(ui_flags),.music_index(music_index),.music_count(music_count),
    .session_state(session_state),.session_expired(session_expired),
    .session_timer_enabled(session_timer_enabled),.session_timer_running(session_timer_running),
    .session_timer_page(session_timer_page),.session_selected_auto(session_selected_auto),
    .session_hours(session_hours),.session_minutes(session_minutes),.session_blink(session_blink),
    .session_zoom(session_zoom),.session_rotate(session_rotate),
    .brightness_level  (brightness_level),
    .volume_level      (volume_level),
    .committed_brightness(committed_brightness),.committed_volume(committed_volume),
    .contrast_level(contrast_level),.committed_contrast(committed_contrast),.settings_focus(settings_focus),
    .settings_active   (settings_active),
    .settings_volume_selected(settings_volume_selected),
    .config_restore_valid(config_restore_valid),
    .config_restore_value(config_restore_value),
    .config_restore_ack(config_restore_ack),
    .config_ready(config_ready),
    .current_interval_s(current_interval_s),
    .osd_auto_play(osd_auto_play),.osd_activity(osd_activity),
    .period_notice_ack (period_notice_ack),
    .period_notice_seconds(period_notice_seconds),
    .period_notice_req (period_notice_req),
    .state_code        (state_code),
    .timeout_code      (timeout_code),
    .pixel_units       (pixel_units),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),
    .media_cue_valid   (media_cue_valid),
    .media_cue_note    (media_cue_note),

    .write_finish_toggle(frame_write_toggle_mem),
    .display_commit_req(display_commit_req),
    .display_commit_ack(display_commit_ack),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);


// Flash and TF run concurrently on the existing SD clock. Only a complete,
// acknowledged tuple is exposed to display/key control; save snapshots are held.
player_flash_spi_driver u_flash_driver (
    .I_clk(sd_card_clk),.I_rst(rst_sd),.I_cmd_start(flash_cmd_start),
    .I_cmd(flash_cmd),.I_addr(flash_addr),.I_length(flash_length),
    .I_write_data(flash_write_data),.I_miso(user_flash_miso),
    .O_init_done(flash_init_done),.O_available(flash_available),.O_jedec(flash_jedec),
    .O_cmd_busy(flash_cmd_busy),.O_cmd_done(flash_cmd_done),.O_error(flash_cmd_error),
    .O_write_index(flash_write_index),.O_read_valid(flash_read_valid),
    .O_read_data(flash_read_data),.O_read_index(flash_read_index),
    .O_cs_n(user_flash_cs_n),.O_sck(user_flash_sck),.O_mosi(user_flash_mosi)
);
player_config_persistence u_config_persistence (
    .I_clk(sd_card_clk),.I_rst(rst_sd),
    .I_current_config({committed_contrast,committed_brightness,committed_volume,current_interval_s}),.I_editing(1'b0),
    .I_restore_ack(config_restore_ack),.I_init_done(flash_init_done),.I_available(flash_available),
    .I_cmd_busy(flash_cmd_busy),.I_cmd_done(flash_cmd_done),.I_cmd_error(flash_cmd_error),
    .I_read_valid(flash_read_valid),.I_read_data(flash_read_data),.I_read_index(flash_read_index),
    .I_write_index(flash_write_index),.O_restore_valid(config_restore_valid),
    .O_restore_config(config_restore_value),.O_ready(config_store_ready),
    .O_save_busy(config_save_busy),.O_dirty(config_dirty),.O_error(config_store_error),
    .O_save_confirmed(),.O_save_failed(),
    .O_save_config(),.O_save_sequence(),.O_save_slot(),
    .O_cmd_start(flash_cmd_start),.O_cmd(flash_cmd),.O_addr(flash_addr),
    .O_length(flash_length),.O_write_data(flash_write_data)
);
// The notification crosses with a request/ack mailbox; its payload stays stable.
carousel_period_display #(.CLK_FREQ_HZ(50_000_000)) u_period_display (
    .clk            (clk),
    .rst            (rst_all),
    .notice_seconds (period_notice_seconds),
    .notice_req     (period_notice_req),
    .notice_ack     (period_notice_ack),
    .show_period    (period_show),
    .tens           (period_tens),
    .ones           (period_ones)
);
seg_decoder u_seg_period_tens(.bin_data(period_tens), .seg_data(seg_period_tens));
seg_decoder u_seg_period_ones(.bin_data(period_ones), .seg_data(seg_period_ones));

seg_decoder seg_decoder_m0(
    .bin_data          (state_digits),
    .seg_data          (seg_data_0)
);

// Only the state digit crosses to the display clock. Full failure
// context remains in the SD domain and is available through UART query page1.
player_config_mailbox #(.WIDTH(4),.RESET_VALUE(4'd0)) u_diagnostics_mailbox (
    .I_source_clk(sd_card_clk),.I_dest_clk(clk),
    .I_source_rst(rst_sd),.I_dest_rst(rst_all),
    .I_value(state_code),.O_value(state_digits)
);

// Display settings use an atomic held-payload mailbox into the 50MHz scanner.
// Electrical indices 6/7 map to SEL0/1; indices 0..5 map to SEL2..7.
player_config_mailbox #(.WIDTH(10), .RESET_VALUE(10'b00_1001_1001)) u_settings_display (
    .I_source_clk(sd_card_clk), .I_dest_clk(clk),
    .I_source_rst(rst_sd), .I_dest_rst(rst_all),
    .I_value({settings_active, settings_volume_selected, brightness_level, volume_level}),
    .O_value(config_display)
);
seg_decoder u_seg_brightness(.bin_data(config_display[7:4]), .seg_data(seg_brightness));
seg_decoder u_seg_volume(.bin_data(config_display[3:0]), .seg_data(seg_volume));

// Physical left-to-right positions 3..7 use electrical indices 0..4.
// Fault/startup diagnostics and interval notifications have display priority.
player_config_mailbox #(.WIDTH(19),.RESET_VALUE(19'd0)) u_session_digits (
    .I_source_clk(sd_card_clk),.I_dest_clk(clk),
    .I_source_rst(rst_sd),.I_dest_rst(rst_all),
    .I_value({config_ready,display_valid,session_expired,session_timer_enabled,
        session_timer_running,(settings_active && session_timer_page),
        settings_volume_selected,session_blink,session_hours,session_minutes}),
    .O_value(session_digits)
);
player_session_digits #(.ENCODED_MODE(1)) u_timer_digits (
    .timer_enabled(session_digits[15]),.timer_running(session_digits[14]),
    .expired(session_digits[16]),.editing(session_digits[13]),
    .minute_selected(session_digits[12]),.blink(session_digits[11]),
    .hours(session_digits[10:6]),.minutes(session_digits[5:0]),
    .digit0(timer_digit0),.digit1(timer_digit1),.digit2(timer_digit2),
    .digit3(timer_digit3),.digit4(timer_digit4)
);
// The scanner drives the status digit at the selected duty cycle.
// All other seven digits and all decimal points stay dark.
seg_scan #(.ENCODED_MODE(1),.SLEEP_ENABLE(1)) seg_scan_m0(
    .clk               (clk),
    .rst_n             (user_reset_n),
    .sleep             (indicator_sleep),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0 (8'hff),
    .seg_data_1 (8'hff),
    .seg_data_2 (8'hff),
    .seg_data_3 (8'hff),
    .seg_data_4 (8'hff),
    .seg_data_5 ({1'b1,indicator_sleep,2'b00,state_digits}),
    .seg_data_6 (8'hff),
    .seg_data_7 (8'hff)
);

// Requests carry a held buffer selection; acknowledge only after the memory
// reader enters its frame ACK state (old bursts drained, new base selected).
frame_display_commit u_frame_display_commit (
    .mem_clk(ext_mem_clk), .rst(rst_sdram),
    .commit_req(transition_reader_req), .requested_buf(disp_buf_idx),
    .requested_view({thumbnail_layout,thumbnail_mask}),.live_thumbnail_mask(thumbnail_mask_mem),.read_view(read_view_mem),
    .commit_ack(transition_reader_ack), .read_buf_idx(read_buf_idx_mem),
    .video_req(video_read_req), .video_ack(video_read_ack_mem),
    .frame_req(frame_read_req_mem), .frame_ack(frame_read_ack_mem)
);
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        video_read_ack_sync <= 2'b00;
        display_valid_sync <= 2'b00;
    end else begin
        video_read_ack_sync <= {video_read_ack_sync[0], video_read_ack_mem};
        display_valid_sync <= {display_valid_sync[0], display_valid};
    end
end
assign video_read_req_ack = video_read_ack_sync[1];

// ===================== 原图像时序与帧缓存 =====================
video_timing_data #(.SLEEP_ENABLE(1)) video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .sleep(session_black),.read_active(video_read_active),.resume_black(video_resume_black),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay #(.DATA_WIDTH(25)) video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_video),
    .read_en           (video_read_en),
    .read_data         ({video_read_data[31:8],video_read_data[0]}),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_picture)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
assign vout_data = display_valid_sync[1] ? vout_data_raw : 24'd0;

// The pixel controller authorizes the unchanged reader only after an all-black
// frame boundary. Its visible ACK retains the requested bank until fade-in starts.
video_transition_control #(.ENABLE(TRANSITION_ENABLE)) u_transition (
    .I_clk(video_clk), .I_rst(rst_video), .I_vs(vs),
    .I_commit_req(display_commit_req), .I_reader_ack(transition_reader_ack),
    .O_reader_req(transition_reader_req), .O_visible_ack(display_commit_ack),
    .O_gain(transition_gain), .O_rst(transition_rst)
);
// Contrast transforms actual picture pixels only. The spare FIFO tag preserves
// black borders and unfilled thumbnails without reserving another frame buffer.
player_contrast_pixels_113 u_contrast_pixels (
    .I_clk(video_clk),.I_rst(transition_rst),.I_level(osd_bundle_video[80:78]),
    .I_hs(hs),.I_vs(vs),.I_de(de),.I_rgb(vout_data),
    .I_picture(vout_picture[0] && display_valid_sync[1]),
    .O_hs(contrast_hs),.O_vs(contrast_vs),.O_de(contrast_de),.O_rgb(contrast_rgb)
);
video_transition_pixels u_transition_pixels (
    .I_clk(video_clk), .I_rst(transition_rst), .I_gain(transition_gain),
    .I_hs(contrast_hs), .I_vs(contrast_vs), .I_de(contrast_de), .I_rgb(contrast_rgb),
    .O_hs(transition_hs), .O_vs(transition_vs), .O_de(transition_de),
    .O_rgb(transition_rgb)
);

// Brightness lives after the fade pipeline and before RGB-to-AXIS conversion.
// Memory banks and TF streaming share the frame-ownership handshake.
player_config_mailbox #(.WIDTH(4), .RESET_VALUE(4'd9)) u_brightness_mailbox (
    .I_source_clk(sd_card_clk), .I_dest_clk(video_clk),
    .I_source_rst(rst_sd), .I_dest_rst(transition_rst),
    .I_value(brightness_level), .O_value(brightness_video_level)
);
wire [4:0] music_brightness_gain;
player_brightness_pixels u_brightness_pixels (
    .I_clk(video_clk), .I_rst(transition_rst), .I_level(brightness_video_level),
    .I_hs(transition_hs), .I_vs(transition_vs), .I_de(transition_de), .I_rgb(transition_rgb),
    .O_hs(brightness_hs), .O_vs(brightness_vs), .O_de(brightness_de), .O_rgb(brightness_rgb),
    .O_latched_gain(music_brightness_gain)
);


// One held tuple crosses the SD/video boundary; activity is not a raw pulse CDC.
// {ready, settings, volume-select, brightness[3:0], volume[3:0], seconds[4:0], auto}
player_osd_bridge #(.WIDTH(81),.RESET_STATE({3'd2,61'd0,1'b0,1'b0,1'b0,4'd9,4'd9,5'd5,1'b0})) u_osd_bridge (
    .I_source_clk(sd_card_clk), .I_dest_clk(video_clk),
    .I_source_rst(rst_sd), .I_dest_rst(transition_rst),
    .I_state({contrast_level,settings_focus,music_index,music_count,music_count[2],ui_flags,ui_seconds,thumbnail_layout,thumbnail_mask,thumbnail_focus,audio_file_error,audio_file_found,session_tuple[21:19],session_timer_page,music_count[1],session_hours,session_minutes,music_count[0],music_index[2:0],
              config_ready,settings_active,settings_volume_selected,
              brightness_level,volume_level,current_interval_s,osd_auto_play}),
    .I_activity(osd_activity), .O_state(osd_bundle_video), .O_activity(osd_activity_video)
);
// Transform configuration is captured once per reader request; a later UI
// update cannot change the frame being acknowledged or rendered.
assign thumbnail_mask_mem=transform_and_mask_mem[8:5];
assign transform_mem=transform_and_mask_mem[4:0];
player_config_mailbox #(.WIDTH(9),.RESET_VALUE(9'd0)) u_transform_config (
    .I_source_clk(sd_card_clk),.I_dest_clk(ext_mem_clk),
    .I_source_rst(rst_sd),.I_dest_rst(rst_sdram),
    .I_value({thumbnail_mask,session_zoom,session_rotate}),.O_value(transform_and_mask_mem)
);
always @(posedge ext_mem_clk or posedge rst_sdram) begin
    if(rst_sdram) transform_frame<=0;
    else if(!frame_read_req_mem) transform_frame<=transform_mem;
end
player_osd_078 u_osd (
    .I_clk(video_clk), .I_rst(transition_rst),
    .I_hs(brightness_hs), .I_vs(brightness_vs), .I_de(brightness_de), .I_rgb(brightness_rgb),
    .I_activity(osd_activity_video),.I_state(osd_state_video), .I_session(session_video),.I_extra(osd_bundle_video[63:37]),
    .I_contrast(osd_bundle_video[80:78]),.I_setting_focus(osd_bundle_video[77:75]),
    .I_music_index(osd_bundle_video[74:70]),.I_music_count(osd_bundle_video[69:64]),
    .I_display_valid(display_valid_sync[1]),
    .I_audio_valid(audio_valid), .I_audio_pcm(session_meter_pcm),
    .I_music_gain(music_brightness_gain),
    .O_hs(osd_hs), .O_vs(osd_vs), .O_de(osd_de), .O_rgb(osd_rgb)
);

// Explicit widths preserve the existing fixed 21-bit frame-reader interface.
localparam [20:0] FR_BUF0_ADDR = BUF0_ADDR;
localparam [20:0] FR_BUF1_ADDR = BUF1_ADDR;
localparam [20:0] FR_BUF2_ADDR = BUF2_ADDR;
localparam [20:0] FR_BUF3_ADDR = BUF3_ADDR;
localparam [20:0] FR_FRAME_PIXELS = FRAME_PIXELS;

frame_read_write #(
    .TRANSFORM_ENABLE (1),.THUMB_ENABLE(1),
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_sdram),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (frame_read_req_mem),
    .read_req_ack      (frame_read_ack_mem),
    .read_finish       (),
    .read_addr_0       (FR_BUF0_ADDR),
    .read_addr_1       (FR_BUF1_ADDR),
    .read_addr_2       (FR_BUF2_ADDR),
    .read_addr_3       (FR_BUF3_ADDR),
    .read_addr_index   (read_buf_idx_mem),
    .read_zoom(transform_frame[4:2]),.read_rotate(transform_frame[1:0]),
    .read_thumbnail(read_view_mem[4]),.read_ready_banks(read_view_mem[3:0]),
    .read_len          (FR_FRAME_PIXELS),
    .read_en           (video_read_en && video_read_active),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (FR_BUF0_ADDR),
    .write_addr_1      (FR_BUF1_ADDR),
    .write_addr_2      (FR_BUF2_ADDR),
    .write_addr_3      (FR_BUF3_ADDR),
    .write_addr_index  (write_buf_idx),
    .write_len         (FR_FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_sdram),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// Independent audio clock/reset path. Audio lock never resets image playback.
hdmi_audio_clock u_audio_clock (
    .I_ref_clk(clk), .I_rst(rst_all),
    .O_mclk(audio_mclk), .O_locked(audio_pll_lock)
);
hdmi_audio_pipeline #(.FILE_MODE(1)) u_audio_pipeline (
    .I_sleep(session_expired),.I_music_paused(ui_flags[3]),.I_file_data(audio_file_data),.I_file_valid(audio_file_valid),.I_file_empty(audio_file_empty),
    .I_file_level(audio_file_level),.O_file_read(audio_file_read),
    .I_mclk(audio_mclk), .I_pixel_clk(video_clk),
    .I_cue_clk(sd_card_clk), .I_cue_valid(media_cue_valid), .I_cue_note(media_cue_note),
    .I_volume_level(volume_level),
    .I_rst(rst_all | ~audio_pll_lock),
    .O_audio_valid(audio_valid),
    .O_audio_left_data(audio_left_data), .O_audio_right_data(audio_right_data),
    .O_meter_sample(audio_meter_sample),
    .O_acr_valid(acr_valid), .O_acr_cts(acr_cts), .O_acr_n(acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_video),
    .I_vs          (osd_vs),
    .I_de          (osd_de),
    .I_rgb         (session_rgb),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_video),
    .O_pulse (edid_trig)
);

// ===================== HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_video),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (session_audio_left),
    .I_audio_right_data (session_audio_right),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

// HDMI_STANDBY106_BEGIN
// park only the four-lane PHY after the existing whole-frame reader stop.
// The encoder/raster continue running. Reset leaves cold startup unchanged.
function hdmi_sleep_is_control;
    input [9:0] word;
    begin
        case (word)
            10'h354, 10'h0ab, 10'h154, 10'h2ab:
                hdmi_sleep_is_control = 1'b1;
            default: hdmi_sleep_is_control = 1'b0;
        endcase
    end
endfunction
wire hdmi_sleep_control = hdmi_sleep_is_control(tmds_ch0_data) &&
                          hdmi_sleep_is_control(tmds_ch1_data) &&
                          hdmi_sleep_is_control(tmds_ch2_data);
// Interpret VS only behind the complete three-lane control-word predicate.
wire hdmi_sleep_public_vs = tmds_ch0_data[9] ^ tmds_ch0_data[8];
reg hdmi_sleep_previous_control;
reg hdmi_phy_sleep_hold;
wire hdmi_sleep_safe_open = hdmi_sleep_control &&
                           !hdmi_sleep_previous_control &&
                           !hdmi_sleep_public_vs &&
                           (tmds_ch1_data == 10'h354) &&
                           (tmds_ch2_data == 10'h354);
wire hdmi_phy_sleep_rst = rst_video || hdmi_phy_sleep_hold;
always @(posedge video_clk or posedge rst_video) begin
    if (rst_video) begin
        hdmi_sleep_previous_control <= 1'b0;
        hdmi_phy_sleep_hold <= 1'b0;
    end else begin
        hdmi_sleep_previous_control <= hdmi_sleep_control;
        if (!video_read_active)
            hdmi_phy_sleep_hold <= 1'b1;
        else if (video_read_active && !session_black && !video_resume_black &&
                 hdmi_sleep_safe_open)
            hdmi_phy_sleep_hold <= 1'b0;
    end
end
// HDMI_STANDBY106_END

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (hdmi_phy_sleep_rst),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule


// Display-only helper in the existing source file: no new project registration.
// A fresh notification restarts the full two-second prompt, even at a limit.
module carousel_period_display #(
    parameter integer CLK_FREQ_HZ = 50_000_000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [4:0] notice_seconds,
    input  wire       notice_req,
    output reg        notice_ack,
    output reg        show_period,
    output reg [3:0]  tens,
    output reg [3:0]  ones
);
localparam integer NOTICE_CYCLES = CLK_FREQ_HZ * 2;
localparam integer NOTICE_BITS = (NOTICE_CYCLES > 1) ? $clog2(NOTICE_CYCLES) : 1;
reg [2:0] notice_req_sync;
reg [4:0] captured_seconds;
reg captured_token,capture_pending;
reg [NOTICE_BITS-1:0] notice_count;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        notice_req_sync <= 3'b000;
        notice_ack      <= 1'b0;
        captured_seconds<= 5'd0;
        captured_token  <= 1'b0;
        capture_pending <= 1'b0;
        show_period     <= 1'b0;
        notice_count    <= 0;
        tens            <= 4'd0;
        ones            <= 4'd0;
    end else begin
        notice_req_sync <= {notice_req_sync[1:0], notice_req};
        if (capture_pending) begin
            capture_pending <= 1'b0;
            notice_ack   <= captured_token;
            show_period  <= 1'b1;
            notice_count <= NOTICE_CYCLES - 1;
            // Only 1..30 seconds is transferred; avoid a general divide-by-ten.
            if (captured_seconds >= 5'd30) begin
                tens <= 4'd3;
                ones <= captured_seconds - 5'd30;
            end else if (captured_seconds >= 5'd20) begin
                tens <= 4'd2;
                ones <= captured_seconds - 5'd20;
            end else if (captured_seconds >= 5'd10) begin
                tens <= 4'd1;
                ones <= captured_seconds - 5'd10;
            end else begin
                tens <= 4'd0;
                ones <= captured_seconds[3:0];
            end
        end else if (notice_req_sync[2] != notice_ack) begin
            captured_seconds <= notice_seconds;
            captured_token <= notice_req_sync[2];
            capture_pending <= 1'b1;
        end else if (show_period) begin
            if (notice_count == 0)
                show_period <= 1'b0;
            else
                notice_count <= notice_count - 1'b1;
        end
    end
end
endmodule

// Frame-boundary bridge around the unchanged memory/FIFO reader. The source
// holds requested_buf from commit_req until commit_ack returns.
module frame_display_commit (
    input wire mem_clk,
    input wire rst,
    input wire commit_req,
    input wire [1:0] requested_buf,
    input wire [4:0] requested_view,
    input wire [3:0] live_thumbnail_mask,
    output reg [4:0] read_view,
    output reg commit_ack,
    output reg [1:0] read_buf_idx,
    input wire video_req,
    output reg video_ack,
    output reg frame_req,
    input wire frame_ack
);
    localparam [1:0] IDLE=2'd0, SETTLE=2'd1, WAIT_ACK=2'd2, DRAIN_ACK=2'd3;
    reg [1:0] state;
    reg [2:0] commit_req_sync;
    reg [2:0] video_req_sync;
    reg [1:0] settle_count;
    reg frame_commit_token;

    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            commit_req_sync <= 3'b000;
            video_req_sync <= 3'b000;
        end else begin
            commit_req_sync <= {commit_req_sync[1:0], commit_req};
            video_req_sync <= {video_req_sync[1:0], video_req};
        end
    end

    always @(posedge mem_clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            settle_count <= 2'd0;
            frame_commit_token <= 1'b0;
            commit_ack <= 1'b0;
            read_buf_idx <= 2'd0;read_view<=0;
            video_ack <= 1'b0;
            frame_req <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    video_ack <= 1'b0;
                    frame_req <= 1'b0;
                    if (video_req_sync[2]) begin
                        // Selection changes only before this frame request.
                        if (commit_req_sync[2] != commit_ack)begin
                            read_buf_idx <= requested_buf;read_view<=requested_view;
                        end else if(read_view[4]) begin
                            // Same-clock mailbox output, sampled before a fresh
                            // frame request. Add complete cells without a fade.
                            read_view[3:0]<=read_view[3:0]|live_thumbnail_mask;
                        end
                        frame_commit_token <= commit_req_sync[2];
                        settle_count <= 2'd0;
                        state <= SETTLE;
                    end
                end
                SETTLE: begin
                    // Give the unchanged reader's two index synchronizers time
                    // to settle before its separate request synchronizers fire.
                    if (settle_count == 2'd3) begin
                        frame_req <= 1'b1;
                        state <= WAIT_ACK;
                    end else
                        settle_count <= settle_count + 2'd1;
                end
                WAIT_ACK: begin
                    if (frame_ack) begin
                        commit_ack <= frame_commit_token;
                        video_ack <= 1'b1;
                        frame_req <= 1'b0;
                        state <= DRAIN_ACK;
                    end
                end
                DRAIN_ACK: begin
                    if (!video_req_sync[2]) begin
                        video_ack <= 1'b0;
                        if (!frame_ack)
                            state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule


// Fade-through-black transaction controller. Tokens persist across clocks;
// bank payload remains owned by the source until O_visible_ack returns.
// Alpha never crosses a clock domain. The normal per-frame reader/video ACK
// continues while the source transaction is waiting for the visible frame.
module video_transition_control #(
    parameter integer ENABLE = 1
)(
    input wire I_clk, I_rst, I_vs,
    input wire I_commit_req, I_reader_ack,
    output wire O_reader_req, O_visible_ack,
    output wire [4:0] O_gain,
    output wire O_rst
);
    localparam [2:0] FULL=3'd0, FIRST_WAIT=3'd1,
                     FADE_OUT=3'd2, BLACK_WAIT=3'd3, FADE_IN=3'd4;
    reg [1:0] reset_sync;
    reg [2:0] req_sync, reader_ack_sync;
    reg [2:0] state;
    reg vs_d;
    reg first_done, held_token;
    reg reader_req_q, visible_ack_q;
    reg [4:0] gain_q;
    wire frame_edge = vs_d && !I_vs;
    assign O_rst = reset_sync[1];
    assign O_reader_req = ENABLE ? reader_req_q : I_commit_req;
    assign O_visible_ack = ENABLE ? visible_ack_q : I_reader_ack;
    assign O_gain = ENABLE ? gain_q : 5'd16;

    // Asynchronous assertion, local pixel-clock reset release.
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) reset_sync <= 2'b11;
        else reset_sync <= {reset_sync[0],1'b0};
    end
    always @(posedge I_clk or posedge O_rst) begin
        if (O_rst) begin
            req_sync <= 3'b000;
            reader_ack_sync <= 3'b000;
        end else begin
            req_sync <= {req_sync[1:0], I_commit_req};
            reader_ack_sync <= {reader_ack_sync[1:0], I_reader_ack};
        end
    end
    always @(posedge I_clk or posedge O_rst) begin
        if (O_rst) begin
            state<=FULL;vs_d<=1'b0;first_done<=1'b0;held_token<=1'b0;
            reader_req_q<=1'b0;visible_ack_q<=1'b0;gain_q<=5'd16;
        end else begin
            vs_d <= I_vs;
            case (state)
                FULL: if (req_sync[2] != visible_ack_q) begin
                    held_token <= req_sync[2];
                    if (!first_done) begin
                        // Cold boot already has a black display gate: no fade-out.
                        reader_req_q <= req_sync[2];
                        state <= FIRST_WAIT;
                    end else state <= FADE_OUT;
                end
                FIRST_WAIT: if (reader_ack_sync[2] == held_token) begin
                    visible_ack_q <= held_token;
                    first_done <= 1'b1;
                    state <= FULL;
                end
                FADE_OUT: if (frame_edge) begin
                    gain_q <= gain_q - 5'd1;
                    if (gain_q == 5'd1) begin
                        // No new-bank reader transaction until this all-black frame.
                        reader_req_q <= held_token;
                        state <= BLACK_WAIT;
                    end
                end
                BLACK_WAIT: if (frame_edge && (reader_ack_sync[2] == held_token)) begin
                    gain_q <= 5'd1;
                    visible_ack_q <= held_token;
                    state <= FADE_IN;
                end
                FADE_IN: if (frame_edge) begin
                    gain_q <= gain_q + 5'd1;
                    if (gain_q == 5'd15) state <= FULL;
                end
                default: begin
                    // A recovery keeps the source transaction pending for replay.
                    gain_q<=5'd16;state<=FULL;
                end
            endcase
        end
    end
endmodule

// Two pixel registers, including HS/VS/DE. The first stage uses DSP
// products for floor(channel*gain/16), with four-state simulation semantics.
// gain16 bypasses the low-bit product, preserving every original RGB byte.
module video_transition_pixels (
    input wire I_clk, I_rst,
    input wire [4:0] I_gain,
    input wire I_hs,I_vs,I_de,
    input wire [23:0] I_rgb,
    output reg O_hs,O_vs,O_de,
    output reg [23:0] O_rgb
);
    reg hs_q,vs_q,de_q,full_q;
    reg [23:0] rgb_q;
    // Pure products use the official TD multiplier directive. The first
    // stage remains one clock; the second stage keeps truncation and bypass.
    (* dsp_style = "yes" *) wire [11:0] r_product;
    (* dsp_style = "yes" *) wire [11:0] g_product;
    (* dsp_style = "yes" *) wire [11:0] b_product;
    assign r_product=I_rgb[23:16]*I_gain[3:0];
    assign g_product=I_rgb[15:8]*I_gain[3:0];
    assign b_product=I_rgb[7:0]*I_gain[3:0];
    reg [11:0] r_sum,g_sum,b_sum;
    // Multiplication has different X propagation from conditional terms.
    // Conditional terms define four-state behavior. In binary hardware both explicit
    // reduction cases select the multiplier; the default is unreachable.
    function [11:0] exact_product;
        input [7:0] color;
        input [3:0] gain;
        input [11:0] product;
        begin
            case(^{color,gain})
                1'b0,1'b1: exact_product=product;
                default: exact_product={2'd0,low_terms(color,gain[1:0])}+
                                       high_terms(color,gain[3:2]);
            endcase
        end
    endfunction
    function [9:0] low_terms;
        input [7:0] color;
        input [1:0] bits01;
        begin
            low_terms=(bits01[0] ? {2'd0,color} : 10'd0)+
                      (bits01[1] ? {1'd0,color,1'd0} : 10'd0);
        end
    endfunction
    function [11:0] high_terms;
        input [7:0] color;
        input [1:0] bits23;
        begin
            high_terms=(bits23[0] ? {2'd0,color,2'd0} : 12'd0)+
                       (bits23[1] ? {1'd0,color,3'd0} : 12'd0);
        end
    endfunction
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            hs_q<=0;vs_q<=0;de_q<=0;full_q<=0;rgb_q<=0;
            r_sum<=0;g_sum<=0;b_sum<=0;
            O_hs<=0;O_vs<=0;O_de<=0;O_rgb<=0;
        end else begin
            hs_q<=I_hs;vs_q<=I_vs;de_q<=I_de;
            full_q<=I_gain[4];rgb_q<=I_rgb;
            r_sum<=exact_product(I_rgb[23:16],I_gain[3:0],r_product);
            g_sum<=exact_product(I_rgb[15:8],I_gain[3:0],g_product);
            b_sum<=exact_product(I_rgb[7:0],I_gain[3:0],b_product);
            O_hs<=hs_q;O_vs<=vs_q;O_de<=de_q;
            O_rgb<=!de_q ? 24'd0 : full_q ? rgb_q :
                   {r_sum[11:4],g_sum[11:4],b_sum[11:4]};
        end
    end
endmodule


// Atomic latest-value configuration transport. Token and payload are held
// until ACK returns; destination samples the bus only after three token FFs.
// Reset-default values are usable even before the first transport completes.
module player_config_mailbox #(
    parameter integer WIDTH = 4,
    parameter [WIDTH-1:0] RESET_VALUE = 9
)(
    input wire I_source_clk, I_dest_clk,
    input wire I_source_rst, I_dest_rst,
    input wire [WIDTH-1:0] I_value,
    output reg [WIDTH-1:0] O_value
);
    reg [WIDTH-1:0] source_value;
    reg source_req, dest_ack, reset_dirty;
    reg [2:0] ack_sync, req_sync;
    always @(posedge I_source_clk or posedge I_source_rst) begin
        if (I_source_rst) begin
            source_value<=RESET_VALUE;source_req<=0;ack_sync<=0;reset_dirty<=1;
        end else begin
            ack_sync<={ack_sync[1:0],dest_ack};
            if ((source_req==ack_sync[2]) && (reset_dirty || source_value!=I_value)) begin
                source_value<=I_value;source_req<=~source_req;reset_dirty<=0;
            end
        end
    end
    always @(posedge I_dest_clk or posedge I_dest_rst) begin
        if (I_dest_rst) begin
            O_value<=RESET_VALUE;dest_ack<=0;req_sync<=0;
        end else begin
            req_sync<={req_sync[1:0],source_req};
            if (req_sync[2]!=dest_ack) begin
                O_value<=source_value;dest_ack<=req_sync[2];
            end
        end
    end
endmodule

// User brightness is latched at the vertical-blank boundary. Reuse the
// accepted two-stage RGB gain datapath and carry HS/VS/DE through both stages.
module player_brightness_pixels (
    input wire I_clk, I_rst,
    input wire [3:0] I_level,
    input wire I_hs,I_vs,I_de,
    input wire [23:0] I_rgb,
    output wire O_hs,O_vs,O_de,
    output wire [23:0] O_rgb,
    output wire [4:0] O_latched_gain
);
    reg vs_q;
    reg [4:0] gain_q;
    assign O_latched_gain=gain_q;
    function [4:0] level_gain;
        input [3:0] level;
        begin
            case(level)
                4'd1:level_gain=5'd2;
                4'd2:level_gain=5'd4;
                4'd3:level_gain=5'd6;
                4'd4:level_gain=5'd8;
                4'd5:level_gain=5'd10;
                4'd6:level_gain=5'd12;
                4'd7:level_gain=5'd14;
                4'd8:level_gain=5'd15;
                default:level_gain=5'd16;
            endcase
        end
    endfunction
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin vs_q<=0;gain_q<=5'd16;end
        else begin
            vs_q<=I_vs;
            if (I_vs && !vs_q) gain_q<=level_gain(I_level);
        end
    end
    video_transition_pixels u_gain (
        .I_clk(I_clk), .I_rst(I_rst), .I_gain(gain_q),
        .I_hs(I_hs), .I_vs(I_vs), .I_de(I_de), .I_rgb(I_rgb),
        .O_hs(O_hs), .O_vs(O_vs), .O_de(O_de), .O_rgb(O_rgb)
    );
endmodule

// parameter persistence modules.
// User NOR Flash only. All serial edges are enables in the existing I_clk domain.
module player_flash_spi_driver #(

    parameter integer CLK_FREQ_HZ = 100000000,

    parameter integer SPI_HZ = 1000000,

    parameter integer POWER_UP_MS = 10,

    parameter integer READY_TIMEOUT_MS = 1000,

    parameter integer PROGRAM_TIMEOUT_MS = 10,

    parameter integer ERASE_TIMEOUT_MS = 1000,

    parameter integer CS_HIGH_US = 1

)(

    input wire I_clk, I_rst,

    input wire I_cmd_start,

    input wire [1:0] I_cmd,

    input wire [23:0] I_addr,

    input wire [12:0] I_length,

    input wire [7:0] I_write_data,

    input wire I_miso,

    output reg O_init_done, O_available,

    output reg [23:0] O_jedec,

    output reg O_cmd_busy, O_cmd_done,

    output reg [3:0] O_error,

    output wire [7:0] O_write_index,

    output reg O_read_valid,

    output reg [7:0] O_read_data,

    output reg [12:0] O_read_index,

    output reg O_cs_n, O_sck, O_mosi

);

    localparam [3:0] ERR_NONE=0, ERR_UNAVAILABLE=1, ERR_TIMEOUT=2,

                     ERR_REQUEST=3, ERR_PROTECTED=4, ERR_WEL=5;

    localparam integer HALF_RAW = CLK_FREQ_HZ / (2*SPI_HZ);

    localparam integer HALF_CYCLES = (HALF_RAW < 4) ? 4 : HALF_RAW;

    localparam integer DIV_W = (HALF_CYCLES <= 1) ? 1 : $clog2(HALF_CYCLES);

    // Divide before multiplying; supported clock is an integral MHz and no 32bit product overflow.

    localparam [31:0] POWER_CYCLES = (CLK_FREQ_HZ/1000)*POWER_UP_MS;

    localparam [31:0] READY_CYCLES = (CLK_FREQ_HZ/1000)*READY_TIMEOUT_MS;

    localparam [31:0] PROGRAM_CYCLES = (CLK_FREQ_HZ/1000)*PROGRAM_TIMEOUT_MS;

    localparam [31:0] ERASE_CYCLES = (CLK_FREQ_HZ/1000)*ERASE_TIMEOUT_MS;

    localparam [31:0] GAP_RAW = (CLK_FREQ_HZ/1000000)*CS_HIGH_US;

    localparam [31:0] GAP_CYCLES = (GAP_RAW < 1) ? 1 : GAP_RAW;

    // These counters only reach their inclusive constant limits. Widen the

    // +1 expression so a 32'hffffffff limit still requires all 32 bits;

    // the zero limit uses a legal one-bit register.

    localparam [31:0] WAIT_MAX_A = (POWER_CYCLES>READY_CYCLES)?POWER_CYCLES:READY_CYCLES;

    localparam [31:0] WAIT_MAX_B = (PROGRAM_CYCLES>ERASE_CYCLES)?PROGRAM_CYCLES:ERASE_CYCLES;

    localparam [31:0] WAIT_MAX = (WAIT_MAX_A>WAIT_MAX_B)?WAIT_MAX_A:WAIT_MAX_B;

    localparam integer WAIT_BITS = (WAIT_MAX<1)?1:$clog2({1'b0,WAIT_MAX}+33'd1);

    localparam integer GAP_BITS = (GAP_CYCLES<1)?1:$clog2({1'b0,GAP_CYCLES}+33'd1);





    // Mode 0 input: NOR changes DO on falling SCK; rising CE is half a serial period later.

    reg miso_meta, miso_sync;

    always @(posedge I_clk or posedge I_rst) begin

        if (I_rst) begin miso_meta<=0; miso_sync<=0; end

        else begin miso_meta<=I_miso; miso_sync<=miso_meta; end

    end

    reg spi_start, spi_busy, spi_done;

    reg [7:0] spi_tx, spi_rx, rx_shift, tx_shift;

    reg [2:0] bit_count;

    reg [DIV_W-1:0] divider;

    always @(posedge I_clk or posedge I_rst) begin

        if (I_rst) begin

            O_sck<=0; O_mosi<=0; spi_busy<=0; spi_done<=0;

            spi_rx<=0; rx_shift<=0; tx_shift<=0; bit_count<=0; divider<=0;

        end else begin

            spi_done<=0;

            if (!spi_busy) begin

                O_sck<=0;

                if (spi_start) begin

                    spi_busy<=1; O_mosi<=spi_tx[7]; tx_shift<=spi_tx;

                    rx_shift<=0; bit_count<=0; divider<=HALF_CYCLES-1;

                end

            end else if (divider != 0) divider<=divider-1'b1;

            else begin

                divider<=HALF_CYCLES-1;

                if (!O_sck) begin

                    O_sck<=1; rx_shift<={rx_shift[6:0],miso_sync};

                end else begin

                    O_sck<=0;

                    if (bit_count==7) begin

                        spi_busy<=0; spi_done<=1; spi_rx<=rx_shift;

                    end else begin

                        bit_count<=bit_count+1'b1;

                        tx_shift<={tx_shift[6:0],1'b0}; O_mosi<=tx_shift[6];

                    end

                end

            end

        end

    end



    localparam [2:0] X_STATUS=0, X_ID=1, X_READ=2, X_WREN=3, X_ERASE=4, X_PROGRAM=5;

    localparam [2:0] T_IDLE=0, T_GAP=1, T_BYTE=2, T_WAIT=3, T_FINISH=4;

    reg [2:0] transport_state, xfer_kind, launch_kind;

    reg xfer_start, xfer_busy, xfer_done;

    reg [23:0] id_data;
    reg [23:0] command_addr;

    // command_addr is held from host acceptance through every serial transfer.

    // Address bytes are only consumed by READ/ERASE/PROGRAM; no next command

    // is accepted until its transport has completed.

    wire [23:0] xfer_addr = command_addr;

    reg [12:0] launch_length;

    reg [13:0] xfer_index, xfer_last;

    reg [GAP_BITS-1:0] gap_count;

    reg [7:0] status_data;

    reg [7:0] next_byte;

    assign O_write_index = (xfer_kind==X_PROGRAM && xfer_index>=4) ? xfer_index-14'd4 : 8'd0;

    always @* begin

        next_byte=8'h00;

        if (xfer_index==0) begin

            case (xfer_kind)

                X_STATUS: next_byte=8'h05;

                X_ID: next_byte=8'h9f;

                X_READ: next_byte=8'h03;

                X_WREN: next_byte=8'h06;

                X_ERASE: next_byte=8'h20;

                X_PROGRAM: next_byte=8'h02;

                default: next_byte=8'h00;

            endcase

        end else if (xfer_kind==X_READ || xfer_kind==X_ERASE || xfer_kind==X_PROGRAM) begin

            case (xfer_index)

                1: next_byte=xfer_addr[23:16];

                2: next_byte=xfer_addr[15:8];

                3: next_byte=xfer_addr[7:0];

                default: if (xfer_kind==X_PROGRAM) next_byte=I_write_data;

            endcase

        end

    end

    always @(posedge I_clk or posedge I_rst) begin

        if (I_rst) begin

            transport_state<=T_IDLE; xfer_kind<=X_STATUS; xfer_busy<=0; xfer_done<=0;

            xfer_index<=0; xfer_last<=0; gap_count<=0;

            O_cs_n<=1; spi_start<=0; spi_tx<=0; status_data<=0; id_data<=0;

            O_read_valid<=0; O_read_data<=0; O_read_index<=0;

        end else begin

            spi_start<=0; xfer_done<=0; O_read_valid<=0;

            if (O_cs_n && gap_count<GAP_CYCLES) gap_count<=gap_count+1'b1;

            if (!O_cs_n) gap_count<=0;

            case (transport_state)

                T_IDLE: if (xfer_start) begin

                    xfer_kind<=launch_kind; xfer_index<=0; xfer_busy<=1;

                    case (launch_kind)

                        X_STATUS: xfer_last<=1;

                        X_ID: begin xfer_last<=3; id_data<=0; end

                        X_READ,X_PROGRAM: xfer_last<={1'b0,launch_length}+14'd3;

                        X_ERASE: xfer_last<=3;

                        default: xfer_last<=0;

                    endcase

                    transport_state<=T_GAP;

                end

                T_GAP: if (gap_count>=GAP_CYCLES) begin O_cs_n<=0; transport_state<=T_BYTE; end

                T_BYTE: begin spi_tx<=next_byte; spi_start<=1; transport_state<=T_WAIT; end

                T_WAIT: if (spi_done) begin

                    if (xfer_kind==X_STATUS && xfer_index==1) status_data<=spi_rx;

                    if (xfer_kind==X_ID && xfer_index>0) id_data<={id_data[15:0],spi_rx};

                    if (xfer_kind==X_READ && xfer_index>=4) begin

                        O_read_valid<=1; O_read_data<=spi_rx; O_read_index<=xfer_index-14'd4;

                    end

                    if (xfer_index==xfer_last) transport_state<=T_FINISH;

                    else begin xfer_index<=xfer_index+1'b1; transport_state<=T_BYTE; end

                end

                T_FINISH: begin O_cs_n<=1; xfer_busy<=0; xfer_done<=1; transport_state<=T_IDLE; end

                default: transport_state<=T_IDLE;

            endcase

        end

    end



    localparam [3:0] H_POWER=0,H_STATUS_START=1,H_STATUS_WAIT=2,H_ID_START=3,H_ID_WAIT=4,

        H_IDLE=5,H_WREN_START=6,H_WREN_WAIT=7,H_OP_START=8,H_OP_WAIT=9,H_DONE=10;

    localparam [1:0] P_BOOT=0,P_PRE=1,P_WEL=2,P_COMPLETE=3;

    reg [3:0] host_state;

    reg [1:0] poll_reason, command;

    reg [12:0] command_length;

    reg [WAIT_BITS-1:0] wait_count, wait_limit;

    wire [24:0] req_end={1'b0,I_addr}+{12'd0,I_length};

    wire range_ok=(I_addr>=24'h7fe000) && (req_end<=25'h0800000);

    wire read_ok=(I_length!=0)&&(I_length<=4096)&&range_ok;

    wire erase_ok=((I_addr==24'h7fe000)||(I_addr==24'h7ff000))&&(I_length==4096);

    wire program_ok=(I_length!=0)&&(I_length<=256)&&range_ok&&({1'b0,I_addr[7:0]}+{1'b0,I_length}<=256);

    always @(posedge I_clk or posedge I_rst) begin

        if (I_rst) begin

            host_state<=H_POWER; poll_reason<=P_BOOT; command<=0; command_addr<=0; command_length<=0;

            wait_count<=0; wait_limit<=READY_CYCLES; launch_kind<=X_STATUS;

            launch_length<=0; xfer_start<=0;

            O_init_done<=0; O_available<=0; O_jedec<=0; O_cmd_busy<=0; O_cmd_done<=0; O_error<=0;

        end else begin

            xfer_start<=0; O_cmd_done<=0;

            if ((host_state==H_STATUS_START || host_state==H_STATUS_WAIT) && wait_count<wait_limit)

                wait_count<=wait_count+1'b1;

            case (host_state)

                H_POWER: if (wait_count>=POWER_CYCLES) begin

                    wait_count<=0; wait_limit<=READY_CYCLES; poll_reason<=P_BOOT; host_state<=H_STATUS_START;

                end else wait_count<=wait_count+1'b1;

                H_STATUS_START: begin

                    if (!xfer_busy) begin

                        launch_kind<=X_STATUS; xfer_start<=1; host_state<=H_STATUS_WAIT;

                    end

                end

                H_STATUS_WAIT: if (xfer_done) begin

                    if (status_data[0]) begin

                        if (wait_count>=wait_limit) begin

                            O_error<=ERR_TIMEOUT;

                            if (poll_reason==P_BOOT) begin O_init_done<=1; host_state<=H_IDLE; end

                            else host_state<=H_DONE;

                        end else host_state<=H_STATUS_START;

                    end else begin

                        case (poll_reason)

                            P_BOOT: host_state<=H_ID_START;

                            P_PRE: if (status_data[4:2]!=0) begin O_error<=ERR_PROTECTED; host_state<=H_DONE; end

                                   else host_state<=H_WREN_START;

                            P_WEL: if (!status_data[1] || status_data[4:2]!=0) begin

                                       O_error<=status_data[4:2]!=0 ? ERR_PROTECTED : ERR_WEL; host_state<=H_DONE;

                                   end else host_state<=H_OP_START;

                            default: host_state<=H_DONE;

                        endcase

                    end

                end

                H_ID_START: if (!xfer_busy) begin launch_kind<=X_ID; xfer_start<=1; host_state<=H_ID_WAIT; end

                H_ID_WAIT: if (xfer_done) begin

                    O_jedec<=id_data; O_init_done<=1;

                    if (id_data==24'hef3017 || id_data==24'hef4017) begin O_available<=1; O_error<=ERR_NONE; end

                    else begin O_available<=0; O_error<=ERR_UNAVAILABLE; end

                    host_state<=H_IDLE;

                end

                H_IDLE: if (I_cmd_start) begin

                    O_cmd_busy<=1; O_error<=ERR_NONE;

                    command<=I_cmd; command_addr<=I_addr; command_length<=I_length;

                    if (!O_available) begin O_error<=ERR_UNAVAILABLE; host_state<=H_DONE; end

                    else if ((I_cmd==0 && read_ok)||(I_cmd==1 && erase_ok)||(I_cmd==2 && program_ok)) begin

                        if (I_cmd==0) host_state<=H_OP_START;

                        else begin wait_count<=0; wait_limit<=READY_CYCLES; poll_reason<=P_PRE; host_state<=H_STATUS_START; end

                    end else begin O_error<=ERR_REQUEST; host_state<=H_DONE; end

                end

                H_WREN_START: if (!xfer_busy) begin launch_kind<=X_WREN; xfer_start<=1; host_state<=H_WREN_WAIT; end

                H_WREN_WAIT: if (xfer_done) begin

                    wait_count<=0; wait_limit<=READY_CYCLES; poll_reason<=P_WEL; host_state<=H_STATUS_START;

                end

                H_OP_START: if (!xfer_busy) begin

                    launch_length<=command_length;

                    launch_kind<=command==0 ? X_READ : (command==1 ? X_ERASE : X_PROGRAM);

                    xfer_start<=1; host_state<=H_OP_WAIT;

                end

                H_OP_WAIT: if (xfer_done) begin

                    if (command==0) host_state<=H_DONE;

                    else begin

                        wait_count<=0; wait_limit<=command==1 ? ERASE_CYCLES : PROGRAM_CYCLES;

                        poll_reason<=P_COMPLETE; host_state<=H_STATUS_START;

                    end

                end

                H_DONE: begin O_cmd_busy<=0; O_cmd_done<=1; host_state<=H_IDLE; end

                default: host_state<=H_POWER;

            endcase

        end

    end

endmodule

// bounded dual-sector settings store. No new clock or clock gating.
module player_config_persistence #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer STABLE_SAVE_MS=2000,
    parameter integer BOOT_WATCHDOG_MS=2000,
    parameter integer COMMAND_WATCHDOG_MS=2000,
    parameter integer APPLY_TIMEOUT_MS=100
)(
    input wire I_clk,I_rst,
    input wire [15:0] I_current_config,
    input wire I_editing,
    input wire I_restore_ack,I_init_done,I_available,
    input wire I_cmd_busy,I_cmd_done,
    input wire [3:0] I_cmd_error,
    input wire I_read_valid,
    input wire [7:0] I_read_data,
    input wire [12:0] I_read_index,
    input wire [7:0] I_write_index,
    output reg O_restore_valid,
    output reg [15:0] O_restore_config,
    output reg O_ready,O_save_busy,
    // Passive UART result: immutable snapshot, final verification only.
    output reg O_save_confirmed,O_save_failed,
    output wire [15:0] O_save_config,
    output wire [31:0] O_save_sequence,
    output wire O_save_slot,
    output wire O_dirty,
    output reg [3:0] O_error,
    output reg O_cmd_start,
    output reg [1:0] O_cmd,
    output reg [23:0] O_addr,
    output reg [12:0] O_length,
    output wire [7:0] O_write_data
);
localparam [15:0] DEFAULT_CONFIG={3'd2,4'd9,4'd9,5'd5};
localparam [23:0] SLOT_A=24'h7FE000,SLOT_B=24'h7FF000;
localparam [63:0] STABLE_N=(64'd1*CLK_FREQ_HZ*STABLE_SAVE_MS/1000)>0 ?
                          (64'd1*CLK_FREQ_HZ*STABLE_SAVE_MS/1000):1;
localparam [63:0] BOOT_N=(64'd1*CLK_FREQ_HZ*BOOT_WATCHDOG_MS/1000)>0 ?
                        (64'd1*CLK_FREQ_HZ*BOOT_WATCHDOG_MS/1000):1;
localparam [63:0] COMMAND_N=(64'd1*CLK_FREQ_HZ*COMMAND_WATCHDOG_MS/1000)>0 ?
                           (64'd1*CLK_FREQ_HZ*COMMAND_WATCHDOG_MS/1000):1;
localparam [63:0] APPLY_N=(64'd1*CLK_FREQ_HZ*APPLY_TIMEOUT_MS/1000)>0 ?
                         (64'd1*CLK_FREQ_HZ*APPLY_TIMEOUT_MS/1000):1;
localparam integer STABLE_BITS=$clog2(STABLE_N+1),BOOT_BITS=$clog2(BOOT_N+1),
                   COMMAND_BITS=$clog2(COMMAND_N+1),APPLY_BITS=$clog2(APPLY_N+1);
localparam [3:0] S_BOOT=0,S_LAUNCH=1,S_WAIT=2,S_DRAIN=3,S_EVAL=4,
                 S_SELECT=5,S_APPLY=6,S_IDLE=7,S_GEN_FEED=8,S_GEN_SHIFT=9,
                 S_ERASE=10,S_APP_FAIL=11,S_SEQ_DELTA=12,S_SEQ_PICK=13;
localparam [2:0] C_BOOT=0,C_ERASE=1,C_EMPTY=2,C_BODY_PP=3,
                 C_BODY_READ=4,C_MARK_PP=5,C_FINAL_READ=6;
reg [3:0] state;
reg [2:0] op_context;
reg boot_phase,boot_slot;
// Boot deadline and ready-state stable-save interval have disjoint lifetimes.
localparam integer LIFECYCLE_BITS=(BOOT_BITS>STABLE_BITS)?BOOT_BITS:STABLE_BITS;
reg [LIFECYCLE_BITS-1:0] lifecycle_count;
// Command and apply states are disjoint; each entry initializes the shared timer.
localparam integer TRANSACTION_BITS=(COMMAND_BITS>APPLY_BITS)?COMMAND_BITS:APPLY_BITS;
reg [TRANSACTION_BITS-1:0] transaction_count;

reg [15:0] observed,confirmed,snapshot;
reg [31:0] snapshot_seq,snapshot_crc;
reg target_slot,retry_used,save_blocked,active_valid,active_slot,sequence_blocked;
reg [1:0] slot_blank,slot_valid,slot_prepared;
reg [31:0] seq_a,seq_b;
wire [31:0] active_seq=active_slot ? seq_b:seq_a; // authoritative slot sequence
reg [15:0] config_a,config_b;
reg [12:0] read_count;
reg read_error,verify_good,header_good,range_good,all_blank,tail_blank;
reg marker_good,marker_compatible;
reg [3:0] command_error;
reg [31:0] parsed_seq,parsed_crc,crc_accum;
reg [15:0] parsed_config;
reg parsed_v2;
reg [3:0] crc_busy;
reg [4:0] gen_index;
// evaluate completed immutable read results before distributing them.
reg eval_transport_good_q,eval_slot_valid_q,eval_slot_prepared_q,eval_payload_good_q;
reg [31:0] seq_delta_q;
reg selected_b_q,sequence_conflict_q;
// One accumulator: read/feed uses it only when crc_busy is zero.
wire [31:0] crc_step=crc_accum[0] ? (crc_accum>>1)^32'hEDB88320 : crc_accum>>1;
wire body_good=header_good && range_good && ((crc_accum^32'hFFFFFFFF)==parsed_crc);
wire current_good=(I_current_config[15:13]<=4 && I_current_config[12:9]>=1 && I_current_config[12:9]<=9 &&
                   I_current_config[8:5]<=9 && I_current_config[4:0]>=1 && I_current_config[4:0]<=30);
wire [31:0] seq_delta=seq_delta_q;
wire sequence_conflict=slot_valid==2'b11 &&
                      ((seq_delta==0 && config_a!=config_b) || seq_delta==32'h80000000);
wire selected_b=slot_valid[1] && (!slot_valid[0] || (seq_delta!=0 && seq_delta<32'h80000000));
wire inactive=~active_slot;
// Membership in {0,+1,-1} is invariant under swapping the two slots.
// Share the same seq_b-seq_a subtraction already used at boot selection.
wire [31:0] peer_delta=seq_b-seq_a;
wire peer_prepared_ok=slot_prepared[inactive] &&
                     (peer_delta==0 || peer_delta==32'd1 || peer_delta==32'hffffffff);
wire inactive_eligible=slot_blank[inactive] || slot_valid[inactive] || peer_prepared_ok;
// Metadata changes only outside IDLE. Register the expensive prepared-peer
// qualification, and require one complete IDLE cycle before consuming it.
// This invalidates stale qualification after boot selection or a save commit.
reg target_eligible_q,eligibility_ready_q;
always @(posedge I_clk or posedge I_rst) begin
    if(I_rst) begin target_eligible_q<=0;eligibility_ready_q<=0;end
    else begin
        target_eligible_q<=active_valid ? inactive_eligible : (slot_blank!=0);
        eligibility_ready_q<=(state==S_IDLE);
    end
end
wire [23:0] target_addr=target_slot ? SLOT_B:SLOT_A;
assign O_dirty=O_ready && (I_current_config!=confirmed);
assign O_save_config=snapshot;
assign O_save_sequence=snapshot_seq;
assign O_save_slot=target_slot;

function [7:0] marker_byte;
    input [1:0] n;
    begin case(n) 0:marker_byte=8'h3C;1:marker_byte=8'hC3;
                  2:marker_byte=8'h5A;3:marker_byte=8'hA5;endcase end
endfunction
function [7:0] fixed_byte;
    input [4:0] n;
    begin case(n)
      0:fixed_byte="P";1:fixed_byte="C";2:fixed_byte="F";3:fixed_byte="G";
      4:fixed_byte=2;5:fixed_byte=0;6:fixed_byte=32;7:fixed_byte=0;
      default:fixed_byte=0;
    endcase end
endfunction
function [7:0] record_byte;
    input [5:0] n;
    begin case(n)
      8:record_byte=snapshot_seq[7:0];9:record_byte=snapshot_seq[15:8];
      10:record_byte=snapshot_seq[23:16];11:record_byte=snapshot_seq[31:24];
      12:record_byte={4'b0,snapshot[12:9]};13:record_byte={4'b0,snapshot[8:5]};
      14:record_byte={3'b0,snapshot[4:0]};
      15:record_byte={5'd0,snapshot[15:13]};
      24:record_byte=snapshot_crc[7:0];25:record_byte=snapshot_crc[15:8];
      26:record_byte=snapshot_crc[23:16];27:record_byte=snapshot_crc[31:24];
      28,29,30,31:record_byte=marker_byte(n[1:0]);
      default:record_byte=fixed_byte(n[4:0]);
    endcase end
endfunction
wire [5:0] internal_byte_index=(state==S_GEN_FEED) ? {1'b0,gen_index}:read_count[5:0];
wire [7:0] internal_byte=record_byte(internal_byte_index);
assign O_write_data=(O_addr[11:0]==12'd28) ?
                    ((I_write_index<4) ? marker_byte(I_write_index[1:0]):8'hFF) :
                    ((I_write_index<28) ? record_byte(I_write_index[5:0]):8'hFF);

// One outstanding command; driver payload is held through its completion.
task queue_command;
    input [2:0] c;
    input [1:0] op;
    input [23:0] addr;
    input [12:0] length;
    begin
        op_context<=c;O_cmd<=op;O_addr<=addr;O_length<=length;state<=S_LAUNCH;
        transaction_count<=0;command_error<=0;read_count<=0;read_error<=0;
        verify_good<=1;header_good<=1;range_good<=1;all_blank<=1;tail_blank<=1;
        marker_good<=1;marker_compatible<=1;parsed_seq<=0;parsed_crc<=0;
        eval_transport_good_q<=0;eval_slot_valid_q<=0;
        eval_slot_prepared_q<=0;eval_payload_good_q<=0;
        parsed_config<={3'd2,13'd0};parsed_v2<=0;crc_accum<=32'hFFFFFFFF;crc_busy<=0;
    end
endtask
task start_apply;
    input [15:0] cfg;
    begin
        O_restore_config<=cfg;O_restore_valid<=1;confirmed<=cfg;
        boot_phase<=0;lifecycle_count<=0;transaction_count<=0;state<=S_APPLY;
    end
endtask
task fail_save;
    input [3:0] error_code;
    begin
        O_error<=error_code;
        // At most one retry of this immutable snapshot/session-owned target.
        // No new command is sent while a timed-out old command is still busy.
        if(!retry_used && I_available && !I_cmd_busy) begin
            retry_used<=1;state<=S_ERASE;
        end else begin
            O_save_failed<=1;
            O_save_busy<=0;save_blocked<=(I_current_config==snapshot);state<=S_IDLE;
        end
    end
endtask

always @(posedge I_clk or posedge I_rst) begin
    if(I_rst) begin
        state<=S_BOOT;op_context<=C_BOOT;boot_phase<=1;boot_slot<=0;lifecycle_count<=0;
        transaction_count<=0;
        observed<=DEFAULT_CONFIG;confirmed<=DEFAULT_CONFIG;snapshot<=DEFAULT_CONFIG;
        snapshot_seq<=0;snapshot_crc<=0;target_slot<=0;retry_used<=0;save_blocked<=0;
        active_valid<=0;active_slot<=0;sequence_blocked<=0;
        slot_blank<=0;slot_valid<=0;slot_prepared<=0;seq_a<=0;seq_b<=0;
        config_a<=DEFAULT_CONFIG;config_b<=DEFAULT_CONFIG;
        read_count<=0;read_error<=0;verify_good<=1;header_good<=1;range_good<=1;
        all_blank<=1;tail_blank<=1;marker_good<=1;marker_compatible<=1;
        command_error<=0;parsed_seq<=0;parsed_crc<=0;parsed_config<={3'd2,13'd0};parsed_v2<=0;
        crc_accum<=32'hFFFFFFFF;crc_busy<=0;gen_index<=0;
        eval_transport_good_q<=0;eval_slot_valid_q<=0;
        eval_slot_prepared_q<=0;eval_payload_good_q<=0;
        seq_delta_q<=0;selected_b_q<=0;sequence_conflict_q<=0;
        O_restore_valid<=0;O_restore_config<=DEFAULT_CONFIG;O_ready<=0;
        O_save_confirmed<=0;O_save_failed<=0;
        O_save_busy<=0;O_error<=0;O_cmd_start<=0;O_cmd<=0;O_addr<=SLOT_A;O_length<=0;
    end else begin
        O_cmd_start<=0;O_save_confirmed<=0;O_save_failed<=0;
        if(boot_phase && lifecycle_count<BOOT_N-1)lifecycle_count<=lifecycle_count+1'b1;
        if(!O_ready) begin observed<=O_restore_config;if(!boot_phase)lifecycle_count<=0;end
        else if(I_current_config!=observed) begin
            observed<=I_current_config;lifecycle_count<=0;save_blocked<=0;
        end else if(lifecycle_count<STABLE_N)lifecycle_count<=lifecycle_count+1'b1;

        if(crc_busy!=0) begin
            crc_accum<=crc_step;crc_busy<=crc_busy-1'b1;
        end
        // A strict indexed stream, not merely a count of valid pulses.
        if((state==S_WAIT || state==S_DRAIN) && I_read_valid) begin
            if(O_cmd!=0 || I_read_index!=read_count || read_count>=O_length || crc_busy!=0)
                read_error<=1;
            if(read_count<13'd8191)read_count<=read_count+1'b1;
            if(I_read_data!=8'hFF)all_blank<=0;
            if(read_count>=32 && I_read_data!=8'hFF)tail_blank<=0;
            if(O_cmd==0 && read_count<24 && crc_busy==0) begin
                crc_accum<=crc_accum^{24'b0,I_read_data};crc_busy<=8;
            end
            if((read_count<8 && read_count!=4) || (read_count>=16 && read_count<24)) begin
                if(I_read_data!=fixed_byte(read_count[4:0]))header_good<=0;
            end
            case(read_count)
              4:begin
                  parsed_v2<=(I_read_data==8'd2);
                  if(I_read_data!=8'd1 && I_read_data!=8'd2)header_good<=0;
              end
              15:begin
                  if(parsed_v2)begin
                      parsed_config[15:13]<=I_read_data[2:0];
                      if(I_read_data>8'd4)range_good<=0;
                  end else if(I_read_data!=0)header_good<=0;
              end
              8:parsed_seq[7:0]<=I_read_data;9:parsed_seq[15:8]<=I_read_data;
              10:parsed_seq[23:16]<=I_read_data;11:parsed_seq[31:24]<=I_read_data;
              12:begin parsed_config[12:9]<=I_read_data[3:0];
                       if(I_read_data<1 || I_read_data>9)range_good<=0;end
              13:begin parsed_config[8:5]<=I_read_data[3:0];
                       if(I_read_data>9)range_good<=0;end
              14:begin parsed_config[4:0]<=I_read_data[4:0];
                       if(I_read_data<1 || I_read_data>30)range_good<=0;end
              24:parsed_crc[7:0]<=I_read_data;25:parsed_crc[15:8]<=I_read_data;
              26:parsed_crc[23:16]<=I_read_data;27:parsed_crc[31:24]<=I_read_data;
              28,29,30,31:begin
                  if(I_read_data!=marker_byte(read_count[1:0]))marker_good<=0;
                  if((I_read_data & marker_byte(read_count[1:0]))!=marker_byte(read_count[1:0]))
                      marker_compatible<=0;
              end
              default:;
            endcase
            if(op_context==C_BODY_READ || op_context==C_FINAL_READ)
                if(I_read_data!=internal_byte)verify_good<=0;
        end
        case(state)
          S_BOOT:if(I_init_done) begin
              if(I_available)queue_command(C_BOOT,0,SLOT_A,13'd4096);
              else begin O_error<=1;start_apply(DEFAULT_CONFIG);end
          end
          S_LAUNCH:begin
              if(!I_available) begin
                  if(boot_phase)begin O_error<=1;start_apply(DEFAULT_CONFIG);end
                  else fail_save(4'd1);
              end else if(!I_cmd_busy) begin
                  O_cmd_start<=1;transaction_count<=0;state<=S_WAIT;
              end else if(transaction_count>=COMMAND_N-1) begin
                  if(boot_phase)begin O_error<=2;start_apply(DEFAULT_CONFIG);end
                  else fail_save(4'd2);
              end else transaction_count<=transaction_count+1'b1;
          end
          S_WAIT:begin
              if(I_cmd_done) begin command_error<=I_cmd_error;state<=S_DRAIN;end
              else if(transaction_count>=COMMAND_N-1) begin
                  if(boot_phase)begin O_error<=2;start_apply(DEFAULT_CONFIG);end
                  else fail_save(4'd2);
              end else transaction_count<=transaction_count+1'b1;
          end
          S_DRAIN:begin
              if(!I_read_valid && crc_busy==0)begin
                  eval_transport_good_q<=!read_error && !command_error &&
                                         (O_cmd!=0 || read_count==O_length);
                  eval_slot_valid_q<=!read_error && !command_error && read_count==4096 &&
                                     tail_blank && body_good && marker_good;
                  eval_slot_prepared_q<=!read_error && !command_error && read_count==4096 &&
                                        tail_blank && body_good && marker_compatible && !marker_good;
                  eval_payload_good_q<=verify_good && body_good &&
                                       (op_context!=C_FINAL_READ || marker_good);
                  state<=S_EVAL;
              end
              else if(transaction_count>=COMMAND_N-1)begin
                  if(boot_phase)begin O_error<=2;start_apply(DEFAULT_CONFIG);end
                  else fail_save(4'd2);
              end else transaction_count<=transaction_count+1'b1;
          end
          S_EVAL:begin
              if(op_context==C_BOOT) begin
                  slot_blank[boot_slot]<=!read_error && !command_error && read_count==4096 && all_blank;
                  slot_valid[boot_slot]<=eval_slot_valid_q;
                  slot_prepared[boot_slot]<=eval_slot_prepared_q;
                  if(boot_slot)begin seq_b<=parsed_seq;config_b<=parsed_config;state<=S_SEQ_DELTA;end
                  else begin
                      seq_a<=parsed_seq;config_a<=parsed_config;boot_slot<=1;
                      queue_command(C_BOOT,0,SLOT_B,13'd4096);
                  end
                  if(read_error || command_error || read_count!=4096)O_error<=2;
              end else if(!eval_transport_good_q) begin
                  fail_save(4'd2);
              end else case(op_context)
                C_ERASE:queue_command(C_EMPTY,0,target_addr,13'd4096);
                C_EMPTY:if(all_blank)queue_command(C_BODY_PP,2,target_addr,13'd28);
                        else fail_save(4'd5);
                C_BODY_PP:queue_command(C_BODY_READ,0,target_addr,13'd28);
                C_BODY_READ:if(eval_payload_good_q)
                                queue_command(C_MARK_PP,2,target_addr+24'd28,13'd4);
                            else fail_save(4'd5);
                C_MARK_PP:queue_command(C_FINAL_READ,0,target_addr,13'd32);
                C_FINAL_READ:if(eval_payload_good_q) begin
                    O_save_confirmed<=1;
                    active_valid<=1;active_slot<=target_slot;
                    confirmed<=snapshot;slot_blank[target_slot]<=0;slot_valid[target_slot]<=1;
                    slot_prepared[target_slot]<=0;
                    if(target_slot)begin seq_b<=snapshot_seq;config_b<=snapshot;end
                    else begin seq_a<=snapshot_seq;config_a<=snapshot;end
                    O_save_busy<=0;O_error<=0;save_blocked<=0;state<=S_IDLE;
                end else fail_save(4'd5);
                default:fail_save(4'd2);
              endcase
          end
          // Slot B was captured in EVAL; separate subtraction, comparison,
          // and wide payload selection without changing ordering policy.
          S_SEQ_DELTA:begin seq_delta_q<=seq_b-seq_a;state<=S_SEQ_PICK;end
          S_SEQ_PICK:begin
              selected_b_q<=selected_b;sequence_conflict_q<=sequence_conflict;
              state<=S_SELECT;
          end
          S_SELECT:begin
              sequence_blocked<=sequence_conflict_q;
              if(slot_valid!=0)begin
                  active_valid<=1;active_slot<=selected_b_q;
                  start_apply(selected_b_q ? config_b:config_a);
              end else start_apply(DEFAULT_CONFIG);
              if(sequence_conflict_q)O_error<=6;
              else if((!(slot_blank[0] || slot_valid[0] || slot_prepared[0])) ||
                      (!(slot_blank[1] || slot_valid[1] || slot_prepared[1])))begin
                  if(O_error==0)O_error<=4;
              end
          end
          S_APPLY:begin
              if(I_restore_ack)begin
                  O_restore_valid<=0;O_ready<=1;observed<=O_restore_config;
                  lifecycle_count<=0;state<=S_IDLE;
              end else if(transaction_count>=APPLY_N-1)begin
                  O_restore_valid<=0;O_error<=7;state<=S_APP_FAIL;
              end else transaction_count<=transaction_count+1'b1;
          end
          S_IDLE:begin
              if(!current_good)O_error<=3;
              else if(!I_editing && O_dirty && lifecycle_count>=STABLE_N && !save_blocked && I_current_config==observed && eligibility_ready_q)begin
                  if(!I_init_done || !I_available)begin O_error<=1;save_blocked<=1;end
                  else if(sequence_blocked)begin O_error<=6;save_blocked<=1;end
                  else if(!target_eligible_q)begin O_error<=4;save_blocked<=1;end
                  else begin
                      target_slot<=active_valid ? inactive : (!slot_blank[0]);
                      snapshot<=I_current_config;snapshot_seq<=active_valid ? active_seq+32'd1:32'd0;
                      retry_used<=0;O_save_busy<=1;gen_index<=0;crc_accum<=32'hFFFFFFFF;
                      crc_busy<=0;state<=S_GEN_FEED;
                  end
              end
          end
          S_GEN_FEED:begin
              crc_accum<=crc_accum^{24'b0,internal_byte};crc_busy<=8;
              state<=S_GEN_SHIFT;
          end
          S_GEN_SHIFT:if(crc_busy==1)begin
              if(gen_index==23)begin snapshot_crc<=crc_step^32'hFFFFFFFF;state<=S_ERASE;end
              else begin gen_index<=gen_index+1'b1;state<=S_GEN_FEED;end
          end
          S_ERASE:queue_command(C_ERASE,1,target_addr,13'd4096);
          S_APP_FAIL:;
          default:begin O_error<=2;O_save_busy<=0;state<=S_APP_FAIL;end
        endcase
        // Total boot deadline also covers malformed/no-response full reads.
        // boot counter starts at zero and saturates at BOOT_N-1.
        // Equality is the same deadline on every reachable boot state.
        if(boot_phase && lifecycle_count==BOOT_N-1)begin
            O_cmd_start<=0;O_error<=2;start_apply(DEFAULT_CONFIG);
        end
    end
end
endmodule

// compact passive observations. None of these outputs drives playback.
// Record77={code8,image16,detail8,settings13,time32}. No hardware duration/LBA.


// Five source-owned held slots. ACK applies only to diagnostic buffers.
// No record is duplicated here; FIFO refusal still cannot stall media.


// Flash final verification pulse is supplied by the existing transaction FSM.


// FireWater: decimal brightness,volume,period followed by one real LF (0A).
// Startup/change samples have 6 or 7 bytes. Error text ERR=1/2/3 has 6 bytes.
// No carriage return or literal backslash-n bytes are transmitted.


// the reference clock remains running while derived PLLs restart.
// All intervals below are 50 MHz reference-clock cycles, not PLL clocks.
module clock_startup_supervisor #(
    parameter integer QUIESCE_CYCLES = 50000,
    parameter integer PLL_RESET_CYCLES = 50000,
    parameter integer LOCK_STABLE_CYCLES = 1000000,
    parameter integer LOCK_TIMEOUT_CYCLES = 5000000,
    parameter integer MAX_LOCK_RETRIES = 2
)(
    input wire I_clk,
    input wire I_rst_n,
    input wire I_sys_lock,
    input wire I_video_lock,
    output reg O_pll_reset = 1'b0,
    (* max_fanout = 4 *) output reg O_rst = 1'b1,
    (* dont_touch = "true", max_fanout = 4 *) output reg O_rst_mem = 1'b1
);
    localparam integer PHASE_MAX = (QUIESCE_CYCLES > PLL_RESET_CYCLES) ? QUIESCE_CYCLES : PLL_RESET_CYCLES;
    localparam integer PHASE_WIDTH = (PHASE_MAX < 2) ? 1 : $clog2(PHASE_MAX);
    localparam integer STABLE_WIDTH = (LOCK_STABLE_CYCLES < 2) ? 1 : $clog2(LOCK_STABLE_CYCLES);
    localparam integer WAIT_WIDTH = (LOCK_TIMEOUT_CYCLES < 2) ? 1 : $clog2(LOCK_TIMEOUT_CYCLES);
    localparam integer RETRY_WIDTH = (MAX_LOCK_RETRIES < 1) ? 1 : $clog2(MAX_LOCK_RETRIES + 1);
    localparam [2:0] ST_QUIESCE = 3'd0, ST_PLL_HOLD = 3'd1,
                     ST_WAIT_LOCK = 3'd2, ST_RUN = 3'd3, ST_FAULT = 3'd4;

    (* async_reg = "true" *) reg [2:0] ref_reset_sync = 3'b111;
    wire ref_reset = ref_reset_sync[2];
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) ref_reset_sync <= 3'b111;
        else ref_reset_sync <= {ref_reset_sync[1:0], 1'b0};
    end

    // Raw lock status terminates only at each chain's first stage.
    // Explicit reset prevents a previous lock indication surviving a restart.
    (* async_reg = "true" *) reg [2:0] sys_lock_sync = 3'b000;
    (* async_reg = "true" *) reg [2:0] video_lock_sync = 3'b000;
    always @(posedge I_clk or posedge O_pll_reset) begin
        if (O_pll_reset) begin
            sys_lock_sync <= 3'b000;
            video_lock_sync <= 3'b000;
        end else begin
            sys_lock_sync <= {sys_lock_sync[1:0], I_sys_lock};
            video_lock_sync <= {video_lock_sync[1:0], I_video_lock};
        end
    end
    wire locks_ready = sys_lock_sync[2] && video_lock_sync[2];
    reg [2:0] state = ST_QUIESCE;
    reg [PHASE_WIDTH-1:0] phase_count = {PHASE_WIDTH{1'b0}};
    reg [STABLE_WIDTH-1:0] lock_good_count = {STABLE_WIDTH{1'b0}};
    reg [WAIT_WIDTH-1:0] wait_count = {WAIT_WIDTH{1'b0}};
    reg [RETRY_WIDTH-1:0] retry_count = {RETRY_WIDTH{1'b0}};
    wire start_ready = (state == ST_WAIT_LOCK) && locks_ready &&
                       (lock_good_count >= LOCK_STABLE_CYCLES - 1);

    // A short external reset immediately holds all business logic. The PLLs
    // keep running until the sequencer has given synchronous consumers time.
    always @(posedge I_clk or posedge ref_reset) begin
        if (ref_reset) O_rst <= 1'b1;
        else if (start_ready || ((state == ST_RUN) && locks_ready)) O_rst <= 1'b0;
        else O_rst <= 1'b1;
    end

    // Parallel same-D source; do not sample O_rst or add a release cycle.
    always @(posedge I_clk or posedge ref_reset) begin
        if (ref_reset) O_rst_mem <= 1'b1;
        else if (start_ready || ((state == ST_RUN) && locks_ready)) O_rst_mem <= 1'b0;
        else O_rst_mem <= 1'b1;
    end

    // No reset-feedback dependency on PLL clocks or the downstream audio lock.
    // A sampled runtime lock loss restarts the whole business domain group.
    always @(posedge I_clk) begin
        case (state)
            ST_QUIESCE: begin
                O_pll_reset <= 1'b0;
                lock_good_count <= 0;
                wait_count <= 0;
                if (ref_reset) retry_count <= 0;
                if (phase_count >= QUIESCE_CYCLES - 1) begin
                    phase_count <= 0;
                    O_pll_reset <= 1'b1;
                    state <= ST_PLL_HOLD;
                end else phase_count <= phase_count + 1'b1;
            end
            ST_PLL_HOLD: begin
                O_pll_reset <= 1'b1;
                lock_good_count <= 0;
                wait_count <= 0;
                if (ref_reset) begin
                    phase_count <= 0;
                    retry_count <= 0;
                end else if (phase_count >= PLL_RESET_CYCLES - 1) begin
                    phase_count <= 0;
                    O_pll_reset <= 1'b0;
                    state <= ST_WAIT_LOCK;
                end else phase_count <= phase_count + 1'b1;
            end
            ST_WAIT_LOCK: begin
                O_pll_reset <= 1'b0;
                phase_count <= 0;
                if (ref_reset) begin
                    retry_count <= 0;
                    lock_good_count <= 0;
                    wait_count <= 0;
                    state <= ST_QUIESCE;
                end else if (start_ready) begin
                    retry_count <= 0;
                    lock_good_count <= 0;
                    wait_count <= 0;
                    state <= ST_RUN;
                end else if (wait_count >= LOCK_TIMEOUT_CYCLES - 1) begin
                    lock_good_count <= 0;
                    wait_count <= 0;
                    if (retry_count < MAX_LOCK_RETRIES) begin
                        retry_count <= retry_count + 1'b1;
                        state <= ST_QUIESCE;
                    end else state <= ST_FAULT;
                end else begin
                    wait_count <= wait_count + 1'b1;
                    if (locks_ready) lock_good_count <= lock_good_count + 1'b1;
                    else lock_good_count <= 0;
                end
            end
            ST_RUN: begin
                O_pll_reset <= 1'b0;
                phase_count <= 0;
                lock_good_count <= 0;
                wait_count <= 0;
                retry_count <= 0;
                if (ref_reset || !locks_ready) state <= ST_QUIESCE;
            end
            ST_FAULT: begin
                // Stop automatic retries with business logic held in reset.
                O_pll_reset <= 1'b0;
                phase_count <= 0;
                lock_good_count <= 0;
                wait_count <= 0;
                if (ref_reset) begin
                    retry_count <= 0;
                    state <= ST_QUIESCE;
                end
            end
            default: begin
                O_pll_reset <= 1'b0;
                phase_count <= 0;
                lock_good_count <= 0;
                wait_count <= 0;
                retry_count <= 0;
                state <= ST_QUIESCE;
            end
        endcase
    end
endmodule

// Always-on reference-clock ownership of the physical K1 press.
// Power-on values hold the existing startup sequencer in reset until release.
// A sleep press is owned as WAKE until release, even after sleeping falls.
module player_reset_wake_080 #(
    parameter integer DEBOUNCE_CYCLES=2500000
)(
    input wire clk,key_n,sleeping,
    output reg reset_n=1'b0,
    output reg wake_level=1'b0,
    output wire sleep_state
);
localparam integer CW=DEBOUNCE_CYCLES>1?$clog2(DEBOUNCE_CYCLES):1;
(* async_reg="true" *) reg [2:0] key_sync=3'b000;
(* async_reg="true" *) reg [2:0] sleep_sync=3'b000;
// reuse the existing final synchronizer stage; no new state or clock.
assign sleep_state=sleep_sync[2];
reg key_stable=1'b0;
reg [CW-1:0] count=0;
always @(posedge clk) begin
    key_sync<={key_sync[1:0],key_n};
    sleep_sync<={sleep_sync[1:0],sleeping};
    if(key_sync[2]==key_stable)count<=0;
    else if(count==DEBOUNCE_CYCLES-1)begin
        count<=0;key_stable<=key_sync[2];
        if(key_sync[2])begin reset_n<=1;wake_level<=0;end
        else if(reset_n&&sleep_sync[2])wake_level<=1;
        else begin reset_n<=0;wake_level<=0;end
    end else count<=count+1'b1;
end
endmodule
