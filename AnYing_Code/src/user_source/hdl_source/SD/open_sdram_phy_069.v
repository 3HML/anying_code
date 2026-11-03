`timescale 1ns/1ps
// Public SDR PHY. This source does not instantiate or reset a PLL.
// clk_sft MUST be the existing sys_pll forwarded 125 MHz / 180-degree output.
// Required implementation attributes are saved in pin.adc and loaded by TD.
// Normal project builds retain fabric outputs, IOFF inputs and independent OE.
module open_sdram_phy_069 (
    input wire clk, clk_sft, rst,
    input wire [2:0] ca,
    input wire [1:0] ba,
    input wire [10:0] addr,
    input wire [3:0] dm,
    input wire [31:0] d_out,
    input wire oe,
    (* iob = "true" *) output reg [31:0] d_in,
    output wire sdram_clk,
    output reg [2:0] pin_ca,
    output reg [1:0] pin_ba,
    output reg [10:0] pin_addr,
    output wire [3:0] pin_dm,
    inout wire [31:0] dq,
    output reg pin_oe
);
    reg [31:0] pin_do;

    // Preserve the actual PLL output; never synthesize a replacement ~clk.
    assign sdram_clk = clk_sft;
    assign dq = pin_oe ? pin_do : 32'bz;
    // EG4S20 SiP DM[3:0] are fixed low (DS301 table4-1). This interface
    // supports full 32-bit writes only. The controller must always supply dm=0.
    assign pin_dm = 4'b0000;

    // Equal asynchronous-reset/enable control sets on every final output.
    // Controller prepares CA/data/OE on posedge; final launch is on negedge.
    always @(negedge clk or posedge rst) begin
        if (rst) begin
            pin_ca <= 3'b111;
            pin_ba <= 2'b00;
            pin_addr <= 11'd0;
            pin_do <= 32'd0;
            pin_oe <= 1'b0;
        end else begin
            pin_ca <= ca;
            pin_ba <= ba;
            pin_addr <= addr;
            pin_do <= d_out;
            pin_oe <= oe;
        end
    end

    // Rising-edge input capture. Controller read-valid alignment
    // must be verified against physical round-trip delay; this is not a delay.
    always @(posedge clk or posedge rst) begin
        if (rst)
            d_in <= 32'd0;
        else
            d_in <= dq;
    end
endmodule
