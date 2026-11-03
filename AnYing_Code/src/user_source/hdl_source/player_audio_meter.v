// Passive video-domain meter of signed 24-bit PCM. In091 the top feeds
// the held premaster mix, so master-volume changes cannot change bar height.
// MUSIC_MODE publishes24 coarse frequency bands; legacy mode is unchanged.
module player_audio_meter #(parameter integer MUSIC_MODE=0) (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_start,
    input  wire        mute,
    input  wire        pcm_valid,
    input  wire [23:0] pcm_sample,
    output reg [95:0] history,
    output reg  [3:0]  level
);
    // Unsigned two's-complement magnitude also represents abs(-8388608).
    wire [23:0] magnitude = pcm_sample[23] ? (~pcm_sample + 24'd1) : pcm_sample;
    // For negative PCM, ~pcm is abs(pcm)-1: abs > 2**k iff any
    // bit at k or above is set. Constant +0 costs no binary logic and
    // intentionally uses whole-word arithmetic X/Z
    // propagation before reduction (plain upper-bit inversion would not).
    wire [23:0] negative_minus_one=(~pcm_sample)+24'd0;
    reg [3:0] sample_level;
    always @* begin
        if(MUSIC_MODE)begin
          // Linear envelope scale: one bar per~12.5% full-scale. Silence stays0.
          if(magnitude==0)sample_level=0;
          else if(magnitude>=24'd7340032)sample_level=8;
          else sample_level={1'b0,magnitude[22:20]}+1'b1;
        end else begin
        if      (magnitude == 24'd0)      sample_level = 4'd0;
        else if (magnitude <= (MUSIC_MODE?24'd65536:24'd62500))  sample_level = 4'd1;
        else if (magnitude <= (MUSIC_MODE?24'd131072:24'd125000)) sample_level = 4'd2;
        else if (magnitude <= (MUSIC_MODE?24'd262144:24'd187500)) sample_level = 4'd3;
        else if (magnitude <= (MUSIC_MODE?24'd524288:24'd250000)) sample_level = 4'd4;
        else if (magnitude <= (MUSIC_MODE?24'd1048576:24'd312500)) sample_level = 4'd5;
        else if (magnitude <= (MUSIC_MODE?24'd2097152:24'd375000)) sample_level = 4'd6;
        else if (magnitude <= (MUSIC_MODE?24'd4194304:24'd437500)) sample_level = 4'd7;
        else                             sample_level = 4'd8;
        end
    end

    generate if(MUSIC_MODE)begin:g_history
        // time-shared24-band visual spectrum from real48kHz PCM.
        // LP: signed18 Q1 with nearest rounding. Envelope: unsigned18 Q4.
        // LP addresses0..24; envelope addresses32..55 (49/64 states).
        // One native18-bit BRAM; shared DSP coefficient product and19-bit ALU.
        localparam CLEAR=0,IDLE=1,LP_WAIT=2,LP_READ=3,LP_DIFF=4,
                   LP_COEFF=5,LP_ADD=6,BAND_DIFF=7,BAND_ABS=8,
                   BAND_GAIN=9,ENV_WAIT=10,ENV_READ=11,ENV_DIFF=12,ENV_ADD=13;
        reg [3:0] state;
        reg [5:0] clear_index;
        reg [4:0] band_index;
        reg signed [15:0] previous_sample;
        wire signed [16:0] sample_pair=$signed({pcm_sample[23],pcm_sample[23:8]})+$signed({previous_sample[15],previous_sample});
        reg signed [17:0] input_average,previous_lowpass,value_reg;
        reg signed [18:0] delta;
        reg [95:0] working_levels,completed_levels;
        reg seen,mute_d;
        reg [5:0] read_address,write_address;
        reg write_enable;
        reg [17:0] write_data;
        reg [17:0] state_memory[0:63];
        reg [17:0] read_data;
        // consume RAM data only on the READ cycle following each WAIT.
        // Hold the read port otherwise; writes and the existing latency stay intact.
        wire read_enable=(state==LP_WAIT)||(state==ENV_WAIT);
        always @(posedge clk) begin
            if(write_enable)state_memory[write_address]<=write_data;
            if(read_enable)read_data<=state_memory[read_address];
        end
        reg signed [14:0] lp_coefficient;
        always @* begin
            case(band_index)
                5'd0:lp_coefficient=15'sd20;
                5'd1:lp_coefficient=15'sd27;
                5'd2:lp_coefficient=15'sd36;
                5'd3:lp_coefficient=15'sd47;
                5'd4:lp_coefficient=15'sd63;
                5'd5:lp_coefficient=15'sd84;
                5'd6:lp_coefficient=15'sd112;
                5'd7:lp_coefficient=15'sd150;
                5'd8:lp_coefficient=15'sd199;
                5'd9:lp_coefficient=15'sd265;
                5'd10:lp_coefficient=15'sd352;
                5'd11:lp_coefficient=15'sd466;
                5'd12:lp_coefficient=15'sd616;
                5'd13:lp_coefficient=15'sd813;
                5'd14:lp_coefficient=15'sd1068;
                5'd15:lp_coefficient=15'sd1396;
                5'd16:lp_coefficient=15'sd1816;
                5'd17:lp_coefficient=15'sd2345;
                5'd18:lp_coefficient=15'sd3005;
                5'd19:lp_coefficient=15'sd3817;
                5'd20:lp_coefficient=15'sd4807;
                5'd21:lp_coefficient=15'sd6012;
                5'd22:lp_coefficient=15'sd7500;
                5'd23:lp_coefficient=15'sd9434;
                default:lp_coefficient=15'sd12288;
            endcase
        end
        (* dsp_style = "yes" *) wire signed [33:0] lp_product;
        assign lp_product=delta*lp_coefficient;
        wire signed [33:0] lp_rounded=lp_product+34'sd4096;
        reg signed [18:0] alu_a,alu_b;
        reg alu_subtract;
        wire signed [18:0] alu_b_adjusted=alu_b^{19{alu_subtract}};
        wire signed [18:0] alu_result=alu_a+alu_b_adjusted+alu_subtract;
        // delta holds unsigned band magnitude until ENV_DIFF. Clamp only
        // above16383PCM, well beyond the visible15-step saturation level.
        wire [17:0] band_q4=(|delta[18:15])?18'h3ffff:{delta[14:0],3'b000};
        wire [3:0] quantized=(|alu_result[17:16])?4'd15:alu_result[15:12];
        wire clear_request=(mute&&!mute_d)||(frame_start&&!seen&&!pcm_valid);
        always @* begin
            alu_a=0;alu_b=0;alu_subtract=0;
            case(state)
                LP_DIFF:begin alu_a={input_average[17],input_average};alu_b={value_reg[17],value_reg};alu_subtract=1;end
                LP_ADD:begin alu_a={value_reg[17],value_reg};alu_b=delta;end
                BAND_DIFF:begin alu_a={value_reg[17],value_reg};alu_b={previous_lowpass[17],previous_lowpass};alu_subtract=1;end
                BAND_ABS:begin alu_b=delta;alu_subtract=delta[18];end
                BAND_GAIN:begin alu_a=delta>>>1;alu_b=delta>>>2;end
                ENV_DIFF:begin alu_a={1'b0,band_q4};alu_b={1'b0,value_reg};alu_subtract=1;end
                ENV_ADD:begin alu_a={1'b0,value_reg};alu_b=delta[18]?(delta>>>12):(delta>>>6);end
                default:begin end
            endcase
            read_address=(state==ENV_WAIT||state==ENV_READ)?(6'd31+{1'b0,band_index}):{1'b0,band_index};
            write_address={1'b0,band_index};write_enable=0;write_data=alu_result[17:0];
            if(state==CLEAR)begin write_address=clear_index;write_enable=1;write_data=0;end
            else if(state==LP_ADD)write_enable=1;
            else if(state==ENV_ADD)begin write_address=6'd31+{1'b0,band_index};write_enable=1;end
        end
        always @(posedge clk or posedge rst) begin
            if(rst)begin
                state<=CLEAR;clear_index<=0;band_index<=0;previous_sample<=0;
                input_average<=0;previous_lowpass<=0;value_reg<=0;delta<=0;
                working_levels<=0;completed_levels<=0;history<=0;level<=0;seen<=0;mute_d<=0;
            end else begin
                mute_d<=mute;
                if(pcm_valid&&!mute)seen<=1;
                if(frame_start)begin
                    seen<=pcm_valid&&!mute;
                    history<=(mute||(!seen&&!pcm_valid))?96'd0:completed_levels;
                end
                if(clear_request&&state!=CLEAR)begin
                    state<=CLEAR;clear_index<=0;previous_sample<=0;
                    completed_levels<=0;working_levels<=0;
                end else case(state)
                    CLEAR:begin
                        if(clear_index==6'd63)begin state<=IDLE;clear_index<=0;end
                        else clear_index<=clear_index+1'b1;
                    end
                    IDLE:if(pcm_valid&&!mute)begin
                        input_average<={sample_pair[16],sample_pair};
                        previous_sample<=pcm_sample[23:8];band_index<=0;
                        working_levels<=0;state<=LP_WAIT;
                    end
                    LP_WAIT:state<=LP_READ;
                    LP_READ:begin value_reg<=read_data;state<=LP_DIFF;end
                    LP_DIFF:begin delta<=alu_result;state<=LP_COEFF;end
                    LP_COEFF:begin delta<=lp_rounded>>>13;state<=LP_ADD;end
                    LP_ADD:begin
                        value_reg<=alu_result[17:0];
                        if(band_index==0)begin
                            previous_lowpass<=alu_result[17:0];band_index<=1;state<=LP_WAIT;
                        end else state<=BAND_DIFF;
                    end
                    BAND_DIFF:begin delta<=alu_result;previous_lowpass<=value_reg;state<=BAND_ABS;end
                    BAND_ABS:begin delta<=alu_result;state<=BAND_GAIN;end
                    BAND_GAIN:begin
                        if(band_index==23)delta<=alu_result;
                        else if(band_index==24)delta<=delta>>>1;
                        state<=ENV_WAIT;
                    end
                    ENV_WAIT:state<=ENV_READ;
                    ENV_READ:begin value_reg<=read_data;state<=ENV_DIFF;end
                    ENV_DIFF:begin delta<=alu_result;state<=ENV_ADD;end
                    ENV_ADD:begin
                        working_levels<={working_levels[91:0],quantized};
                        if(band_index==24)begin completed_levels<={working_levels[91:0],quantized};state<=IDLE;end
                        else begin band_index<=band_index+1'b1;state<=LP_WAIT;end
                    end
                    default:begin state<=CLEAR;clear_index<=0;end
                endcase
            end
        end
    end else begin:g_legacy
        always @* history=96'd0;
    // Monotonic quantization commutes with max, so only a 4-bit peak is needed.
    reg [3:0] window_peak;
    reg window_has_sample;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            level <= 4'd0;
            window_peak <= 4'd0;
            window_has_sample <= 1'b0;
        end else if (frame_start) begin
            // Publish the completed window. The coincident sample begins the
            // new window and must not influence this frame's displayed level.
            if (mute || !window_has_sample)
                level <= 4'd0;
            else if (window_peak >= level)
                level <= window_peak;
            else
                level <= level - 4'd1;
            window_peak <= (!mute && pcm_valid) ? sample_level : 4'd0;
            window_has_sample <= !mute && pcm_valid;
        end else if (mute) begin
            // Discard muted samples; displayed state changes only at a frame
            // boundary. Invalid PCM cycles never discard an unmuted peak.
            window_peak <= 4'd0;
            window_has_sample <= 1'b0;
        end else if (pcm_valid) begin
            window_has_sample <= 1'b1;
            if (sample_level > window_peak)
                window_peak <= sample_level;
        end
    end
    end endgenerate
endmodule
