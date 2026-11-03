
# 安映多媒体展示终端时序约束

# 50 MHz参考时钟；PLL推导视频、存储与音频时钟。

# 同步级间路径正常计时；跨域握手仅约束首级和稳定载荷。

# SDRAM读捕获关系与顶层读有效对齐逻辑配套。

# 板级输入主时钟：50 MHz，周期20 ns。

create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# 根据PLL实例推导系统、视频和音频前级时钟。

derive_clocks -instance [get_cells {sys_pll_m0/pll_inst}]
derive_clocks -instance [get_cells {video_pll_m0/pll_inst}]
derive_clocks -instance [get_cells {u_audio_clock/u_audio_pre_pll/pll_inst}]

# 按实际PLL输出命名时钟。

rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]

rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]

rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]

rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]

# 像素时钟和串行时钟同时工作，保留正常setup/hold分析。

# Independent audio clocks.

rename_clock -name {audio_pre_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_audio_clock/u_audio_pre_pll/pll_inst.clkc[2]}]

# TD's automatic derivation does not propagate cascaded PLL ratios; specify stage two.

create_generated_clock -name {audio_mclk} -source [get_pins {u_audio_clock/u_audio_pre_pll/pll_inst.clkc[2]}] -divide_by 7.8125 [get_pins {u_audio_clock/u_audio_pll/pll_inst.clkc[2]}]

create_generated_clock -name {audio_feedback_clk} -source [get_pins {u_audio_clock/u_audio_pre_pll/pll_inst.clkc[2]}] -multiply_by 3.2 [get_pins {u_audio_clock/u_audio_pll/pll_inst.clkc[0]}]

# The only audio sample crossing is the receiver's three-stage I2S synchronizers.

# Audio/video crossings use held-payload and request/acknowledge budgets.

# Only asynchronous assertion inputs of the new reset synchronizers are excluded.

# Deassertion and all downstream audio logic remain timed in their own clock domain.

set_false_path -from [get_clocks {clk}] -to [get_regs -hier {u_audio_pipeline/mclk_reset_sync*}]

set_false_path -from [get_clocks {clk}] -to [get_regs -hier {u_audio_pipeline/pixel_reset_sync*}]

# SDRAM DQ read capture: paired with sdram_rd_en_align in the top-level RTL.

# The forwarded-clock/DQ round trip delivers this beat at the following

# memory capture edge. Scope this relation to the 32 hard-SDRAM DQ outputs.

# Do not add a compensating hold exception: retain the next-beat hold check.

set_multicycle_path -setup -end -from [get_pins -hier {U3/sdram.dq*}] -to [get_clocks {ext_mem_clk}] 2

# display-commit cue mailbox only (SD 100MHz -> audio 12.288MHz).

# Tokens enter three-stage synchronizers; bundled note stays unchanged until ACK.

# TD wildcard get_regs may include upstream driver aliases: use routed exact nets.

# Bound only direct first-stage crossing wires; later sync stages stay timed.

set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/u_cue_mailbox/source_req}] -to [get_regs {u_audio_pipeline/u_cue_mailbox/req_sync\[0\]}] 10

set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/u_cue_mailbox/audio_ack}] -to [get_regs {u_audio_pipeline/u_cue_mailbox/ack_sync\[0\]}] 10

# TD can retain unused copied release FFs without Q-net names. Bound the raw

# asynchronous assertion entry itself, limited to the audio clock destinations.

# Stage0-to-stage1 data and synchronous reset release do not cross this raw net.

set_false_path -from [get_clocks {clk}] -through [get_nets {u_audio_pipeline/I_rst}] -to [get_clocks {audio_mclk}]

# single-token transition crossings only. All payload bank ownership

# remains held by SD until the visible ACK; fade gain is local to video_clk.

set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/display_commit_req}] -to [get_regs {u_transition/req_sync\[0\]}] 10

set_max_delay -datapath_only -from [get_regs {u_frame_display_commit/commit_ack}] -to [get_regs {u_transition/reader_ack_sync\[0\]}] 8

set_max_delay -datapath_only -from [get_regs {u_transition/reader_req_q}] -to [get_regs {u_frame_display_commit/commit_req_sync\[0\]}] 8

set_max_delay -datapath_only -from [get_regs {u_transition/visible_ack_q}] -to [get_regs {sd_card_bmp_m0/commit_ack_sync\[0\]}] 10

# asynchronous switches terminate at their native PAD input FFs.

# Only these two port-source input paths are exempt; clock/Q -> sync1 remains timed.

# Native PAD INFFs are not get_regs collections. Debounce and UI remain timed.

set_false_path -from [get_ports {sw1}]

set_false_path -from [get_ports {sw2}]

# Latest-value mailboxes hold source payload until the three-stage ACK returns.

# Bound tokens only into sync[0], and held payload only into destination capture.

# All following synchronizer stages and gain/scan logic retain normal timing.

set_max_delay -datapath_only -from [get_regs {u_brightness_mailbox/source_req}] -to [get_regs {u_brightness_mailbox/req_sync\[0\]}] 10

set_max_delay -datapath_only -from [get_regs {u_brightness_mailbox/dest_ack}] -to [get_regs {u_brightness_mailbox/ack_sync\[0\]}] 10

set_max_delay -datapath_only -from [get_regs {u_brightness_mailbox/source_value\[0\] u_brightness_mailbox/source_value\[1\] u_brightness_mailbox/source_value\[2\] u_brightness_mailbox/source_value\[3\]}] -to [get_regs {u_brightness_mailbox/O_value\[0\] u_brightness_mailbox/O_value\[1\] u_brightness_mailbox/O_value\[2\] u_brightness_mailbox/O_value\[3\]}] 40

# user-Flash Mode0 SPI uses CE in sd_card_clk, no generated clock.

# MISO is asynchronous only at the PAD input synchronizer; sync1 stays timed.

set_false_path -from [get_ports {user_flash_miso}]

# Route only registered CS/SCK/MOSI launch paths within 10ns. Protocol half

# periods are >=500ns, CS high >=1us; verify pad edges and the second MISO FF.

set_max_delay -datapath_only -from [get_clocks {sd_card_clk}] -to [get_ports {user_flash_cs_n user_flash_sck user_flash_mosi}] 10

# Configuration warnings use a separate stable-payload mailbox into clk50.

# Diagnostic values cross through held-payload/capture handshakes.

# Payloads remain stable until acknowledged.

# Limit only crossing tokens into first FF and held buses into capture FFs;

# every later sync/BCD/scanner path remains normally timed, clocks unchanged.

set_max_delay -datapath_only -from [get_regs {u_diagnostics_mailbox/source_req}] -to [get_regs {u_diagnostics_mailbox/req_sync\[0\]}] 10

set_max_delay -datapath_only -from [get_regs {u_diagnostics_mailbox/dest_ack}] -to [get_regs {u_diagnostics_mailbox/ack_sync\[0\]}] 10

set_max_delay -datapath_only -from [get_regs {u_diagnostics_mailbox/source_value\[0\] u_diagnostics_mailbox/source_value\[1\] u_diagnostics_mailbox/source_value\[2\] u_diagnostics_mailbox/source_value\[3\] }] -to [get_regs {u_diagnostics_mailbox/O_value\[0\] u_diagnostics_mailbox/O_value\[1\] u_diagnostics_mailbox/O_value\[2\] u_diagnostics_mailbox/O_value\[3\] }] 20

# K1 is sampled in the always-on reference domain.

# All stage-to-stage and downstream paths retain normal timing.

# K1 is sampled by the always-on reference-domain ownership block.
# raw K1 only feeds PAD IN_DFF first synchronizer. Later stages and generated reset remain timed.
set_false_path -from [get_ports {rst_n}]

# Raw PLL extlock status has no TD launch timing arc. Its single-bit

# three-stage synchronizers and exclusive first-stage fanout are verified

# structurally; only subsequent stages have ordinary setup/hold claims.

# Atomic OSD mailbox only. Held state/activity are captured

# after three destination request stages and held until three-stage ACK.

# Bound token first-stage routes to 10ns and stable data routes to 40ns;

# later synchronizer stages and pixel logic remain normally timed.

set_max_delay -datapath_only -from [get_regs {u_osd_bridge/source_req}] -to [get_regs {u_osd_bridge/req_sync\[0\]}] 10

set_max_delay -datapath_only -from [get_regs {u_osd_bridge/dest_ack}] -to [get_regs {u_osd_bridge/ack_sync\[0\]}] 10

set_max_delay -datapath_only -from [get_regs {u_osd_bridge/source_state\[0\] u_osd_bridge/source_state\[1\] u_osd_bridge/source_state\[2\] u_osd_bridge/source_state\[3\] u_osd_bridge/source_state\[4\] u_osd_bridge/source_state\[5\] u_osd_bridge/source_state\[6\] u_osd_bridge/source_state\[7\] u_osd_bridge/source_state\[8\] u_osd_bridge/source_state\[9\] u_osd_bridge/source_state\[10\] u_osd_bridge/source_state\[11\] u_osd_bridge/source_state\[12\] u_osd_bridge/source_state\[13\] u_osd_bridge/source_state\[14\] u_osd_bridge/source_state\[15\] u_osd_bridge/source_state\[16\]}] -to [get_regs {u_osd_bridge/O_state\[0\] u_osd_bridge/O_state\[1\] u_osd_bridge/O_state\[2\] u_osd_bridge/O_state\[3\] u_osd_bridge/O_state\[4\] u_osd_bridge/O_state\[5\] u_osd_bridge/O_state\[6\] u_osd_bridge/O_state\[7\] u_osd_bridge/O_state\[8\] u_osd_bridge/O_state\[9\] u_osd_bridge/O_state\[10\] u_osd_bridge/O_state\[11\] u_osd_bridge/O_state\[12\] u_osd_bridge/O_state\[13\] u_osd_bridge/O_state\[14\] u_osd_bridge/O_state\[15\] u_osd_bridge/O_state\[16\]}] 40

set_max_delay -datapath_only -from [get_regs {u_osd_bridge/source_activity}] -to [get_regs {u_osd_bridge/O_activity}] 40

# SW4 PAD synchronizer and held request/ACK payloads.

set_false_path -from [get_ports {sw4}]

set_max_delay -datapath_only -from [get_regs {u_transform_config/source_req}] -to [get_regs {u_transform_config/req_sync\[0\]}] 10

set_max_delay -datapath_only -from [get_regs {u_transform_config/dest_ack}] -to [get_regs {u_transform_config/ack_sync\[0\]}] 10

set_max_delay -datapath_only -from [get_regs {u_transform_config/source_value\[0\] u_transform_config/source_value\[1\] u_transform_config/source_value\[2\] u_transform_config/source_value\[3\] u_transform_config/source_value\[4\] u_transform_config/source_value\[5\] u_transform_config/source_value\[6\] u_transform_config/source_value\[7\] u_transform_config/source_value\[8\]}] -to [get_regs {u_transform_config/O_value\[0\] u_transform_config/O_value\[1\] u_transform_config/O_value\[2\] u_transform_config/O_value\[3\] u_transform_config/O_value\[4\] u_transform_config/O_value\[5\] u_transform_config/O_value\[6\] u_transform_config/O_value\[7\] u_transform_config/O_value\[8\]}] 8

# Coherent session/OSD: upper20 payload bits, same existing request/ACK.

set_max_delay -datapath_only -from [get_regs {u_osd_bridge/source_state\[17\] u_osd_bridge/source_state\[18\] u_osd_bridge/source_state\[19\] u_osd_bridge/source_state\[20\] u_osd_bridge/source_state\[21\] u_osd_bridge/source_state\[22\] u_osd_bridge/source_state\[23\] u_osd_bridge/source_state\[24\] u_osd_bridge/source_state\[25\] u_osd_bridge/source_state\[26\] u_osd_bridge/source_state\[27\] u_osd_bridge/source_state\[28\] u_osd_bridge/source_state\[29\] u_osd_bridge/source_state\[30\] u_osd_bridge/source_state\[31\] u_osd_bridge/source_state\[32\] u_osd_bridge/source_state\[33\] u_osd_bridge/source_state\[34\] u_osd_bridge/source_state\[35\] u_osd_bridge/source_state\[36\]}] -to [get_regs {u_osd_bridge/O_state\[17\] u_osd_bridge/O_state\[18\] u_osd_bridge/O_state\[19\] u_osd_bridge/O_state\[20\] u_osd_bridge/O_state\[21\] u_osd_bridge/O_state\[22\] u_osd_bridge/O_state\[23\] u_osd_bridge/O_state\[24\] u_osd_bridge/O_state\[25\] u_osd_bridge/O_state\[26\] u_osd_bridge/O_state\[27\] u_osd_bridge/O_state\[28\] u_osd_bridge/O_state\[29\] u_osd_bridge/O_state\[30\] u_osd_bridge/O_state\[31\] u_osd_bridge/O_state\[32\] u_osd_bridge/O_state\[33\] u_osd_bridge/O_state\[34\] u_osd_bridge/O_state\[35\] u_osd_bridge/O_state\[36\]}] 40

# SW3 asynchronous PAD; subsequent debounced logic remains timed.
set_false_path -from [get_ports {sw3}]
# FIFO Gray source registers to ONLY their first synchronizer stage.
# Both directions bounded to 8ns (< fastest source period 10ns), all following stages timed.
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg\[0\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg_meta\[0\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg\[1\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg_meta\[1\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg\[2\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg_meta\[2\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg\[3\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg_meta\[3\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg\[4\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg_meta\[4\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg\[5\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg_meta\[5\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg\[6\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg_meta\[6\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg\[7\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg_meta\[7\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg\[8\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg_meta\[8\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg\[9\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg_meta\[9\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg\[10\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg_meta\[10\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg\[11\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/wg_meta\[11\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg\[0\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg_meta\[0\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg\[1\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg_meta\[1\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg\[2\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg_meta\[2\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg\[3\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg_meta\[3\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg\[4\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg_meta\[4\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg\[5\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg_meta\[5\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg\[6\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg_meta\[6\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg\[7\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg_meta\[7\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg\[8\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg_meta\[8\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg\[9\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg_meta\[9\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg\[10\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg_meta\[10\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg\[11\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/fifo/rg_meta\[11\]}] 8
# Reset assertion terminates at local release synchronizers only.
# The through filter excludes stage-to-stage D paths and downstream reset release.
# exact raw assertion nets: global reset and per-track flush. D paths/downstream release remain timed.
set_false_path -through [get_nets {sd_card_bmp_m0/g_music$player/common_reset}] -to [get_regs {sd_card_bmp_m0/g_music$player/wr_reset\[0\] sd_card_bmp_m0/g_music$player/wr_reset\[1\] sd_card_bmp_m0/g_music$player/flush_ack\[0\] sd_card_bmp_m0/g_music$player/flush_ack\[1\]}]
set_false_path -through [get_nets {sd_card_bmp_m0/g_music$player/audio_flush_reset_n}] -to [get_regs {sd_card_bmp_m0/g_music$player/rd_reset\[0\] sd_card_bmp_m0/g_music$player/rd_reset\[1\]}]
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_music$player/rd_reset\[1\]}] -to [get_regs {sd_card_bmp_m0/g_music$player/flush_ack\[0\]}] 8
# Volume/sleep held payload request/ACK mailbox SD -> MCLK.
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$control_mailbox/source_req}] -to [get_regs {u_audio_pipeline/g_file$control_mailbox/req_sync\[0\]}] 10
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$control_mailbox/dest_ack}] -to [get_regs {u_audio_pipeline/g_file$control_mailbox/ack_sync\[0\]}] 10
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$control_mailbox/source_value\[0\] u_audio_pipeline/g_file$control_mailbox/source_value\[1\] u_audio_pipeline/g_file$control_mailbox/source_value\[2\] u_audio_pipeline/g_file$control_mailbox/source_value\[3\] u_audio_pipeline/g_file$control_mailbox/source_value\[4\] u_audio_pipeline/g_file$control_mailbox/source_value\[5\]}] -to [get_regs {u_audio_pipeline/g_file$control_mailbox/O_value\[0\] u_audio_pipeline/g_file$control_mailbox/O_value\[1\] u_audio_pipeline/g_file$control_mailbox/O_value\[2\] u_audio_pipeline/g_file$control_mailbox/O_value\[3\] u_audio_pipeline/g_file$control_mailbox/O_value\[4\] u_audio_pipeline/g_file$control_mailbox/O_value\[5\]}] 80
# Extended OSD state: same existing three-stage request/ACK contract.
set_max_delay -datapath_only -from [get_regs {u_osd_bridge/source_state\[37\] u_osd_bridge/source_state\[38\] u_osd_bridge/source_state\[39\] u_osd_bridge/source_state\[40\] u_osd_bridge/source_state\[41\] u_osd_bridge/source_state\[42\] u_osd_bridge/source_state\[43\] u_osd_bridge/source_state\[44\] u_osd_bridge/source_state\[45\] u_osd_bridge/source_state\[46\] u_osd_bridge/source_state\[47\] u_osd_bridge/source_state\[48\] u_osd_bridge/source_state\[49\] u_osd_bridge/source_state\[50\] u_osd_bridge/source_state\[51\] u_osd_bridge/source_state\[52\] u_osd_bridge/source_state\[53\] u_osd_bridge/source_state\[54\] u_osd_bridge/source_state\[55\] u_osd_bridge/source_state\[56\] u_osd_bridge/source_state\[57\] u_osd_bridge/source_state\[58\] u_osd_bridge/source_state\[59\] u_osd_bridge/source_state\[60\] u_osd_bridge/source_state\[61\] u_osd_bridge/source_state\[62\] u_osd_bridge/source_state\[63\]}] -to [get_regs {u_osd_bridge/O_state\[37\] u_osd_bridge/O_state\[38\] u_osd_bridge/O_state\[39\] u_osd_bridge/O_state\[40\] u_osd_bridge/O_state\[41\] u_osd_bridge/O_state\[42\] u_osd_bridge/O_state\[43\] u_osd_bridge/O_state\[44\] u_osd_bridge/O_state\[45\] u_osd_bridge/O_state\[46\] u_osd_bridge/O_state\[47\] u_osd_bridge/O_state\[48\] u_osd_bridge/O_state\[49\] u_osd_bridge/O_state\[50\] u_osd_bridge/O_state\[51\] u_osd_bridge/O_state\[52\] u_osd_bridge/O_state\[53\] u_osd_bridge/O_state\[54\] u_osd_bridge/O_state\[55\] u_osd_bridge/O_state\[56\] u_osd_bridge/O_state\[57\] u_osd_bridge/O_state\[58\] u_osd_bridge/O_state\[59\] u_osd_bridge/O_state\[60\] u_osd_bridge/O_state\[61\] u_osd_bridge/O_state\[62\] u_osd_bridge/O_state\[63\]}] 40
# View mode and snapshot mask held from SD request through visible ACK.
# Captured only after pixel request synchronizer plus memory synchronizer, at black.
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/thumbnail_layout}] -to [get_regs {u_frame_display_commit/read_view\[4\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/thumbnail_mask\[0\]}] -to [get_regs {u_frame_display_commit/read_view\[0\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/thumbnail_mask\[1\]}] -to [get_regs {u_frame_display_commit/read_view\[1\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/thumbnail_mask\[2\]}] -to [get_regs {u_frame_display_commit/read_view\[2\]}] 8
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/thumbnail_mask\[3\]}] -to [get_regs {u_frame_display_commit/read_view\[3\]}] 8

# single-bit sleep/wake CDC; subsequent synchronizer stages stay ordinarily timed.
set_max_delay -datapath_only -from [get_regs {sd_card_bmp_m0/g_ui078$u_control/sleeping}] -to [get_regs {u_user_reset/sleep_sync\[0\]}] 20
set_max_delay -datapath_only -from [get_regs {u_user_reset/wake_level}] -to [get_regs {sd_card_bmp_m0/g_ui078$u_control/wake_sync\[0\]}] 10

# Cue local reset: exclude only raw assertion net, not synchronizer D or downstream release.
set_false_path -through [get_nets {u_audio_pipeline/I_rst}] -to [get_regs {u_audio_pipeline/u_cue_mailbox/source_reset_sync\[0\] u_audio_pipeline/u_cue_mailbox/source_reset_sync\[1\]}]

# premaster meter shares the existing held PCM request/ACK token.
# Each same-bit destination samples only after the unchanged 3-stage request synchronizer.
# Payload remains held until ACK; these additive budgets do not cut ordinary stages.
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[0\]}] -to [get_regs {u_audio_pipeline/meter_sample\[0\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[1\]}] -to [get_regs {u_audio_pipeline/meter_sample\[1\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[2\]}] -to [get_regs {u_audio_pipeline/meter_sample\[2\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[3\]}] -to [get_regs {u_audio_pipeline/meter_sample\[3\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[4\]}] -to [get_regs {u_audio_pipeline/meter_sample\[4\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[5\]}] -to [get_regs {u_audio_pipeline/meter_sample\[5\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[6\]}] -to [get_regs {u_audio_pipeline/meter_sample\[6\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[7\]}] -to [get_regs {u_audio_pipeline/meter_sample\[7\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[8\]}] -to [get_regs {u_audio_pipeline/meter_sample\[8\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[9\]}] -to [get_regs {u_audio_pipeline/meter_sample\[9\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[10\]}] -to [get_regs {u_audio_pipeline/meter_sample\[10\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[11\]}] -to [get_regs {u_audio_pipeline/meter_sample\[11\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[12\]}] -to [get_regs {u_audio_pipeline/meter_sample\[12\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[13\]}] -to [get_regs {u_audio_pipeline/meter_sample\[13\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[14\]}] -to [get_regs {u_audio_pipeline/meter_sample\[14\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/meter_word\[15\]}] -to [get_regs {u_audio_pipeline/meter_sample\[15\]}] 40

# PCM payload and handshake first-stage budgets.
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[0\]}] -to [get_regs {u_audio_pipeline/audio_left\[0\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[1\]}] -to [get_regs {u_audio_pipeline/audio_left\[1\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[2\]}] -to [get_regs {u_audio_pipeline/audio_left\[2\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[3\]}] -to [get_regs {u_audio_pipeline/audio_left\[3\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[4\]}] -to [get_regs {u_audio_pipeline/audio_left\[4\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[5\]}] -to [get_regs {u_audio_pipeline/audio_left\[5\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[6\]}] -to [get_regs {u_audio_pipeline/audio_left\[6\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[7\]}] -to [get_regs {u_audio_pipeline/audio_left\[7\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[8\]}] -to [get_regs {u_audio_pipeline/audio_left\[8\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[9\]}] -to [get_regs {u_audio_pipeline/audio_left\[9\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[10\]}] -to [get_regs {u_audio_pipeline/audio_left\[10\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[11\]}] -to [get_regs {u_audio_pipeline/audio_left\[11\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[12\]}] -to [get_regs {u_audio_pipeline/audio_left\[12\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[13\]}] -to [get_regs {u_audio_pipeline/audio_left\[13\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[14\]}] -to [get_regs {u_audio_pipeline/audio_left\[14\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[15\]}] -to [get_regs {u_audio_pipeline/audio_left\[15\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[16\]}] -to [get_regs {u_audio_pipeline/audio_left\[16\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[17\]}] -to [get_regs {u_audio_pipeline/audio_left\[17\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[18\]}] -to [get_regs {u_audio_pipeline/audio_left\[18\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[19\]}] -to [get_regs {u_audio_pipeline/audio_left\[19\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[20\]}] -to [get_regs {u_audio_pipeline/audio_left\[20\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[21\]}] -to [get_regs {u_audio_pipeline/audio_left\[21\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[22\]}] -to [get_regs {u_audio_pipeline/audio_left\[22\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_word\[23\]}] -to [get_regs {u_audio_pipeline/audio_left\[23\]}] 40
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/g_file$source/sample_req}] -to [get_regs {u_audio_pipeline/sample_req_sync\[0\]}] 10
set_max_delay -datapath_only -from [get_regs {u_audio_pipeline/sample_ack}] -to [get_regs {u_audio_pipeline/g_file$source/ack_sync\[0\]}] 10

#async UART input: only the synchronizer first stage is excepted.
# RX first FF packs into the input PAD. Audit requires its ONLY raw-input sink,
# ONLY meta-to-sync fanout, and ordinary timed 10ns second-stage setup/hold.
set_false_path -from [get_ports {uart_rx}]
#TX pad budget; UART baud derives from the 100MHz clock.
set_max_delay -datapath_only -from [get_clocks {sd_card_clk}] -to [get_ports {uart_tx}] 10

# LED indicators are asynchronous to viewers; retain a10ns internal output route budget.
set_max_delay -datapath_only -from [get_clocks {sd_card_clk}] -to [get_ports {cache_led[0] cache_led[1] cache_led[2] cache_led[3]}] 10

#asynchronous demodulated IR input; only raw input synchronizer is excluded.
set_false_path -from [get_ports {ir_rx}]

# held contrast/focus/32-song metadata; same handshake and 40 ns payload budget.
set_max_delay -datapath_only -from [get_regs {u_osd_bridge/source_state\[64\] u_osd_bridge/source_state\[65\] u_osd_bridge/source_state\[66\] u_osd_bridge/source_state\[67\] u_osd_bridge/source_state\[68\] u_osd_bridge/source_state\[69\] u_osd_bridge/source_state\[70\] u_osd_bridge/source_state\[71\] u_osd_bridge/source_state\[72\] u_osd_bridge/source_state\[73\] u_osd_bridge/source_state\[74\] u_osd_bridge/source_state\[75\] u_osd_bridge/source_state\[76\] u_osd_bridge/source_state\[77\] u_osd_bridge/source_state\[78\] u_osd_bridge/source_state\[79\] u_osd_bridge/source_state\[80\]}] -to [get_regs {u_osd_bridge/O_state\[64\] u_osd_bridge/O_state\[65\] u_osd_bridge/O_state\[66\] u_osd_bridge/O_state\[67\] u_osd_bridge/O_state\[68\] u_osd_bridge/O_state\[69\] u_osd_bridge/O_state\[70\] u_osd_bridge/O_state\[71\] u_osd_bridge/O_state\[72\] u_osd_bridge/O_state\[73\] u_osd_bridge/O_state\[74\] u_osd_bridge/O_state\[75\] u_osd_bridge/O_state\[76\] u_osd_bridge/O_state\[77\] u_osd_bridge/O_state\[78\] u_osd_bridge/O_state\[79\] u_osd_bridge/O_state\[80\]}] 40
