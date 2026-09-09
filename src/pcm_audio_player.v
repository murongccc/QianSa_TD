// Prefetch from the synchronous-read EG_LOGIC_FIFO (REGMODE_R=NOREG).
// NOREG disables the EXTRA output register; it is not a FWFT interface.
module pcm_audio_player #(
    parameter integer PIXEL_CLOCK_HZ = 25_000_000,
    parameter integer SAMPLE_RATE_HZ = 48_000
) (
    input wire clk, input wire rst,
    input wire [31:0] fifo_dout, input wire fifo_empty,
    input wire [2:0] volume_level_async,
    input wire [1:0] playback_mode_async,
    output reg fifo_re, output reg audio_valid,
    output reg [23:0] left_pcm, output reg [23:0] right_pcm,
    output reg underrun
);
    localparam [31:0] CLOCK_RATE = PIXEL_CLOCK_HZ;
    localparam [31:0] SAMPLE_RATE = SAMPLE_RATE_HZ;
    reg [31:0] phase;
    wire [32:0] phase_sum = {1'b0,phase} + {1'b0,SAMPLE_RATE};
    wire sample_tick = phase_sum >= {1'b0,CLOCK_RATE};
    wire [32:0] phase_next = sample_tick ? phase_sum - {1'b0,CLOCK_RATE} : phase_sum;
    reg read_pending, sample_ready;
    reg [31:0] sample_buffer;
    reg [5:0] fallback_sample_count;
    reg [2:0] volume_meta, volume_sync;
    reg [1:0] playback_mode_meta, playback_mode_sync;
    localparam [1:0] MODE_STOP=2'd0, MODE_PLAY=2'd1, MODE_PAUSE=2'd2;

    function [23:0] scale_pcm;
        input [15:0] sample;
        input [2:0] level;
        reg signed [26:0] expanded, scaled;
        begin
            // Left alignment preserves normalized PCM amplitude (16 -> 24).
            expanded = $signed({{3{sample[15]}}, sample, 8'd0});
            case(level)
                3'd0: scaled = 27'sd0;
                3'd1: scaled = expanded >>> 3;
                3'd2: scaled = expanded >>> 2;
                3'd3: scaled = expanded >>> 1;
                3'd4: scaled = expanded;
                3'd5: scaled = expanded + (expanded >>> 1);
                3'd6: scaled = expanded <<< 1;
                default: scaled = (expanded <<< 1) + (expanded >>> 1);
            endcase
            if (scaled > 27'sd8388607) scale_pcm = 24'h7fffff;
            else if (scaled < -27'sd8388608) scale_pcm = 24'h800000;
            else scale_pcm = scaled[23:0];
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            phase<=32'd0; fifo_re<=1'b0; audio_valid<=1'b0;
            left_pcm<=24'd0; right_pcm<=24'd0; underrun<=1'b0;
            read_pending<=1'b0; sample_ready<=1'b0; sample_buffer<=32'd0;
            fallback_sample_count<=6'd0;
            volume_meta<=3'd4; volume_sync<=3'd4;
            playback_mode_meta<=MODE_STOP; playback_mode_sync<=MODE_STOP;
        end else begin
            volume_meta<=volume_level_async; volume_sync<=volume_meta;
            playback_mode_meta<=playback_mode_async; playback_mode_sync<=playback_mode_meta;
            phase<=phase_next[31:0];
            fifo_re<=1'b0;
            // Keep HDMI/ACR at 48 kHz even while muted.
            audio_valid<=sample_tick;
            if (playback_mode_sync == MODE_STOP) begin
                fifo_re<=!fifo_empty;
                read_pending<=1'b0; sample_ready<=1'b0; underrun<=1'b0;
                left_pcm<=24'd0; right_pcm<=24'd0;
            end else if (playback_mode_sync == MODE_PAUSE) begin
                // Complete a read already issued before the pause edge.
                read_pending<=1'b0;
                if (read_pending) begin sample_buffer<=fifo_dout; sample_ready<=1'b1; end
                left_pcm<=24'd0; right_pcm<=24'd0;
            end else begin
                read_pending<=fifo_re && !fifo_empty;
                if (!sample_ready && !read_pending && !fifo_re && !fifo_empty) fifo_re<=1'b1;
                if (read_pending) begin sample_buffer<=fifo_dout; sample_ready<=1'b1; end
                if (sample_tick) begin
                    if (sample_ready) begin
                        left_pcm<=scale_pcm(sample_buffer[15:0],volume_sync);
                        right_pcm<=scale_pcm(sample_buffer[31:16],volume_sync);
                        sample_ready<=1'b0;
                    end else begin
                        if (fallback_sample_count < 6'd24) begin
                            left_pcm<=24'sd1000000; right_pcm<=24'sd1000000;
                        end else begin
                            left_pcm<=-24'sd1000000; right_pcm<=-24'sd1000000;
                        end
                        if (fallback_sample_count == 6'd47) fallback_sample_count<=6'd0;
                        else fallback_sample_count<=fallback_sample_count + 1'b1;
                        underrun<=1'b1;
                    end
                end
            end
        end
    end
endmodule

module audio_playback_control #(
    parameter integer CLK_FREQ_HZ=100_000_000, parameter integer DEBOUNCE_MS=20
)(
    input wire clk,input wire rst,input wire play_pause_key_n,input wire run_switch,
    input wire fifo_empty_async,output reg [1:0] player_mode,
    output wire reader_enable,output wire reader_reset
);
    localparam [1:0] ST_STOPPED=2'd0, ST_STARTING=2'd1,
                     ST_PLAYING=2'd2, ST_PAUSED=2'd3;
    localparam [1:0] MODE_STOP=2'd0, MODE_PLAY=2'd1, MODE_PAUSE=2'd2;
    wire key_level, key_press, switch_level;
    reg fifo_empty_meta, fifo_empty_sync;
    reg [1:0] state;
audio_control_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(DEBOUNCE_MS),.RESET_LEVEL(1'b1)) u_key(
 .clk(clk),.rst(rst),.async_in(play_pause_key_n),.stable_level(key_level),.fall_pulse(key_press));
audio_control_debounce #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.DEBOUNCE_MS(DEBOUNCE_MS),.RESET_LEVEL(1'b0)) u_switch(
 .clk(clk),.rst(rst),.async_in(run_switch),.stable_level(switch_level),.fall_pulse());
assign reader_enable=(state==ST_PLAYING);
assign reader_reset=(state==ST_STOPPED)||(state==ST_STARTING);
always @(*) case(state) ST_PLAYING:player_mode=MODE_PLAY; ST_PAUSED:player_mode=MODE_PAUSE; default:player_mode=MODE_STOP; endcase
always @(posedge clk or posedge rst) begin
 if(rst) begin fifo_empty_meta<=1'b1;fifo_empty_sync<=1'b1;state<=ST_STOPPED;end
 else begin
  fifo_empty_meta<=fifo_empty_async;fifo_empty_sync<=fifo_empty_meta;
  case(state)
   ST_STOPPED:if(switch_level)state<=ST_STARTING;
   ST_STARTING:if(!switch_level)state<=ST_STOPPED;else if(fifo_empty_sync)state<=ST_PLAYING;
   ST_PLAYING:if(!switch_level)state<=ST_STOPPED;else if(key_press)state<=ST_PAUSED;
   ST_PAUSED:if(!switch_level)state<=ST_STOPPED;else if(key_press)state<=ST_PLAYING;
   default:state<=ST_STOPPED;
  endcase
 end
end
endmodule

module audio_control_debounce #(
 parameter integer CLK_FREQ_HZ=100_000_000,parameter integer DEBOUNCE_MS=20,parameter RESET_LEVEL=1'b0
)(input wire clk,input wire rst,input wire async_in,output reg stable_level,output reg fall_pulse);
localparam integer DEBOUNCE_CYCLES=(CLK_FREQ_HZ/1000)*DEBOUNCE_MS;
reg sync0,sync1;reg [31:0] count;
always @(posedge clk or posedge rst) begin
 if(rst)begin sync0<=RESET_LEVEL;sync1<=RESET_LEVEL;stable_level<=RESET_LEVEL;fall_pulse<=1'b0;count<=0;end
 else begin sync0<=async_in;sync1<=sync0;fall_pulse<=1'b0;
  if(sync1==stable_level)count<=0;
  else if(count>=DEBOUNCE_CYCLES-1)begin if(stable_level&&!sync1)fall_pulse<=1'b1;stable_level<=sync1;count<=0;end
  else count<=count+1'b1;
 end
end
endmodule
