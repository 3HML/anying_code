`timescale 1ns/1ps
`include "../user_source/hdl_source/include/global_def.v"
// SDRAM controller and physical-interface integration.
module sdram(
`ifdef SIMULATION
    output wire SDRAM_CLK, SDR_CKE, SDR_RAS, SDR_CAS, SDR_WE,
    output wire [1:0] SDR_BA,
    output wire [10:0] SDR_ADDR,
    output wire [3:0] SDR_DM,
    inout wire [31:0] SDR_DQ,
`endif
    input wire Clk, Clk_sft, Rst,
    output wire Sdr_init_done, Sdr_init_ref_vld, Sdr_busy,
    input wire App_wr_en,
    input wire [20:0] App_wr_addr,
    input wire [3:0] App_wr_dm,
    input wire [31:0] App_wr_din,
    input wire App_rd_en,
    input wire [20:0] App_rd_addr,
    output wire Sdr_rd_en,
    output wire [31:0] Sdr_rd_dout
);
`ifndef SIMULATION
    wire SDRAM_CLK, SDR_CKE, SDR_RAS, SDR_CAS, SDR_WE;
    wire [1:0] SDR_BA;
    wire [10:0] SDR_ADDR;
    wire [3:0] SDR_DM;
    wire [31:0] SDR_DQ;
`endif
    wire [2:0] ca;
    wire [1:0] bank;
    wire [10:0] address;
    wire [3:0] mask;
    wire [31:0] d_out, d_in;
    wire oe, core_init, core_busy, protocol_error;
    // The existing SHOW_AHEAD/NOREG write FIFO presents the consumed word
    // before this edge. Match the core's one-cycle-later data contract.
    reg [31:0] app_write_data_q;
    always @(posedge Clk or posedge Rst) begin
        if (Rst) app_write_data_q <= 32'd0;
        else if (App_wr_en) app_write_data_q <= App_wr_din;
    end
    // SiP DM is hard tied low. The existing frame writer only requests full words.
    open_sdram_controller_069 #(.READ_RETURN_CYCLES(7)) u_core(
        .Clk(Clk),.Rst(Rst),.App_wr_en(App_wr_en),.App_rd_en(App_rd_en),
        .App_wr_addr(App_wr_addr),.App_rd_addr(App_rd_addr),
        .App_wr_din(app_write_data_q),.App_wr_dm(4'b0000),.App_ref_req(1'b0),
        .Sdr_init_done(core_init),.Sdr_init_ref_vld(Sdr_init_ref_vld),.Sdr_busy(core_busy),
        .Sdr_rd_en(Sdr_rd_en),.Sdr_rd_dout(Sdr_rd_dout),.O_write_commit(),
        .O_protocol_error(protocol_error),.O_queue_used(),
        .O_ca(ca),.O_ba(bank),.O_addr(address),.O_dm(mask),
        .O_do(d_out),.O_oe(oe),.I_di(d_in)
    );
    // Fail closed if a contract violation is ever detected; reset clears the latch.
    assign Sdr_init_done=core_init && !protocol_error;
    assign Sdr_busy=core_busy || protocol_error;
    open_sdram_phy_069 u_phy(
        .clk(Clk),.clk_sft(Clk_sft),.rst(Rst),.ca(ca),.ba(bank),.addr(address),
        .dm(mask),.d_out(d_out),.oe(oe),.d_in(d_in),.sdram_clk(SDRAM_CLK),
        .pin_ca({SDR_RAS,SDR_CAS,SDR_WE}),.pin_ba(SDR_BA),.pin_addr(SDR_ADDR),
        .pin_dm(SDR_DM),.dq(SDR_DQ),.pin_oe()
    );
    assign SDR_CKE=1'b1;
    EG_PHY_SDRAM_2M_32 sdram(.clk(SDRAM_CLK),.ras_n(SDR_RAS),.cas_n(SDR_CAS),
        .we_n(SDR_WE),.addr(SDR_ADDR),.ba(SDR_BA),.dq(SDR_DQ),.cs_n(1'b0),
        .dm0(1'b0),.dm1(1'b0),.dm2(1'b0),.dm3(1'b0),.cke(1'b1));
endmodule
