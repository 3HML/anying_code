module hdmi_audio_clock (
    input wire I_ref_clk,
    input wire I_rst,
    output wire O_mclk,
    output wire O_locked
);
    wire pre_clk, pre_lock, audio_lock;
    // Independent audio clocks: 50 MHz -> 96 MHz -> 12.288 MHz.
    // Existing sys_pll and video_pll are not connected to these resets.
    PLL_AUDIO_PRE u_audio_pre_pll (
        .refclk(I_ref_clk), .reset(I_rst), .extlock(pre_lock),
        .clk0_out(), .clk1_out(), .clk2_out(pre_clk)
    );
    PLL_HDMI_AUDIO u_audio_pll (
        .refclk(pre_clk), .reset(I_rst || !pre_lock), .extlock(audio_lock),
        .clk0_out(), .clk1_out(), .clk2_out(O_mclk)
    );
    assign O_locked = pre_lock && audio_lock;
endmodule
