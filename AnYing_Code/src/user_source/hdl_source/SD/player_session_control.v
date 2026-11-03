// session control. All time values use the existing SD clock; no new clock.
// Keys are already debounced by sd_card_bmp. Switch changes, restore and STOP
// changes reject stale key pulses and require all three keys released again.
module player_session_control #(
    parameter integer CLK_FREQ_HZ=100_000_000,
    parameter integer DEBOUNCE_MS=50,
    parameter integer SECONDS_PER_MINUTE=60,
    parameter integer DEFAULT_MINUTES=1,
    parameter integer CONFIG_RESTORE_ENABLE=0
)(
    input wire clk,rst,
    input wire settings_mode_in,settings_volume_in,timer_enable_in,
    input wire next_press,up_press,auto_press,
    input wire next_released,up_released,auto_released,
    input wire controls_enable,restore_apply,recovery_priority,
    input wire [3:0] restore_brightness,restore_volume,
    input wire auto_play,image_visible,
    output wire play_next_press,play_up_press,play_auto_press,
    output wire mode_set,mode_value,play_allowed,
    output reg [3:0] brightness_level,volume_level,
    output wire settings_active,settings_volume_selected,parameter_activity,
    output reg [1:0] session_state,
    output wire session_expired,session_timer_enabled,session_timer_running,
    output reg session_timer_page,
    output wire session_selected_auto,
    output wire [4:0] session_hours,
    output wire [5:0] session_minutes,
    output reg session_blink,
    output reg [1:0] session_zoom,session_rotate
);
localparam [1:0] PLAY=0, READY=1, WAIT_IMAGE=2, EXPIRED=3;
localparam integer CYCLES_PER_MS=(CLK_FREQ_HZ>=1000)?CLK_FREQ_HZ/1000:1;
localparam integer STABLE_CYCLES=(DEBOUNCE_MS>0)?CYCLES_PER_MS*DEBOUNCE_MS:1;
localparam integer DB_BITS=(STABLE_CYCLES>1)?$clog2(STABLE_CYCLES+1):1;
localparam integer SEC_CYCLES=(CLK_FREQ_HZ>0)?CLK_FREQ_HZ:1;
localparam integer SEC_BITS=(SEC_CYCLES>1)?$clog2(SEC_CYCLES):1;
localparam integer MIN_SECONDS=(SECONDS_PER_MINUTE>0)?SECONDS_PER_MINUTE:1;
localparam integer MIN_BITS=(MIN_SECONDS>1)?$clog2(MIN_SECONDS):1;
localparam integer DEFAULT_SAFE=(DEFAULT_MINUTES<1)?1:(DEFAULT_MINUTES>1440)?1440:DEFAULT_MINUTES;
reg [2:0] switch_sync0,switch_sync1,switch_observed,switch_stable;
reg [DB_BITS-1:0] stable_count;
reg switch_ready,keys_armed,recovery_observed,timer_observed;
reg [SEC_BITS-1:0] subsecond;
reg [MIN_BITS-1:0] second_in_minute;
reg [4:0] draft_hours,remaining_hours;
reg [5:0] draft_minutes,remaining_minutes;
reg timer_running,chosen_auto;
reg hold_minus,hold_plus,hold_tick_seen;
// Precompute the comparison for the next clock without delaying commands.
// Keep procedural-if semantics when a simulation switch value contains X/Z.
reg switch_changed;
reg [2:0] switch_observed_next;
always @* begin
    switch_observed_next=switch_observed;
    if(switch_changed) switch_observed_next=switch_sync1;
end
wire recovery_changed=(recovery_priority!=recovery_observed);
wire enabled=!CONFIG_RESTORE_ENABLE || controls_enable;
wire stable_context=enabled && !restore_apply && switch_ready && !switch_changed && !recovery_changed;
wire accept_press=stable_context && keys_armed;
wire any_press=next_press || up_press || auto_press;
wire only_minus=next_press && !up_press && !auto_press && up_released && auto_released;
wire only_plus=up_press && !next_press && !auto_press && next_released && auto_released;
wire only_auto=auto_press && !next_press && !up_press && next_released && up_released;
wire second_tick=(subsecond==SEC_CYCLES-1);
wire minute_tick=second_tick && (second_in_minute==MIN_SECONDS-1);
wire timer_changed=(switch_stable[2]!=timer_observed);
wire repeat_context=stable_context && settings_active && !recovery_priority && !session_expired && !auto_press;
wire minus_event=(accept_press && only_minus) ||
                 (repeat_context && hold_minus && !next_released && up_released && auto_released && hold_tick_seen && second_tick);
wire plus_event=(accept_press && only_plus) ||
                (repeat_context && hold_plus && !up_released && next_released && auto_released && hold_tick_seen && second_tick);
wire settings_event=repeat_context && (minus_event || plus_event);
wire timer_edit=settings_event && session_timer_page && session_timer_enabled;
wire basic_edit=settings_event && !session_timer_page;
wire last_minute=(remaining_hours==0 && remaining_minutes==1);
wire expire_now=timer_running && session_timer_enabled && minute_tick && last_minute;
assign settings_active=switch_stable[1];
assign settings_volume_selected=switch_stable[0];
assign session_timer_enabled=switch_stable[2];
assign session_timer_running=timer_running;
assign session_expired=(session_state==EXPIRED);
assign session_selected_auto=(session_state==READY || session_state==WAIT_IMAGE)?chosen_auto:auto_play;
assign session_hours=session_expired?5'd0:(settings_active && session_timer_page)?draft_hours:timer_running?remaining_hours:draft_hours;
assign session_minutes=session_expired?6'd0:(settings_active && session_timer_page)?draft_minutes:timer_running?remaining_minutes:draft_minutes;
assign play_allowed=(session_state==PLAY) && !timer_changed && !expire_now;
// Recovery still owns K2/K4 in STOP. An expired first press is wake only.
assign play_next_press=accept_press && !session_expired && !timer_changed && !expire_now && next_press && !auto_press &&
                       (recovery_priority || (play_allowed && !settings_active && (!auto_play || !settings_volume_selected)));
assign play_up_press=accept_press && !session_expired && !timer_changed && !expire_now && up_press && !auto_press &&
                     !recovery_priority && play_allowed && !settings_active && auto_play && !settings_volume_selected;
assign play_auto_press=accept_press && !session_expired && !timer_changed && !expire_now && auto_press &&
                       (recovery_priority || (play_allowed && !settings_active));
assign mode_set=(session_state==WAIT_IMAGE) && image_visible && !recovery_priority &&
                !settings_active && !timer_changed && stable_context;
assign mode_value=chosen_auto;
assign parameter_activity=basic_edit || timer_edit ||
                         (accept_press && any_press && !recovery_priority && !timer_changed && !expire_now);

always @(posedge clk or posedge rst) begin
    if(rst) begin switch_sync0<=0;switch_sync1<=0;switch_changed<=0;end
    else begin
        switch_sync0<={timer_enable_in,settings_mode_in,settings_volume_in};
        switch_sync1<=switch_sync0;
        switch_changed<=(switch_sync0!=switch_observed_next);
    end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        switch_observed<=0;switch_stable<=0;stable_count<=0;
        switch_ready<=0;keys_armed<=0;recovery_observed<=0;
    end else begin
        recovery_observed<=recovery_priority;
        if(switch_changed) begin
            switch_observed<=switch_sync1;stable_count<=0;switch_ready<=0;keys_armed<=0;
        end else if(!switch_ready) begin
            keys_armed<=0;
            if(stable_count>=STABLE_CYCLES-1) begin switch_stable<=switch_observed;switch_ready<=1;end
            else stable_count<=stable_count+1'b1;
        end else if(!enabled || restore_apply || recovery_changed || any_press) keys_armed<=0;
        else if(next_released && up_released && auto_released) keys_armed<=1;
    end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin hold_minus<=0;hold_plus<=0;hold_tick_seen<=0;end
    else if(!repeat_context || timer_changed || (next_released && up_released) ||
            (!next_released && !up_released)) begin hold_minus<=0;hold_plus<=0;hold_tick_seen<=0;end
    else if(accept_press && (only_minus || only_plus)) begin
        hold_minus<=only_minus;hold_plus<=only_plus;hold_tick_seen<=0;
    end else if(second_tick) hold_tick_seen<=1;
end
always @(posedge clk or posedge rst) begin
    if(rst) begin brightness_level<=9;volume_level<=9;end
    else if(CONFIG_RESTORE_ENABLE && restore_apply) begin
        brightness_level<=restore_brightness;volume_level<=restore_volume;
    end else if(basic_edit) begin
        if(settings_volume_selected) begin
            if(minus_event && volume_level>0)volume_level<=volume_level-1'b1;
            else if(plus_event && volume_level<9)volume_level<=volume_level+1'b1;
        end else begin
            if(minus_event && brightness_level>1)brightness_level<=brightness_level-1'b1;
            else if(plus_event && brightness_level<9)brightness_level<=brightness_level+1'b1;
        end
    end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin draft_hours<=DEFAULT_SAFE/60;draft_minutes<=DEFAULT_SAFE%60;end
    else if(timer_edit && !expire_now) begin
        if(settings_volume_selected) begin
            if(plus_event && draft_hours<24) begin
                if(draft_minutes==59)begin draft_minutes<=0;draft_hours<=draft_hours+1'b1;end
                else draft_minutes<=draft_minutes+1'b1;
            end else if(minus_event && (draft_hours!=0 || draft_minutes>1)) begin
                if(draft_minutes==0)begin draft_minutes<=59;draft_hours<=draft_hours-1'b1;end
                else draft_minutes<=draft_minutes-1'b1;
            end
        end else begin
            if(plus_event && draft_hours<24)begin
                draft_hours<=draft_hours+1'b1;
                if(draft_hours==23)draft_minutes<=0;
            end else if(minus_event && draft_hours!=0)begin
                draft_hours<=draft_hours-1'b1;
                if(draft_hours==1 && draft_minutes==0)draft_minutes<=1;
            end
        end
    end
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        session_state<=PLAY;session_timer_page<=0;timer_running<=0;timer_observed<=0;chosen_auto<=0;
        remaining_hours<=0;remaining_minutes<=0;subsecond<=0;second_in_minute<=0;session_blink<=0;
        session_zoom<=0;session_rotate<=0;
    end else begin
        timer_observed<=session_timer_enabled;
        if(second_tick)begin subsecond<=0;session_blink<=~session_blink;end
        else subsecond<=subsecond+1'b1;
        if(!settings_active || !session_timer_enabled)session_timer_page<=0;
        if(session_state==PLAY && !auto_play)begin session_zoom<=0;session_rotate<=0;end
        // Cancel has precedence over exact expiry, but never wakes an expired session.
        if(timer_changed)begin
            timer_running<=0;second_in_minute<=0;
            if(session_timer_enabled && !session_expired)begin session_state<=READY;chosen_auto<=auto_play;end
            else if(!session_expired && session_state!=READY)session_state<=PLAY;
        end else if(expire_now) begin
            session_state<=EXPIRED;timer_running<=0;remaining_hours<=0;remaining_minutes<=0;
            second_in_minute<=0;
        end else begin
            if(timer_running && second_tick)begin
                if(minute_tick)begin
                    second_in_minute<=0;
                    if(remaining_minutes==0)begin remaining_hours<=remaining_hours-1'b1;remaining_minutes<=59;end
                    else remaining_minutes<=remaining_minutes-1'b1;
                end else second_in_minute<=second_in_minute+1'b1;
            end
            if(session_expired)begin
                if(accept_press && any_press)begin session_state<=READY;chosen_auto<=auto_play;end
            end else if(!recovery_priority)begin
                if(timer_edit)begin session_state<=READY;timer_running<=0;chosen_auto<=auto_play;end
                else if(accept_press && only_auto && settings_active)begin
                    if(session_timer_enabled)session_timer_page<=~session_timer_page;
                end else if(session_state==READY && !settings_active && accept_press)begin
                    if(only_minus)chosen_auto<=0;
                    else if(only_plus)chosen_auto<=1;
                    else if(only_auto)session_state<=WAIT_IMAGE;
                end else if(mode_set)begin
                    session_state<=PLAY;timer_running<=session_timer_enabled;
                    remaining_hours<=draft_hours;remaining_minutes<=draft_minutes;
                    second_in_minute<=0;subsecond<=0;session_blink<=0;
                    if(!chosen_auto)begin session_zoom<=0;session_rotate<=0;end
                end else if(play_allowed && !settings_active && auto_play && settings_volume_selected && accept_press)begin
                    if(only_minus)session_zoom<=(session_zoom==2)?2'd0:session_zoom+1'b1;
                    else if(only_plus)session_rotate<=session_rotate+1'b1;
                end
            end
        end
    end
end
endmodule
