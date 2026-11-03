module hdmi_audio_pipeline #(
    parameter signed [23:0] AMP = 24'sd2000000,
    parameter integer NOTE_HOLD_FRAMES = 24000,
    parameter integer CUE_MODE = 1,
    parameter integer FILE_MODE = 0,
    parameter integer VOLUME_ENABLE = 1,
    parameter signed [23:0] CUE_AMP = 24'sd500000,
    parameter integer CUE_ATTACK_SAMPLES = 480,
    parameter integer CUE_HOLD_SAMPLES = 8640,
    parameter integer CUE_RELEASE_SAMPLES = 960,
    parameter integer CUE_RESTART_FADE_SAMPLES = 240
)(
    input wire I_sleep,I_music_paused,
    input wire [15:0] I_file_data,
    input wire I_file_valid,I_file_empty,
    input wire [11:0] I_file_level,
    output wire O_file_read,
    input wire I_mclk,
    input wire I_pixel_clk,
    input wire I_rst,
    input wire I_cue_clk,
    input wire I_cue_valid,
    input wire [2:0] I_cue_note,
    input wire [3:0] I_volume_level,
    output wire O_audio_valid,
    output wire [23:0] O_audio_left_data,
    output wire [23:0] O_audio_right_data,
    output wire O_acr_valid,
    output wire [19:0] O_acr_cts,
    output wire [19:0] O_acr_n,
    output wire [15:0] O_meter_sample
);
    // Assert reset asynchronously; release it in each audio clock domain.
    reg [1:0] mclk_reset_sync;
    reg [1:0] pixel_reset_sync;
    always @(posedge I_mclk or posedge I_rst) begin
        if (I_rst) mclk_reset_sync <= 2'b11;
        else mclk_reset_sync <= {mclk_reset_sync[0], 1'b0};
    end
    always @(posedge I_pixel_clk or posedge I_rst) begin
        if (I_rst) pixel_reset_sync <= 2'b11;
        else pixel_reset_sync <= {pixel_reset_sync[0], 1'b0};
    end

    wire sample_req, legacy_sample_req, sine_sample_req;
    wire [23:0] sample_word, legacy_sample_word, sine_sample_word;
    wire cue_valid;
    wire [2:0] cue_note;
    wire [3:0] volume_level;
    reg sample_ack;
    reg [2:0] sample_req_sync;
    reg audio_valid;
    reg [23:0] audio_left, audio_right;
    reg [15:0] meter_sample;
    wire acr_valid;

    // CUE_MODE=0 preserves the legacy sampler and its regression hierarchy.
    // Constant-selected unused generators are removed by synthesis.
    hdmi_audio_pcm_tone #(
        .AMP(AMP), .NOTE_HOLD_FRAMES(NOTE_HOLD_FRAMES)
    ) u_pcm_tone (
        .I_mclk(I_mclk), .I_rst(mclk_reset_sync[1]),
        .I_sample_ack(sample_ack), .O_sample_req(legacy_sample_req),
        .O_sample_word(legacy_sample_word)
    );
    hdmi_audio_cue_mailbox u_cue_mailbox (
        .I_source_clk(I_cue_clk), .I_mclk(I_mclk), .I_rst(I_rst),
        .I_cue_valid((CUE_MODE!=0) && I_cue_valid), .I_cue_note(I_cue_note),
        .O_cue_valid(cue_valid), .O_cue_note(cue_note)
    );
    hdmi_audio_volume_mailbox u_volume_mailbox (
        .I_source_clk(I_cue_clk), .I_mclk(I_mclk), .I_rst(I_rst),
        .I_volume_level(I_volume_level), .O_volume_level(volume_level)
    );
    hdmi_audio_pcm_sine_cue #(
        .AMPLITUDE(CUE_AMP), .ATTACK_SAMPLES(CUE_ATTACK_SAMPLES),
        .HOLD_SAMPLES(CUE_HOLD_SAMPLES), .RELEASE_SAMPLES(CUE_RELEASE_SAMPLES),
        .RESTART_FADE_SAMPLES(CUE_RESTART_FADE_SAMPLES),
        .VOLUME_ENABLE(VOLUME_ENABLE && (CUE_MODE!=0))
    ) u_sine_cue (
        .I_mclk(I_mclk), .I_rst(mclk_reset_sync[1]),
        .I_cue_valid(cue_valid), .I_cue_note(cue_note),
        .I_volume_level(volume_level),
        .I_sample_ack(sample_ack), .O_sample_req(sine_sample_req),
        .O_sample_word(sine_sample_word)
    );
    wire file_sample_req;
    wire [23:0] file_sample_word;
    wire [15:0] file_meter_word;
    wire [5:0] file_controls;
    generate if(FILE_MODE)begin:g_file
      player_config_mailbox #(.WIDTH(6),.RESET_VALUE(6'd41)) control_mailbox(
       .I_source_clk(I_cue_clk),.I_dest_clk(I_mclk),.I_source_rst(I_rst),.I_dest_rst(mclk_reset_sync[1]),
       .I_value({I_music_paused,I_sleep,I_volume_level}),.O_value(file_controls));
      audio_pcm_file_078 source(.clk(I_mclk),.rst(mclk_reset_sync[1]),.music_paused(file_controls[5]),.cue_valid(cue_valid),.cue_note(cue_note),.sleeping(file_controls[4]),.volume(file_controls[3:0]),
       .sample_ack(sample_ack),.fifo_data(I_file_data),.fifo_valid(I_file_valid),.fifo_empty(I_file_empty),.fifo_level(I_file_level),
       .fifo_read(O_file_read),.sample_req(file_sample_req),.sample_word(file_sample_word),.underruns(),.meter_word(file_meter_word));
    end else begin:g_no_file
      assign file_controls=0;assign file_sample_req=0;assign file_sample_word=0;assign file_meter_word=0;assign O_file_read=0;
    end endgenerate
    assign sample_req = FILE_MODE?file_sample_req:(CUE_MODE!=0) ? sine_sample_req : legacy_sample_req;
    assign sample_word = FILE_MODE?file_sample_word:(CUE_MODE!=0) ? sine_sample_word : legacy_sample_word;

    always @(posedge I_pixel_clk or posedge pixel_reset_sync[1]) begin
        if (pixel_reset_sync[1]) sample_req_sync <= 3'b000;
        else sample_req_sync <= {sample_req_sync[1:0], sample_req};
    end
    always @(posedge I_pixel_clk or posedge pixel_reset_sync[1]) begin
        if (pixel_reset_sync[1]) begin
            sample_ack <= 1'b0;
            audio_valid <= 1'b0;
            audio_left <= 24'd0;
            audio_right <= 24'd0;
            meter_sample <= 16'd0;
        end else begin
            audio_valid <= 1'b0;
            audio_left <= 24'd0;
            audio_right <= 24'd0;
            meter_sample <= 16'd0;
            if (sample_req_sync[2] != sample_ack) begin
                // The payload has settled through the request synchronizers;
                // it remains stable until this ACK returns to its source.
                audio_left <= sample_word;
                // Capture the premaster sample under the SAME settled request token.
                audio_right <= sample_word;
                meter_sample <= FILE_MODE ? file_meter_word : sample_word[23:8];
                audio_valid <= 1'b1;
                sample_ack <= sample_req_sync[2];
            end
        end
    end
    audio_arc_calculate #(.ACR_N(6144)) u_audio_arc_calculate (
        .I_clk(I_pixel_clk), .I_rst(pixel_reset_sync[1]),
        .I_audio_valid(audio_valid), .O_acr_valid(acr_valid),
        .O_acr_cts(O_acr_cts), .O_acr_n(O_acr_n)
    );
    assign O_audio_valid = audio_valid && !pixel_reset_sync[1];
    assign O_audio_left_data = audio_left;
    assign O_audio_right_data = audio_right;
    assign O_meter_sample = meter_sample;
    assign O_acr_valid = acr_valid && !pixel_reset_sync[1];
endmodule

// Same note increments and sample sequence as the legacy 64fs I2S tone.
// 12.288 MHz / 256 = 48 kHz. No divided clock, serial shifter or new PLL.
module hdmi_audio_pcm_tone #(
    parameter signed [23:0] AMP = 24'sd2000000,
    parameter integer NOTE_HOLD_FRAMES = 24000
)(
    input wire I_mclk,
    input wire I_rst,
    input wire I_sample_ack,
    output reg O_sample_req,
    output reg [23:0] O_sample_word
);
    function [31:0] note_inc_lut;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: note_inc_lut = 32'd23409862;
                3'd1: note_inc_lut = 32'd26276681;
                3'd2: note_inc_lut = 32'd29494578;
                3'd3: note_inc_lut = 32'd31248410;
                3'd4: note_inc_lut = 32'd35075155;
                3'd5: note_inc_lut = 32'd39370534;
                3'd6: note_inc_lut = 32'd44191930;
                default: note_inc_lut = 32'd46819716;
            endcase
        end
    endfunction
    reg [2:0] sample_ack_sync;
    reg [7:0] sample_div;
    reg [31:0] phase_acc;
    reg signed [23:0] sample_current, sample_next;
    reg [2:0] note_idx;
    reg [15:0] note_frame_count;
    always @(posedge I_mclk or posedge I_rst) begin
        if (I_rst) sample_ack_sync <= 3'b000;
        else sample_ack_sync <= {sample_ack_sync[1:0], I_sample_ack};
    end
    always @(posedge I_mclk or posedge I_rst) begin
        if (I_rst) begin
            sample_div <= 8'd0;
            phase_acc <= 32'd0;
            sample_current <= 24'sd0;
            sample_next <= AMP;
            note_idx <= 3'd0;
            note_frame_count <= 16'd0;
            O_sample_req <= 1'b0;
            O_sample_word <= 24'd0;
        end else if (sample_div == 8'd255) begin
            // If the destination clock stalls, retain this sample and wait.
            // Do not overwrite an unacknowledged payload or advance its phase.
            if (sample_ack_sync[2] == O_sample_req) begin
                sample_div <= 8'd0;
                O_sample_word <= sample_current;
                O_sample_req <= ~O_sample_req;
                sample_current <= sample_next;
                sample_next <= phase_acc[31] ? AMP : -AMP;
                phase_acc <= phase_acc + note_inc_lut(note_idx);
                if (note_frame_count == NOTE_HOLD_FRAMES-1) begin
                    note_frame_count <= 16'd0;
                    note_idx <= note_idx + 3'd1;
                end else note_frame_count <= note_frame_count + 16'd1;
            end
        end else sample_div <= sample_div + 8'd1;
    end
endmodule

// Bundled-data cue transport. An in-flight payload is immutable until ACK;
// further source events replace one pending slot with the latest image cue.
// Audio ACK means accepted into the local latest-cue slot, not fully played.
// Common audio reset cancels old cues. Events during reset/release are ignored;
// a stopped clock without reset retains both the token and latest pending cue.
module hdmi_audio_cue_mailbox (
    input wire I_source_clk, I_mclk, I_rst,
    input wire I_cue_valid,
    input wire [2:0] I_cue_note,
    output reg O_cue_valid,
    output reg [2:0] O_cue_note
);
    reg [1:0] source_reset_sync, audio_reset_sync;
    reg source_req, audio_ack, pending;
    reg [2:0] source_note, pending_note;
    reg [2:0] ack_sync, req_sync;
    always @(posedge I_source_clk or posedge I_rst) begin
        if (I_rst) source_reset_sync<=2'b11;
        else source_reset_sync<={source_reset_sync[0],1'b0};
    end
    always @(posedge I_mclk or posedge I_rst) begin
        if (I_rst) audio_reset_sync<=2'b11;
        else audio_reset_sync<={audio_reset_sync[0],1'b0};
    end
    always @(posedge I_source_clk or posedge source_reset_sync[1]) begin
        if (source_reset_sync[1]) ack_sync<=0;
        else ack_sync<={ack_sync[1:0],audio_ack};
    end
    always @(posedge I_mclk or posedge audio_reset_sync[1]) begin
        if (audio_reset_sync[1]) req_sync<=0;
        else req_sync<={req_sync[1:0],source_req};
    end
    always @(posedge I_source_clk or posedge source_reset_sync[1]) begin
        if (source_reset_sync[1]) begin
            source_req<=0;source_note<=0;pending<=0;pending_note<=0;
        end else if (ack_sync[2]==source_req) begin
            if (I_cue_valid || pending) begin
                source_note<=I_cue_valid ? I_cue_note : pending_note;
                source_req<=~source_req;pending<=0;
            end
        end else if (I_cue_valid) begin
            pending<=1;pending_note<=I_cue_note;
        end
    end
    always @(posedge I_mclk or posedge audio_reset_sync[1]) begin
        if (audio_reset_sync[1]) begin
            audio_ack<=0;O_cue_valid<=0;O_cue_note<=0;
        end else begin
            O_cue_valid<=0;
            if (req_sync[2]!=audio_ack) begin
                O_cue_note<=source_note;O_cue_valid<=1;audio_ack<=req_sync[2];
            end
        end
    end
endmodule

// Continuous configuration transport. The source holds the complete payload
// until ACK. While it is in flight the upstream SD register retains the latest
// level; after ACK only that current value is replayed. Reset forces one resend
// even when it equals the default, restoring retained settings after audio reset.
module hdmi_audio_volume_mailbox (
    input wire I_source_clk, I_mclk, I_rst,
    input wire [3:0] I_volume_level,
    output reg [3:0] O_volume_level
);
    reg [1:0] source_reset_sync, audio_reset_sync;
    reg source_req, volume_ack, reset_dirty;
    reg [3:0] source_volume;
    reg [2:0] ack_sync, req_sync;
    wire [3:0] latest_volume=(I_volume_level>4'd9) ? 4'd9 : I_volume_level;
    always @(posedge I_source_clk or posedge I_rst) begin
        if(I_rst) source_reset_sync<=2'b11;
        else source_reset_sync<={source_reset_sync[0],1'b0};
    end
    always @(posedge I_mclk or posedge I_rst) begin
        if(I_rst) audio_reset_sync<=2'b11;
        else audio_reset_sync<={audio_reset_sync[0],1'b0};
    end
    always @(posedge I_source_clk or posedge source_reset_sync[1]) begin
        if(source_reset_sync[1])ack_sync<=0;
        else ack_sync<={ack_sync[1:0],volume_ack};
    end
    always @(posedge I_mclk or posedge audio_reset_sync[1]) begin
        if(audio_reset_sync[1])req_sync<=0;
        else req_sync<={req_sync[1:0],source_req};
    end
    always @(posedge I_source_clk or posedge source_reset_sync[1]) begin
        if(source_reset_sync[1])begin
            source_req<=0;source_volume<=4'd9;reset_dirty<=1;
        end else if(ack_sync[2]==source_req &&
                    (reset_dirty || latest_volume!=source_volume))begin
            source_volume<=latest_volume;source_req<=~source_req;reset_dirty<=0;
        end
    end
    always @(posedge I_mclk or posedge audio_reset_sync[1]) begin
        if(audio_reset_sync[1])begin volume_ack<=0;O_volume_level<=4'd9;end
        else if(req_sync[2]!=volume_ack)begin
            O_volume_level<=source_volume;volume_ack<=req_sync[2];
        end
    end
endmodule

// 256 phase positions, reconstructed from a 65-point inclusive quarter table.
// The table is scaled by the constant AMPLITUDE at elaboration, then a Q12
// envelope controls a signed product. IDLE still emits 48 kHz zero samples so
// HDMI's N=6144 ACR continues during quiet display intervals.
module hdmi_audio_pcm_sine_cue #(
    parameter signed [23:0] AMPLITUDE=24'sd500000,
    parameter integer ATTACK_SAMPLES=480,
    parameter integer HOLD_SAMPLES=8640,
    parameter integer RELEASE_SAMPLES=960,
    parameter integer RESTART_FADE_SAMPLES=240,
    parameter integer VOLUME_ENABLE=1
)(
    input wire I_mclk, I_rst,
    input wire I_cue_valid,
    input wire [2:0] I_cue_note,
    input wire [3:0] I_volume_level,
    input wire I_sample_ack,
    output reg O_sample_req,
    output reg [23:0] O_sample_word
);
    localparam [2:0] IDLE=0, ATTACK=1, HOLD=2, RELEASE=3, FADE=4, QUIET=5;
    localparam integer ATTACK_N=(ATTACK_SAMPLES>0) ? ATTACK_SAMPLES : 1;
    localparam integer HOLD_N=(HOLD_SAMPLES>0) ? HOLD_SAMPLES : 1;
    localparam integer RELEASE_N=(RELEASE_SAMPLES>0) ? RELEASE_SAMPLES : 1;
    localparam integer FADE_N=(RESTART_FADE_SAMPLES>0) ? RESTART_FADE_SAMPLES : 1;
    localparam integer MAX_N0=(ATTACK_N>HOLD_N) ? ATTACK_N : HOLD_N;
    localparam integer MAX_N1=(RELEASE_N>FADE_N) ? RELEASE_N : FADE_N;
    localparam integer MAX_N=(MAX_N0>MAX_N1) ? MAX_N0 : MAX_N1;
    localparam integer COUNT_BITS=(MAX_N>1) ? $clog2(MAX_N+1) : 1;
    localparam [12:0] ATTACK_STEP=(4096+ATTACK_N-1)/ATTACK_N;
    localparam [12:0] RELEASE_STEP=(4096+RELEASE_N-1)/RELEASE_N;
    localparam [12:0] FADE_STEP=(4096+FADE_N-1)/FADE_N;
    reg [2:0] state, note_idx;
    reg [COUNT_BITS-1:0] envelope_count;
    reg [12:0] envelope_level;
    reg [31:0] phase_acc;
    reg [7:0] sample_div;
    reg [2:0] sample_ack_sync;
    reg pending_valid;
    reg [2:0] pending_note;
    wire cue_waiting=pending_valid || I_cue_valid;
    wire [2:0] latest_note=I_cue_valid ? I_cue_note : pending_note;
    wire [6:0] quarter_index=phase_acc[30] ?
        (7'd64-{1'b0,phase_acc[29:24]}) : {1'b0,phase_acc[29:24]};
    wire signed [23:0] magnitude=quarter_sine(quarter_index);
    wire signed [23:0] sine_word=phase_acc[31] ? -magnitude : magnitude;
    wire signed [13:0] gain=$signed({1'b0,envelope_level});
    wire signed [37:0] product=sine_word*gain;
    wire signed [37:0] scaled=product >>> 12;
    wire [23:0] limited=(scaled>38'sd8388607) ? 24'h7fffff :
                       (scaled< -38'sd8388608) ? 24'h800000 : scaled[23:0];
    function [8:0] volume_gain_lut;
        input [3:0] level;
        begin
            case(level)
                0:volume_gain_lut=0; 1:volume_gain_lut=16;
                2:volume_gain_lut=24; 3:volume_gain_lut=32;
                4:volume_gain_lut=48; 5:volume_gain_lut=64;
                6:volume_gain_lut=96; 7:volume_gain_lut=128;
                8:volume_gain_lut=192; default:volume_gain_lut=256;
            endcase
        end
    endfunction
    reg [8:0] volume_gain;
    wire [8:0] volume_target=(VOLUME_ENABLE!=0) ? volume_gain_lut(I_volume_level) : 9'd256;
    // Apply volume after the existing envelope's exact24bit result. A unity
    // bypass forwards each sample with its rounding unchanged.
    wire signed [24:0] volume_input=$signed({limited[23],limited});
    wire [24:0] volume_magnitude=volume_input[24] ? -volume_input : volume_input;
    reg [33:0] volume_product_q;
    reg volume_negative_q,volume_sign_q;
    reg [34:0] volume_rounded_q;
    wire signed [27:0] volume_scaled=volume_sign_q ?
        -$signed({1'b0,volume_rounded_q[34:8]}) :
         $signed({1'b0,volume_rounded_q[34:8]});
    wire [23:0] volume_limited=(volume_scaled>28'sd8388607) ? 24'h7fffff :
        (volume_scaled< -28'sd8388608) ? 24'h800000 : volume_scaled[23:0];
    wire [23:0] volume_word=(VOLUME_ENABLE==0 || volume_gain==9'd256) ? limited :
        (volume_gain==0) ? 24'd0 : volume_limited;
    // Two MCLK pipeline stages settle long before the next256-clock sample.
    // Magnitude rounding then sign restoration is symmetric, including24bit MIN.
    always @(posedge I_mclk or posedge I_rst)begin
        if(I_rst)begin volume_product_q<=0;volume_negative_q<=0;volume_rounded_q<=0;volume_sign_q<=0;end
        else begin
            volume_product_q<=volume_magnitude*volume_gain;
            volume_negative_q<=volume_input[24];
            volume_rounded_q<={1'b0,volume_product_q}+35'd128;
            volume_sign_q<=volume_negative_q;
        end
    end
    function [31:0] note_increment;
        input [2:0] idx;
        begin
            case(idx)
                0:note_increment=32'd23409862;1:note_increment=32'd26276681;
                2:note_increment=32'd29494578;3:note_increment=32'd31248410;
                4:note_increment=32'd35075155;5:note_increment=32'd39370534;
                6:note_increment=32'd44191930;default:note_increment=32'd46819716;
            endcase
        end
    endfunction
    function signed [23:0] quarter_sine;
        input [6:0] idx;
        begin
            case(idx)
                7'd0:quarter_sine=(64'sd0 * AMPLITUDE)/64'sd32767;
                7'd1:quarter_sine=(64'sd804 * AMPLITUDE)/64'sd32767;
                7'd2:quarter_sine=(64'sd1608 * AMPLITUDE)/64'sd32767;
                7'd3:quarter_sine=(64'sd2410 * AMPLITUDE)/64'sd32767;
                7'd4:quarter_sine=(64'sd3212 * AMPLITUDE)/64'sd32767;
                7'd5:quarter_sine=(64'sd4011 * AMPLITUDE)/64'sd32767;
                7'd6:quarter_sine=(64'sd4808 * AMPLITUDE)/64'sd32767;
                7'd7:quarter_sine=(64'sd5602 * AMPLITUDE)/64'sd32767;
                7'd8:quarter_sine=(64'sd6393 * AMPLITUDE)/64'sd32767;
                7'd9:quarter_sine=(64'sd7179 * AMPLITUDE)/64'sd32767;
                7'd10:quarter_sine=(64'sd7962 * AMPLITUDE)/64'sd32767;
                7'd11:quarter_sine=(64'sd8739 * AMPLITUDE)/64'sd32767;
                7'd12:quarter_sine=(64'sd9512 * AMPLITUDE)/64'sd32767;
                7'd13:quarter_sine=(64'sd10278 * AMPLITUDE)/64'sd32767;
                7'd14:quarter_sine=(64'sd11039 * AMPLITUDE)/64'sd32767;
                7'd15:quarter_sine=(64'sd11793 * AMPLITUDE)/64'sd32767;
                7'd16:quarter_sine=(64'sd12539 * AMPLITUDE)/64'sd32767;
                7'd17:quarter_sine=(64'sd13279 * AMPLITUDE)/64'sd32767;
                7'd18:quarter_sine=(64'sd14010 * AMPLITUDE)/64'sd32767;
                7'd19:quarter_sine=(64'sd14732 * AMPLITUDE)/64'sd32767;
                7'd20:quarter_sine=(64'sd15446 * AMPLITUDE)/64'sd32767;
                7'd21:quarter_sine=(64'sd16151 * AMPLITUDE)/64'sd32767;
                7'd22:quarter_sine=(64'sd16846 * AMPLITUDE)/64'sd32767;
                7'd23:quarter_sine=(64'sd17530 * AMPLITUDE)/64'sd32767;
                7'd24:quarter_sine=(64'sd18204 * AMPLITUDE)/64'sd32767;
                7'd25:quarter_sine=(64'sd18868 * AMPLITUDE)/64'sd32767;
                7'd26:quarter_sine=(64'sd19519 * AMPLITUDE)/64'sd32767;
                7'd27:quarter_sine=(64'sd20159 * AMPLITUDE)/64'sd32767;
                7'd28:quarter_sine=(64'sd20787 * AMPLITUDE)/64'sd32767;
                7'd29:quarter_sine=(64'sd21403 * AMPLITUDE)/64'sd32767;
                7'd30:quarter_sine=(64'sd22005 * AMPLITUDE)/64'sd32767;
                7'd31:quarter_sine=(64'sd22594 * AMPLITUDE)/64'sd32767;
                7'd32:quarter_sine=(64'sd23170 * AMPLITUDE)/64'sd32767;
                7'd33:quarter_sine=(64'sd23731 * AMPLITUDE)/64'sd32767;
                7'd34:quarter_sine=(64'sd24279 * AMPLITUDE)/64'sd32767;
                7'd35:quarter_sine=(64'sd24811 * AMPLITUDE)/64'sd32767;
                7'd36:quarter_sine=(64'sd25329 * AMPLITUDE)/64'sd32767;
                7'd37:quarter_sine=(64'sd25832 * AMPLITUDE)/64'sd32767;
                7'd38:quarter_sine=(64'sd26319 * AMPLITUDE)/64'sd32767;
                7'd39:quarter_sine=(64'sd26790 * AMPLITUDE)/64'sd32767;
                7'd40:quarter_sine=(64'sd27245 * AMPLITUDE)/64'sd32767;
                7'd41:quarter_sine=(64'sd27683 * AMPLITUDE)/64'sd32767;
                7'd42:quarter_sine=(64'sd28105 * AMPLITUDE)/64'sd32767;
                7'd43:quarter_sine=(64'sd28510 * AMPLITUDE)/64'sd32767;
                7'd44:quarter_sine=(64'sd28898 * AMPLITUDE)/64'sd32767;
                7'd45:quarter_sine=(64'sd29268 * AMPLITUDE)/64'sd32767;
                7'd46:quarter_sine=(64'sd29621 * AMPLITUDE)/64'sd32767;
                7'd47:quarter_sine=(64'sd29956 * AMPLITUDE)/64'sd32767;
                7'd48:quarter_sine=(64'sd30273 * AMPLITUDE)/64'sd32767;
                7'd49:quarter_sine=(64'sd30571 * AMPLITUDE)/64'sd32767;
                7'd50:quarter_sine=(64'sd30852 * AMPLITUDE)/64'sd32767;
                7'd51:quarter_sine=(64'sd31113 * AMPLITUDE)/64'sd32767;
                7'd52:quarter_sine=(64'sd31356 * AMPLITUDE)/64'sd32767;
                7'd53:quarter_sine=(64'sd31580 * AMPLITUDE)/64'sd32767;
                7'd54:quarter_sine=(64'sd31785 * AMPLITUDE)/64'sd32767;
                7'd55:quarter_sine=(64'sd31971 * AMPLITUDE)/64'sd32767;
                7'd56:quarter_sine=(64'sd32137 * AMPLITUDE)/64'sd32767;
                7'd57:quarter_sine=(64'sd32285 * AMPLITUDE)/64'sd32767;
                7'd58:quarter_sine=(64'sd32412 * AMPLITUDE)/64'sd32767;
                7'd59:quarter_sine=(64'sd32521 * AMPLITUDE)/64'sd32767;
                7'd60:quarter_sine=(64'sd32609 * AMPLITUDE)/64'sd32767;
                7'd61:quarter_sine=(64'sd32678 * AMPLITUDE)/64'sd32767;
                7'd62:quarter_sine=(64'sd32728 * AMPLITUDE)/64'sd32767;
                7'd63:quarter_sine=(64'sd32757 * AMPLITUDE)/64'sd32767;
                7'd64:quarter_sine=(64'sd32767 * AMPLITUDE)/64'sd32767;
                default:quarter_sine=0;
            endcase
        end
    endfunction
    always @(posedge I_mclk or posedge I_rst) begin
        if(I_rst)sample_ack_sync<=0;
        else sample_ack_sync<={sample_ack_sync[1:0],I_sample_ack};
    end
    always @(posedge I_mclk or posedge I_rst) begin
        if(I_rst)begin
            state<=IDLE;note_idx<=0;envelope_count<=0;envelope_level<=0;
            phase_acc<=0;sample_div<=0;pending_valid<=0;pending_note<=0;
            O_sample_req<=0;O_sample_word<=0;volume_gain<=9'd256;
        end else begin
            if(I_cue_valid)begin pending_valid<=1;pending_note<=I_cue_note;end
            if(sample_div==255)begin
                // Advance samples, envelope and phase only when the held PCM
                // payload has been ACKed. An absent pixel clock cannot overwrite it.
                if(sample_ack_sync[2]==O_sample_req)begin
                    sample_div<=0;O_sample_req<=~O_sample_req;O_sample_word<=volume_word;
                    // 1/256 gain per accepted sample: full-range ramp5.33ms.
                    if(volume_gain<volume_target)volume_gain<=volume_gain+9'd1;
                    else if(volume_gain>volume_target)volume_gain<=volume_gain-9'd1;
                    if(state==IDLE || state==QUIET)begin
                        envelope_level<=0;
                        if(cue_waiting)begin
                            note_idx<=latest_note;phase_acc<=0;envelope_count<=0;
                            state<=ATTACK;pending_valid<=0;
                        end else state<=IDLE;
                    end else begin
                        phase_acc<=phase_acc+note_increment(note_idx);
                        if(cue_waiting && state!=FADE)begin
                            // Continue the old oscillator while falling to zero;
                            // requests during that fade replace only latest_note.
                            state<=FADE;envelope_count<=0;
                        end else case(state)
                            ATTACK:begin
                                if(envelope_count==ATTACK_N-1)begin
                                    envelope_level<=13'd4096;envelope_count<=0;
                                    state<=(HOLD_SAMPLES>0) ? HOLD : RELEASE;
                                end else begin
                                    envelope_count<=envelope_count+1'b1;
                                    envelope_level<=(envelope_level>=13'd4096-ATTACK_STEP) ?
                                        13'd4096 : envelope_level+ATTACK_STEP;
                                end
                            end
                            HOLD:begin
                                if(envelope_count==HOLD_N-1)begin state<=RELEASE;envelope_count<=0;end
                                else envelope_count<=envelope_count+1'b1;
                            end
                            RELEASE:begin
                                if(envelope_count==RELEASE_N-1)begin state<=IDLE;envelope_level<=0;envelope_count<=0;end
                                else begin
                                    envelope_count<=envelope_count+1'b1;
                                    envelope_level<=(envelope_level<=RELEASE_STEP) ? 13'd0 : envelope_level-RELEASE_STEP;
                                end
                            end
                            FADE:begin
                                if(envelope_level<=FADE_STEP || envelope_count==FADE_N-1)begin
                                    envelope_level<=0;envelope_count<=0;state<=QUIET;
                                end else begin
                                    envelope_level<=envelope_level-FADE_STEP;
                                    envelope_count<=envelope_count+1'b1;
                                end
                            end
                            default:begin state<=IDLE;envelope_level<=0;end
                        endcase
                    end
                end
            end else sample_div<=sample_div+8'd1;
        end
    end
endmodule
