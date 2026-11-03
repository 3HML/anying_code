// New independent audio PLL, adapted from the EG_PHY_PLL reference template.
// Fref=96.000000 MHz; R=5; M=16; C0=1; C2=25; Fout=12.288000 MHz.
`timescale 1 ns / 100 fs

module PLL_HDMI_AUDIO (
  refclk,
  reset,
  extlock,
  clk0_out,
  clk1_out,
  clk2_out 
);

  input refclk;
  input reset;
  output extlock;
  output clk0_out;
  output clk1_out;
  output clk2_out;

  wire clk0_buf;
  wire PLL_HDMI_AUDIO_open0, PLL_HDMI_AUDIO_open1, PLL_HDMI_AUDIO_open2, PLL_HDMI_AUDIO_open3, PLL_HDMI_AUDIO_open4, PLL_HDMI_AUDIO_open5, PLL_HDMI_AUDIO_open6, PLL_HDMI_AUDIO_open7, PLL_HDMI_AUDIO_open8, PLL_HDMI_AUDIO_open9, PLL_HDMI_AUDIO_open10;


  EG_LOGIC_BUFG bufg_feedback (
    .i(clk0_buf),
    .o(clk0_out) 
  );

  EG_PHY_PLL #(
    .DPHASE_SOURCE("DISABLE"),
    .DYNCFG("DISABLE"),
    .FIN("96.000000"),
    .FEEDBK_MODE("NORMAL"),
    .FEEDBK_PATH("CLKC0_EXT"),
    .STDBY_ENABLE("DISABLE"),
    .PLLRST_ENA("ENABLE"),
    .SYNC_ENABLE("DISABLE"),
    .GMC_GAIN(2),
    .ICP_CURRENT(9),
    .KVCO(2),
    .LPF_CAPACITOR(1),
    .LPF_RESISTOR(8),
    .REFCLK_DIV(5),
    .FBCLK_DIV(16),
    .CLKC0_ENABLE("ENABLE"),
    .CLKC0_DIV(1),
    .CLKC0_CPHASE(0),
    .CLKC0_FPHASE(0),
    .CLKC1_ENABLE("DISABLE"),
    .CLKC1_DIV(2),
    .CLKC1_CPHASE(1),
    .CLKC1_FPHASE(4),
    .CLKC2_ENABLE("ENABLE"),
    .CLKC2_DIV(25),
    .CLKC2_CPHASE(24),
    .CLKC2_FPHASE(0) 
  ) pll_inst (
    .refclk(refclk),
    .reset(reset),
    .stdby(1'b0),
    .extlock(extlock),
    .load_reg(1'b0),
    .psclk(1'b0),
    .psdown(1'b0),
    .psstep(1'b0),
    .psclksel(3'b000),
    .psdone(PLL_HDMI_AUDIO_open0),
    .dclk(1'b0),
    .dcs(1'b0),
    .dwe(1'b0),
    .di(8'b00000000),
    .daddr(6'b000000),
    .do({PLL_HDMI_AUDIO_open8, PLL_HDMI_AUDIO_open7, PLL_HDMI_AUDIO_open6, PLL_HDMI_AUDIO_open5, PLL_HDMI_AUDIO_open4, PLL_HDMI_AUDIO_open3, PLL_HDMI_AUDIO_open2, PLL_HDMI_AUDIO_open1}),
    .fbclk(clk0_out),
    .clkc({PLL_HDMI_AUDIO_open10, PLL_HDMI_AUDIO_open9, clk2_out, clk1_out, clk0_buf}) 
  );

endmodule

