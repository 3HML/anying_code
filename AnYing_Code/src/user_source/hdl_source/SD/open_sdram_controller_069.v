`timescale 1ns/1ps
// FUNCTIONAL PROTOTYPE ONLY. Not integrated, routed, or approved for hardware.
// Fixed memory clock 125 MHz; unchanged 180-degree forwarded clock in PHY.
// App contract: <=256 back-to-back requests per admitted burst, no per-beat ready.
// Start another burst only after Sdr_busy=0. Never assert rd_en and wr_en together.
// Write data belongs to App_wr_en/address from the PREVIOUS rising clock edge.
// Read valid and read data below are aligned. Read-valid and data must remain aligned.
module open_sdram_controller_069 #(
    parameter integer QUEUE_DEPTH=512,
    parameter integer POWERUP_CYCLES=25000,
    parameter integer REF_INTERVAL=1464,
    parameter integer T_RCD=3, T_RP=3, T_RFC=8,
    parameter integer T_RAS=6, T_RC=9, T_RRD=2,
    parameter integer T_WR=3, T_TURN=8, T_MRD=2,
    // Functional-model profile: TAC5/6ns + roundtrip5.394ns requires 7.
    // TAC1ns + roundtrip0 requires 6 instead. This is NOT an SDF guarantee.
    parameter integer READ_RETURN_CYCLES=7
)(
    input wire Clk, Rst,
    input wire App_wr_en, App_rd_en,
    input wire [20:0] App_wr_addr, App_rd_addr,
    input wire [31:0] App_wr_din,
    input wire [3:0] App_wr_dm,
    input wire App_ref_req,
    output reg Sdr_init_done,
    output wire Sdr_init_ref_vld, Sdr_busy,
    output reg Sdr_rd_en,
    output reg [31:0] Sdr_rd_dout,
    output wire O_write_commit,
    output reg O_protocol_error,
    output wire [9:0] O_queue_used,
    output reg [2:0] O_ca,
    output reg [1:0] O_ba,
    output reg [10:0] O_addr,
    output reg [3:0] O_dm,
    output reg [31:0] O_do,
    output reg O_oe,
    input wire [31:0] I_di
);
    localparam integer PTR_W=$clog2(QUEUE_DEPTH);
    localparam [3:0] POWER_WAIT=0, INIT_PRE_WAIT=1, INIT_REF_WAIT=2,
                     INIT_MODE_WAIT=3, RUN=4, REF_WAIT=5;
    reg [3:0] state;
    // Counters only hold parameter-1 down to zero (refresh saturates there).
    // Positive timing parameters retain identical cycles; width is at least one.
    localparam integer WAIT_MAX_A=(POWERUP_CYCLES>T_RP)?POWERUP_CYCLES:T_RP;
    localparam integer WAIT_MAX_B=(T_RFC>T_MRD)?T_RFC:T_MRD;
    localparam integer WAIT_MAX=(WAIT_MAX_A>WAIT_MAX_B)?WAIT_MAX_A:WAIT_MAX_B;
    localparam integer WAIT_W=(WAIT_MAX>1)?$clog2(WAIT_MAX):1;
    localparam integer REFRESH_W=(REF_INTERVAL>1)?$clog2(REF_INTERVAL):1;
    localparam integer RCD_W=(T_RCD>1)?$clog2(T_RCD):1;
    localparam integer RP_W=(T_RP>1)?$clog2(T_RP):1;
    localparam integer RAS_W=(T_RAS>1)?$clog2(T_RAS):1;
    localparam integer RC_W=(T_RC>1)?$clog2(T_RC):1;
    localparam integer RRD_W=(T_RRD>1)?$clog2(T_RRD):1;
    localparam integer WR_W=(T_WR>1)?$clog2(T_WR):1;
    localparam integer TURN_W=(T_TURN>1)?$clog2(T_TURN):1;
    reg [WAIT_W-1:0] wait_count;
    reg [REFRESH_W-1:0] refresh_count;
    reg [3:0] init_refs;
    reg refresh_pending, ref_req_q;

    // Deliberately not reset as a RAM: pointers/count qualify all contents.
    // Synchronous-read RAM plus two-entry head cache. Inference is still unverified.
    // Array has one clocked write and one clocked read; no array/data-register reset.
    reg [57:0] request_memory [0:QUEUE_DEPTH-1];
    reg [PTR_W-1:0] head, tail;
    reg [PTR_W:0] used;
    reg pending_valid,pending_write;
    reg [20:0] pending_addr;
    reg [3:0] pending_mask;
    reg [PTR_W:0] memory_used;
    reg [57:0] ram_read_data,front_cache,skid_cache;
    reg ram_read_valid;
    reg [1:0] cache_count;
    wire [57:0] front=front_cache;
    wire front_valid=(cache_count!=0);
    wire front_write=front[57];
    wire [20:0] front_addr=front[56:36];
    wire [3:0] front_mask=front[35:32];
    wire [31:0] front_data=front[31:0];
    wire [10:0] target_row=front_addr[20:10];
    wire [1:0] target_bank=front_addr[3:2];
    wire [7:0] target_col={front_addr[9:4],front_addr[1:0]};

    reg [3:0] row_open;
    reg [10:0] open_row[0:3];
    reg [RCD_W-1:0] act_to_rw[0:3];
    reg [RAS_W-1:0] act_to_pre[0:3];
    reg [RC_W-1:0] act_to_act[0:3];
    reg [RP_W-1:0] pre_to_act[0:3];
    reg [WR_W-1:0] write_to_pre[0:3];
    reg [RRD_W-1:0] any_act_guard;
    reg [TURN_W-1:0] turn_guard;
    reg last_write,last_direction_valid;
    reg [READ_RETURN_CYCLES-1:0] read_returns;
    // issue P0 -> PHY launch N0 -> DRAM samples N1 -> acknowledge P2.
    // This latency belongs to the functional PHY contract; re-verify for any real PHY.
    reg [2:0] write_commits;
    wire direction_ok=!last_direction_valid || (front_write==last_write) || turn_guard==0;
    // Qualify each bank before selecting its single eligibility bit.
    // Keep dynamic indexing so an unknown bank preserves X semantics.
    wire [3:0] bank_rw_ready,bank_activate_ready,bank_precharge_ready;
    wire [3:0] bank_row_match;
    genvar bank_index;
    generate for(bank_index=0;bank_index<4;bank_index=bank_index+1)begin:g_bank_rw_ready
        assign bank_row_match[bank_index]=(open_row[bank_index]==target_row);
        assign bank_rw_ready[bank_index]=row_open[bank_index] &&
            bank_row_match[bank_index] && act_to_rw[bank_index]==0;
        // Reduce each bank before selection, rather than muxing wide timers.
        // No stored state or command/guard cycle is added or removed.
        assign bank_activate_ready[bank_index]=pre_to_act[bank_index]==0 && act_to_act[bank_index]==0;
        assign bank_precharge_ready[bank_index]=act_to_pre[bank_index]==0 && write_to_pre[bank_index]==0;
    end endgenerate
    // Decide ACT/PRE eligibility per bank before the selected-bank mux.
    // The procedural nesting uses if-X-is-false behavior;
    // no state, command cycle, or guard interval is added or removed.
    reg [3:0] bank_activate_issue,bank_precharge_issue;
    integer command_bank;
    always @* begin
        bank_activate_issue=4'b0000;
        bank_precharge_issue=4'b0000;
        for(command_bank=0;command_bank<4;command_bank=command_bank+1)begin
            if(!row_open[command_bank])begin
                if(bank_activate_ready[command_bank] && any_act_guard==0)
                    bank_activate_issue[command_bank]=1'b1;
            end else if(!bank_row_match[command_bank])begin
                if(bank_precharge_ready[command_bank] &&
                   read_returns==0 && turn_guard==0)
                    bank_precharge_issue[command_bank]=1'b1;
            end
        end
    end
    wire dispatch=(state==RUN) && Sdr_init_done && !refresh_pending && front_valid &&
                  bank_rw_ready[target_bank] && direction_ok;
    wire enqueue=pending_valid && (used<QUEUE_DEPTH || dispatch);
    // Reserve space for the existing RAM return and the newly requested read.
    // Exact 3-bit count + return - dispatch < 2 truth table, including count=3
    // and unsigned underflow. Unknown input bits retain the arithmetic's X.
    reg cache_room;
    always @* begin
        case({cache_count,ram_read_valid,dispatch})
            4'b0000,4'b0010,4'b0011,4'b0100,4'b0101,4'b0111,4'b1001:
                cache_room=1'b1;
            4'b0001,4'b0110,4'b1000,4'b1010,4'b1011,4'b1100,4'b1101,4'b1110,4'b1111:
                cache_room=1'b0;
            default:cache_room=1'bx;
        endcase
    end
    wire fetch=(memory_used!=0) && cache_room;
    always @(posedge Clk)begin
        if(fetch)ram_read_data<=request_memory[head];
        if(!Rst && enqueue)
            request_memory[tail]<={pending_write,pending_addr,pending_mask,pending_write?App_wr_din:32'd0};
    end
    always @(posedge Clk or posedge Rst)begin
        if(Rst)begin ram_read_valid<=0;cache_count<=0;end
        else begin
            ram_read_valid<=fetch;
            case({ram_read_valid,dispatch})
                2'b10:begin
                    if(cache_count==0)front_cache<=ram_read_data;else skid_cache<=ram_read_data;
                    cache_count<=cache_count+1'b1;
                end
                2'b01:begin
                    if(cache_count==2)front_cache<=skid_cache;
                    cache_count<=cache_count-1'b1;
                end
                2'b11:begin
                    if(cache_count==1)front_cache<=ram_read_data;
                    else begin front_cache<=skid_cache;skid_cache<=ram_read_data;end
                end
                default:begin end
            endcase
        end
    end
    wire all_pre_safe=(act_to_pre[0]==0 && act_to_pre[1]==0 && act_to_pre[2]==0 && act_to_pre[3]==0 &&
                        write_to_pre[0]==0 && write_to_pre[1]==0 && write_to_pre[2]==0 && write_to_pre[3]==0);
    wire all_rp_done=(pre_to_act[0]==0 && pre_to_act[1]==0 && pre_to_act[2]==0 && pre_to_act[3]==0);
    assign Sdr_init_ref_vld=!Sdr_init_done || refresh_pending || state==REF_WAIT;
    assign Sdr_busy=!Sdr_init_done || used!=0 || pending_valid || App_wr_en || App_rd_en ||
                    (|read_returns) || (|write_commits) || Sdr_rd_en || turn_guard!=0 ||
                    refresh_pending || state!=RUN;
    assign O_write_commit=write_commits[2];
    assign O_queue_used=used;

    integer i;
    always @(posedge Clk or posedge Rst) begin
        if(Rst) begin
            head<=0;tail<=0;used<=0;memory_used<=0;pending_valid<=0;pending_write<=0;pending_addr<=0;pending_mask<=0;
            O_protocol_error<=0;
        end else begin
            pending_valid<=Sdr_init_done && (App_wr_en || App_rd_en);
            pending_write<=App_wr_en;
            pending_addr<=App_wr_en ? App_wr_addr : App_rd_addr;
            pending_mask<=App_wr_dm;
            if((App_wr_en && App_rd_en) || ((App_wr_en || App_rd_en) && !Sdr_init_done) ||
               (pending_valid && !enqueue)) O_protocol_error<=1;
            if(enqueue)begin
                tail<=tail+1'b1;
            end
            if(fetch)head<=head+1'b1;
            case({enqueue,fetch})
                2'b10:memory_used<=memory_used+1'b1;
                2'b01:memory_used<=memory_used-1'b1;
                default:memory_used<=memory_used;
            endcase
            case({enqueue,dispatch})
                2'b10:used<=used+1'b1;
                2'b01:used<=used-1'b1;
                default:used<=used;
            endcase
        end
    end

    always @(posedge Clk or posedge Rst)begin
        if(Rst)begin
            state<=POWER_WAIT;wait_count<=POWERUP_CYCLES-1;init_refs<=0;
            Sdr_init_done<=0;refresh_count<=0;refresh_pending<=0;ref_req_q<=0;
            O_ca<=3'b111;O_ba<=0;O_addr<=0;O_dm<=0;O_do<=0;O_oe<=0;
            row_open<=0;any_act_guard<=0;turn_guard<=0;last_write<=0;last_direction_valid<=0;
            read_returns<=0;write_commits<=0;Sdr_rd_en<=0;Sdr_rd_dout<=0;
            for(i=0;i<4;i=i+1)begin
                open_row[i]<=0;act_to_rw[i]<=0;act_to_pre[i]<=0;act_to_act[i]<=0;
                pre_to_act[i]<=0;write_to_pre[i]<=0;
            end
        end else begin
            O_ca<=3'b111;O_oe<=0;O_dm<=0;
            read_returns<={read_returns[READ_RETURN_CYCLES-2:0],1'b0};
            write_commits<={write_commits[1:0],1'b0};
            Sdr_rd_en<=read_returns[READ_RETURN_CYCLES-1];
            if(read_returns[READ_RETURN_CYCLES-1])Sdr_rd_dout<=I_di;
            if(any_act_guard!=0)any_act_guard<=any_act_guard-1'b1;
            if(turn_guard!=0)turn_guard<=turn_guard-1'b1;
            for(i=0;i<4;i=i+1)begin
                if(act_to_rw[i]!=0)act_to_rw[i]<=act_to_rw[i]-1'b1;
                if(act_to_pre[i]!=0)act_to_pre[i]<=act_to_pre[i]-1'b1;
                if(act_to_act[i]!=0)act_to_act[i]<=act_to_act[i]-1'b1;
                if(pre_to_act[i]!=0)pre_to_act[i]<=pre_to_act[i]-1'b1;
                if(write_to_pre[i]!=0)write_to_pre[i]<=write_to_pre[i]-1'b1;
            end
            ref_req_q<=App_ref_req;
            if(Sdr_init_done)begin
                if(refresh_count>=REF_INTERVAL-1)refresh_pending<=1;
                else refresh_count<=refresh_count+1'b1;
                if(App_ref_req && !ref_req_q)refresh_pending<=1;
            end
            case(state)
                POWER_WAIT:if(wait_count!=0)wait_count<=wait_count-1'b1;
                           else begin O_ca<=3'b010;O_addr<=11'h400;wait_count<=T_RP-1;state<=INIT_PRE_WAIT;end
                INIT_PRE_WAIT:if(wait_count!=0)wait_count<=wait_count-1'b1;
                              else begin O_ca<=3'b001;init_refs<=1;wait_count<=T_RFC-1;state<=INIT_REF_WAIT;end
                INIT_REF_WAIT:if(wait_count!=0)wait_count<=wait_count-1'b1;
                              else if(init_refs<8)begin O_ca<=3'b001;init_refs<=init_refs+1'b1;wait_count<=T_RFC-1;end
                              else begin O_ca<=3'b000;O_ba<=0;O_addr<=11'h030;wait_count<=T_MRD-1;state<=INIT_MODE_WAIT;end
                INIT_MODE_WAIT:if(wait_count!=0)wait_count<=wait_count-1'b1;
                               else begin Sdr_init_done<=1;refresh_count<=0;state<=RUN;end
                RUN:begin
                    if(refresh_pending)begin
                        if(all_pre_safe && turn_guard==0 && read_returns==0 && write_commits==0)begin
                            if(row_open!=0)begin
                                O_ca<=3'b010;O_addr<=11'h400;row_open<=0;
                                for(i=0;i<4;i=i+1)pre_to_act[i]<=T_RP-1;
                            end else if(all_rp_done)begin
                                O_ca<=3'b001;wait_count<=T_RFC-1;state<=REF_WAIT;
                                refresh_pending<=0;refresh_count<=0;
                            end
                        end
                    end else if(front_valid)begin
                        if(bank_activate_issue[target_bank])begin
                            O_ca<=3'b011;O_ba<=target_bank;O_addr<=target_row;
                            row_open[target_bank]<=1;open_row[target_bank]<=target_row;
                            act_to_rw[target_bank]<=T_RCD-1;act_to_pre[target_bank]<=T_RAS-1;
                            act_to_act[target_bank]<=T_RC-1;any_act_guard<=T_RRD-1;
                        end else if(bank_precharge_issue[target_bank])begin
                            O_ca<=3'b010;O_ba<=target_bank;O_addr<=0;
                            row_open[target_bank]<=0;pre_to_act[target_bank]<=T_RP-1;
                        end else if(dispatch)begin
                            O_ca<=front_write?3'b100:3'b101;O_ba<=target_bank;O_addr<={3'b000,target_col};
                            O_dm<=front_mask;O_do<=front_data;O_oe<=front_write;
                            last_write<=front_write;last_direction_valid<=1;turn_guard<=T_TURN-1;
                            if(front_write)begin write_to_pre[target_bank]<=T_WR-1;write_commits[0]<=1;end
                            else read_returns[0]<=1;
                        end
                    end
                end
                REF_WAIT:if(wait_count!=0)wait_count<=wait_count-1'b1;
                         else state<=RUN;
                default:begin state<=POWER_WAIT;wait_count<=POWERUP_CYCLES-1;Sdr_init_done<=0;end
            endcase
        end
    end
endmodule
