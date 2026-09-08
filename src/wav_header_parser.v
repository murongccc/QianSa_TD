// Parses a WAV header delivered as sequential bytes from the first file sector.
// First-version player accepts PCM, stereo, 48 kHz, 16-bit samples.
module wav_header_parser #(
    parameter integer MAX_HEADER_BYTES = 512
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire        byte_valid,
    input  wire [7:0]  byte_data,
    output reg         busy,
    output reg         done,
    output reg         format_ok,
    output reg [31:0]  data_offset,
    output reg [31:0]  data_length,
    output reg [15:0]  channels,
    output reg [31:0]  sample_rate,
    output reg [15:0]  bits_per_sample
);
    reg [9:0] pos;
    reg [7:0] b0,b1,b2,b3;
    reg [31:0] fmt_size, data_pos;
    reg [15:0] audio_format;
    reg fmt_found, data_found, riff_ok, wave_ok;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy<=0; done<=0; format_ok<=0; pos<=0; b0<=0;b1<=0;b2<=0;b3<=0;
            fmt_size<=0; data_pos<=0; audio_format<=0; fmt_found<=0; data_found<=0;
            riff_ok<=0; wave_ok<=0; data_offset<=0; data_length<=0;
            channels<=0; sample_rate<=0; bits_per_sample<=0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy<=1'b1; pos<=0; fmt_found<=0; data_found<=0; riff_ok<=0; wave_ok<=0;
                format_ok<=0; data_offset<=0; data_length<=0;
            end else if (busy && byte_valid) begin
                b3<=b2; b2<=b1; b1<=b0; b0<=byte_data;
                if (pos==3 && {b0,b1,b2,byte_data}=="RIFF") riff_ok<=1'b1;
                if (pos==11 && {b0,b1,b2,byte_data}=="WAVE") wave_ok<=1'b1;
                // fmt chunk: bytes 12..15='fmt ', payload starts at 20.
                if (pos==15 && {b0,b1,b2,byte_data}=="fmt ") fmt_size<=0;
                if (pos==19) fmt_size <= {b0,b1,b2,byte_data};
                if (pos==20) audio_format <= {b0,b1};
                if (pos==22) channels <= {b0,b1};
                if (pos==24) sample_rate <= {b0,b1,b2,byte_data};
                if (pos==34) bits_per_sample <= {b0,b1};
                // Standard PCM stereo WAV used by this project has data at byte 36.
                if (pos==39 && {b0,b1,b2,byte_data}=="data") begin
                    data_pos<=pos-3; data_found<=1'b1;
                end
                if (data_found && pos==43) begin
                    data_offset<=44; data_length<={b0,b1,b2,byte_data};
                end
                if (pos==MAX_HEADER_BYTES-1 || (data_found && pos>=43)) begin
                    busy<=1'b0; done<=1'b1;
                    format_ok <= riff_ok && wave_ok && fmt_found && data_found &&
                                 (audio_format==16'd1) && (channels==16'd2) &&
                                 (sample_rate==32'd48000) && (bits_per_sample==16'd16);
                end
                if (pos==19) fmt_found<=1'b1;
                pos<=pos+1'b1;
            end
        end
    end
endmodule
