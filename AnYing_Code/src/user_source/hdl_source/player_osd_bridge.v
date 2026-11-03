// Atomic latest-state mailbox. Source/destination resets belong to the same
// system reset epoch; local release may be skewed. TF recovery does not reset it.
// Busy traffic coalesces activity, while source_state/source_activity are held
// unchanged until the destination's ACK has crossed all three source stages.
module player_osd_bridge #(
    parameter integer WIDTH=17,
    parameter [WIDTH-1:0] RESET_STATE={1'b0,1'b0,1'b0,4'd9,4'd9,5'd5,1'b0}
) (
    input wire I_source_clk, I_dest_clk,
    input wire I_source_rst, I_dest_rst,
    input wire [WIDTH-1:0] I_state,
    input wire I_activity,
    output reg [WIDTH-1:0] O_state,
    output reg O_activity
);
reg [WIDTH-1:0] source_state;
reg source_activity, source_req, dest_ack;
reg [2:0] ack_sync, req_sync;
reg pending_activity, reset_dirty;

always @(posedge I_source_clk or posedge I_source_rst) begin
    if (I_source_rst) begin
        source_state<=RESET_STATE; source_activity<=1'b0; source_req<=1'b0;
        ack_sync<=3'b000; pending_activity<=1'b0; reset_dirty<=1'b1;
    end else begin
        ack_sync<={ack_sync[1:0],dest_ack};
        if ((source_req==ack_sync[2]) &&
            (reset_dirty || source_state!=I_state || pending_activity || I_activity)) begin
            source_state<=I_state;
            source_activity<=pending_activity || I_activity;
            source_req<=~source_req;
            pending_activity<=1'b0;
            reset_dirty<=1'b0;
        end else if (I_activity) begin
            pending_activity<=1'b1;
        end
    end
end

always @(posedge I_dest_clk or posedge I_dest_rst) begin
    if (I_dest_rst) begin
        O_state<=RESET_STATE; O_activity<=1'b0;
        req_sync<=3'b000; dest_ack<=1'b0;
    end else begin
        req_sync<={req_sync[1:0],source_req};
        O_activity<=1'b0;
        if (req_sync[2]!=dest_ack) begin
            O_state<=source_state;
            O_activity<=source_activity;
            dest_ack<=req_sync[2];
        end
    end
end
endmodule
