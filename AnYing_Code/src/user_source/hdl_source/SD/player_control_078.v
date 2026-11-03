// UI policy only. All switches are debounced contextual change events.
// Initial physical positions are captured without generating an action. No clock generation and no memory ownership.
module player_control_078 #(
    parameter integer CLK_FREQ_HZ=100000000,
    parameter integer USER_WAKE_ENABLE=0,
    parameter integer REMOTE_ENABLE=0,
    parameter integer IR_ENABLE=0,
    parameter integer DEBOUNCE_CYCLES=5000000,
    parameter integer SECONDS_PER_MINUTE=60
)(
    input wire clk,rst,
    input wire [3:0] switches, // {SW4,SW3,SW2,SW1}
    input wire k2,k3,k4,keys_released,k3_held,
    input wire wake_level,
    input wire remote_valid,
    input wire ir_valid,
    input wire [3:0] ir_action,
    input wire [7:0] remote_command,remote_argument,
    input wire music_available,music_next_ready,
    output reg remote_reply,
    output reg [2:0] remote_result,
    input wire controls_enable,restore_apply,recovery_priority,
    input wire [3:0] restore_brightness,restore_volume,
    input wire [2:0] restore_contrast,
    input wire auto_play,image_visible,image_changed,
    input wire thumb_visible,view_busy,cancel_thumbnail,
    input wire [3:0] ready_banks,
    input wire [1:0] active_bank,
    output reg next_image,auto_toggle,period_inc,period_dec,
    output reg ir_playback_event,ir_period_event,
    output reg thumb_request,open_request,
    output reg [1:0] focus_bank,
    output reg [3:0] brightness,volume,
    output reg [2:0] contrast,committed_contrast,settings_focus,
    output reg settings_active,
    output wire timer_page,volume_selected,
    output reg minute_selected,subtract,
    output wire manual_tools,auto_tools,
    output reg interval_subtract,
    output reg finite_mode,sleeping,
    output wire timer_running,play_allowed,
    output reg [4:0] hours,
    output reg [5:0] minutes,seconds,
    output reg [2:0] zoom,
    output wire [1:0] rotation,
    output reg [3:0] committed_brightness,committed_volume,
    output reg music_paused,music_next,
    output reg activity,confirmed,
    output wire [4:0] edit_hours,
    output wire [5:0] edit_minutes,
    output wire edit_finite
);
localparam integer DBW=(DEBOUNCE_CYCLES>1)?$clog2(DEBOUNCE_CYCLES):1;
localparam integer SECW=(CLK_FREQ_HZ>1)?$clog2(CLK_FREQ_HZ):1;
reg [3:0] sw_meta,sw_sync,sw_observed,sw_stable;
reg [DBW-1:0] db_count;
reg sw_ready,armed;
reg [SECW-1:0] subsecond;
reg [4:0] draft_h;
reg [5:0] draft_m;
reg draft_finite,time_dirty;
wire sw_changed=(sw_observed!=sw_sync);
wire settle= !sw_changed && db_count==DEBOUNCE_CYCLES-1;
wire sw_update=settle && (!sw_ready || sw_stable!=sw_observed);
wire [3:0] edges=sw_stable^sw_observed;
wire mode_edge=sw_update && sw_ready && edges[0];
(* async_reg="true" *) reg [2:0] wake_sync;
wire wake_held=USER_WAKE_ENABLE && wake_sync[2];
always @(posedge clk or posedge rst)begin
    if(rst)wake_sync<=0;else wake_sync<={wake_sync[1:0],wake_level};
end
wire valid_key=armed && controls_enable && sw_ready && !sw_changed && !sw_update && !restore_apply;
wire only2=k2&&!k3&&!k4, only3=k3&&!k2&&!k4, only4=k4&&!k2&&!k3;
wire any_key=k2||k3||k4;
// five parameter fields with dedicated focus and value outputs.
assign timer_page=(settings_focus==3'd3)||(settings_focus==3'd4);
assign volume_selected=(settings_focus==3'd2)||(settings_focus==3'd4);
wire timer_edit_context=settings_active&&settings_focus==3'd4&&draft_finite&&controls_enable&&!restore_apply&&!sleeping;
wire sec_tick=subsecond==CLK_FREQ_HZ-1;
// Local switches/buttons and PC commands keep their existing priority over IR.
wire ir_accept=IR_ENABLE&&ir_valid&&controls_enable&&!restore_apply&&sw_ready&&
    !sw_changed&&!sw_update&&!any_key&&keys_released&&!wake_held&&!remote_valid;
wire ir_menu=ir_accept&&!sleeping&&(ir_action==4'd1);
wire settings_event=mode_edge||ir_menu;
wire remote_busy=settings_active||sleeping||!valid_key||!keys_released||any_key||wake_held||
    recovery_priority||view_busy||cancel_thumbnail||thumb_request||thumb_visible||!image_visible||
    (timer_running&&hours==0&&minutes==0&&seconds<=1&&sec_tick);
wire remote_bad_argument=(remote_command==0)?remote_argument>1:
    (remote_command==1||remote_command==4)?remote_argument!=0:
    (remote_command==2||remote_command==3)?remote_argument>1:remote_argument>9;
assign timer_running=finite_mode&&!sleeping&&!settings_active&&image_visible;
assign play_allowed=!sleeping&&!settings_active&&!thumb_request&&!thumb_visible&&!view_busy;
assign edit_hours=draft_h;
assign edit_minutes=draft_m;
assign edit_finite=draft_finite;
// retain compatibility/status ports; browsing always controls zoom.
assign rotation=2'd0;
assign manual_tools=1'b0;
assign auto_tools=1'b0;

always @(posedge clk or posedge rst) begin
    if(rst) begin sw_meta<=0;sw_sync<=0;sw_observed<=0;sw_stable<=0;db_count<=0;sw_ready<=0;end
    else begin
        sw_meta<=switches;sw_sync<=sw_meta;
        if(sw_changed)begin sw_observed<=sw_sync;db_count<=0;end
        else if(!settle)db_count<=db_count+1'b1;
        if(sw_update)begin sw_stable<=sw_observed;sw_ready<=1;end
    end
end
always @(posedge clk or posedge rst) begin
    if(rst)begin
        remote_reply<=0;remote_result<=0;ir_playback_event<=0;ir_period_event<=0;
        settings_active<=0;armed<=0;next_image<=0;auto_toggle<=0;period_inc<=0;period_dec<=0;
        thumb_request<=0;open_request<=0;focus_bank<=0;
        brightness<=9;volume<=9;committed_brightness<=9;committed_volume<=9;
        contrast<=3'd2;committed_contrast<=3'd2;
        settings_focus<=3'd0;
        music_paused<=1;music_next<=0;minute_selected<=1;subtract<=0;interval_subtract<=0;
        finite_mode<=0;sleeping<=0;hours<=0;minutes<=1;seconds<=0;
        draft_h<=0;draft_m<=1;draft_finite<=0;time_dirty<=0;
        zoom<=0;activity<=0;confirmed<=0;subsecond<=0;
    end else begin
        remote_reply<=0;ir_playback_event<=0;ir_period_event<=0;
        next_image<=0;auto_toggle<=0;period_inc<=0;period_dec<=0;open_request<=0;activity<=0;music_next<=0;
        if(!controls_enable||restore_apply||sw_update||sw_changed||any_key||wake_held)armed<=0;
        else if(keys_released)armed<=1;
        if(restore_apply)begin
            brightness<=restore_brightness;volume<=restore_volume;
            committed_brightness<=restore_brightness;committed_volume<=restore_volume;
            contrast<=(restore_contrast<=3'd4)?restore_contrast:3'd2;
            committed_contrast<=(restore_contrast<=3'd4)?restore_contrast:3'd2;
        end
        if(REMOTE_ENABLE&&remote_valid)begin
            remote_reply<=1;remote_result<=0;
            if(remote_command>5)remote_result<=1;
            else if(remote_bad_argument)remote_result<=2;
            else if(remote_command!=0)begin
                if(remote_busy||(remote_command==1&&auto_play)||
                    (remote_command==4&&music_available&&!music_next_ready))remote_result<=3;
                else if((remote_command==4||(remote_command==3&&remote_argument==1))&&!music_available)remote_result<=4;
                else begin
                    activity<=1;
                    case(remote_command)
                        1:next_image<=1;
                        2:if(auto_play!=remote_argument[0])auto_toggle<=1;
                        3:music_paused<=!remote_argument[0];
                        4:music_next<=1;
                        5:begin volume<=remote_argument[3:0];committed_volume<=remote_argument[3:0];end
                        default:;
                    endcase
                end
            end
        end
        if(image_changed)begin zoom<=0;end
        if(cancel_thumbnail)begin thumb_request<=0;focus_bank<=active_bank;end
        if(timer_running && !settings_event)begin
            if(sec_tick)begin
                subsecond<=0;
                if(seconds!=0)seconds<=seconds-1'b1;
                else if(minutes!=0)begin minutes<=minutes-1'b1;seconds<=SECONDS_PER_MINUTE-1;end
                else if(hours!=0)begin hours<=hours-1'b1;minutes<=59;seconds<=SECONDS_PER_MINUTE-1;end
                else sleeping<=1;
                // Expire on the last second, never one second after zero.
                if(hours==0&&minutes==0&&seconds==1)sleeping<=1;
            end else subsecond<=subsecond+1'b1;
        end
        if(settings_event && controls_enable && !restore_apply && !sleeping)begin
            settings_active<=!settings_active;
            if(mode_edge)activity<=1;
            if(!settings_active)begin
                settings_focus<=3'd0;draft_h<=hours;draft_m<=minutes;draft_finite<=finite_mode;
                if(hours==0&&minutes==0)draft_m<=1;
                confirmed<=0;time_dirty<=0;
            end else begin
                // Roll back uncommitted previews. Timer live state updates only on K4.
                brightness<=committed_brightness;volume<=committed_volume;
                contrast<=committed_contrast;
                time_dirty<=0;
            end
        end
        if(sleeping)begin
            if(wake_held||(valid_key&&any_key)||(sw_update&&sw_ready&&|edges))begin
                settings_active<=0;
                sleeping<=0;finite_mode<=0;draft_finite<=0;subsecond<=0;
                activity<=!wake_held;armed<=0;
            end
        end else if(controls_enable&&!restore_apply)begin
            if(sw_update&&sw_ready&&!mode_edge)begin
                // SW3 has no browsing action; it only controls music in settings.
                activity<=settings_active||edges[3]||edges[1];
                if(settings_active)begin
                    if(edges[2])music_paused<=!music_paused; // Global immediate action within settings.
                    if(settings_focus==3'd4)begin
                        if(edges[3])begin draft_finite<=!draft_finite;time_dirty<=1;confirmed<=0;end
                        else if(edges[1]&&draft_finite)minute_selected<=!minute_selected;
                    end
                end else if(!recovery_priority&&!view_busy&&!cancel_thumbnail)begin
                    if(!auto_play&&edges[3]&&image_visible)begin
                        if(!thumb_request)begin thumb_request<=1;focus_bank<=active_bank;end
                        else if(ready_banks[focus_bank])begin thumb_request<=0;open_request<=1;end
                    end
                end
            end
            // One edit per debounced press; a held key never repeats. Selection alone preserves confirmation.
            if(timer_edit_context&&!mode_edge&&valid_key&&only3)begin
                activity<=1;time_dirty<=1;confirmed<=0;
                if(minute_selected)begin
                    if(draft_h==24)begin draft_h<=0;draft_m<=1;end
                    else if(draft_m==59)draft_m<=(draft_h==0)?1:0;
                    else draft_m<=draft_m+1'b1;
                end else begin
                    if(draft_h==24)begin draft_h<=0;if(draft_m==0)draft_m<=1;end
                    else begin draft_h<=draft_h+1'b1;if(draft_h==23)draft_m<=0;end
                end
            end
            if(valid_key&&any_key)begin
                activity<=1;
                if(recovery_priority&&!settings_active)begin
                    if(only3)next_image<=1;
                    if(only4)auto_toggle<=1;
                end else if(settings_active)begin
                    if(only2)settings_focus<=(settings_focus==3'd4)?3'd0:settings_focus+3'd1;
                    if(only3)begin
                        case(settings_focus)
                            0:begin brightness<=(brightness==9)?1:brightness+1'b1;confirmed<=0;end
                            1:begin contrast<=(contrast==3'd4)?3'd0:contrast+3'd1;confirmed<=0;end
                            2:begin volume<=(volume==9)?0:volume+1'b1;confirmed<=0;end
                            3:music_next<=1; // Immediate action; outside page confirmation.
                            default:;
                        endcase
                    end
                    if(only4)begin
                        confirmed<=1;committed_brightness<=brightness;committed_volume<=volume;committed_contrast<=contrast;
                                if(time_dirty)begin
                            finite_mode<=draft_finite;hours<=draft_h;minutes<=draft_m;seconds<=0;subsecond<=0;
                        end
                        time_dirty<=0;
                    end
                end else if(!view_busy&&!cancel_thumbnail)begin
                    if(thumb_request||thumb_visible)begin
                        if(only2&&ready_banks[focus_bank^2'd1])focus_bank<=focus_bank^2'd1;
                        if(only3&&ready_banks[focus_bank^2'd2])focus_bank<=focus_bank^2'd2;
                        if(only4&&ready_banks[focus_bank])begin thumb_request<=0;open_request<=1;auto_toggle<=1;end
                    end else if(only4)auto_toggle<=1;
                    else if(image_visible)begin
                        if(only2)begin
                            case(zoom)
                                0:zoom<=5;5:zoom<=6;6:zoom<=7;7:zoom<=1;
                                1:zoom<=3;3:zoom<=2;2:zoom<=4;default:zoom<=0;
                            endcase
                        end
                        if(only3)begin if(auto_play)period_inc<=1;else next_image<=1;end
                    end
                end
            end
        end
        // IR never starts or extends local-button help. Page/menu visibility
        // continues to use the existing settings/thumbnail state and animation.
        if(ir_accept)begin
            if(sleeping)begin
                if(ir_action==4'd0)begin
                    sleeping<=0;settings_active<=0;finite_mode<=0;draft_finite<=0;subsecond<=0;
                    armed<=0;
                end
            end else if(ir_action==4'd0)begin
                sleeping<=1;settings_active<=0;time_dirty<=0;confirmed<=0;
                brightness<=committed_brightness;volume<=committed_volume;
                contrast<=committed_contrast;
            end else if(!recovery_priority&&!view_busy&&!cancel_thumbnail&&
                        (settings_active||image_visible)&&
                        !(timer_running&&hours==0&&minutes==0&&seconds<=1&&sec_tick))begin
                case(ir_action)
                    // Each shortcut commits only its own currently previewed field.
                    // At a limit it still focuses and commits that field, never the page.
                    2,8:begin
                        brightness<=(ir_action==2)?((brightness<9)?brightness+1'b1:brightness):
                                                   ((brightness>1)?brightness-1'b1:brightness);
                        committed_brightness<=(ir_action==2)?((brightness<9)?brightness+1'b1:brightness):
                                                             ((brightness>1)?brightness-1'b1:brightness);
                        if(settings_active)begin settings_focus<=3'd0;end
                    end
                    3,9:begin
                        volume<=(ir_action==3)?((volume<9)?volume+1'b1:volume):
                                               ((volume>0)?volume-1'b1:volume);
                        committed_volume<=(ir_action==3)?((volume<9)?volume+1'b1:volume):
                                                         ((volume>0)?volume-1'b1:volume);
                        if(settings_active)settings_focus<=3'd2;
                    end
                    4:if(!settings_active&&!thumb_request&&!thumb_visible)begin
                        auto_toggle<=1;ir_playback_event<=1;
                    end
                    5:if(!settings_active&&!auto_play)begin
                        if(!thumb_request&&!thumb_visible)begin thumb_request<=1;focus_bank<=active_bank;end
                        else if(ready_banks[focus_bank])begin thumb_request<=0;open_request<=1;end
                    end
                    6:if(music_available)music_paused<=!music_paused;
                    7:if(!settings_active&&!auto_play&&!thumb_request&&!thumb_visible)begin
                        next_image<=1;ir_playback_event<=1;
                    end
                    10:begin
                        if(settings_active)settings_focus<=3'd3;
                        if(music_available&&music_next_ready)music_next<=1;
                    end
                    11:if(!settings_active&&(thumb_request||thumb_visible)&&ready_banks[focus_bank^2'd1])
                        focus_bank<=focus_bank^2'd1;
                    12:if(!settings_active&&(thumb_request||thumb_visible)&&ready_banks[focus_bank^2'd2])
                        focus_bank<=focus_bank^2'd2;
                    13:if(!settings_active&&auto_play&&!thumb_request&&!thumb_visible)begin
                        period_inc<=1;ir_period_event<=1;
                    end
                    default:;
                endcase
            end
        end
    end
end
// The display consumes a separately synchronized tuple, including draft values.
endmodule
