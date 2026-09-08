// Streams a contiguous WAV data region from the existing SD sector reader.
// The first version uses a fixed physical start sector and byte count.
module sd_audio_reader #(
    parameter [31:0] AUDIO_START_SECTOR = 32'd32112,
    parameter [31:0] AUDIO_FILE_BYTES   = 32'd41444010
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        sd_init_done,
    output reg         sd_sec_read,
    output reg [31:0]  sd_sec_read_addr,
    input  wire [7:0]  sd_sec_read_data,
    input  wire        sd_sec_read_data_valid,
    input  wire        sd_sec_read_end,
    output reg         fifo_we,
    output reg [31:0]  fifo_din,
    input  wire        fifo_full,
    output reg         busy,
    output reg         done
);
    localparam [31:0] SECTOR_BYTES = 32'd512;
    reg [31:0] sector_index, bytes_seen;
    reg [1:0] byte_index;
    reg [7:0] b0,b1,b2;
    reg waiting_end;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sd_sec_read<=0; sd_sec_read_addr<=AUDIO_START_SECTOR; fifo_we<=0;
            fifo_din<=0; busy<=0; done<=0; sector_index<=0; bytes_seen<=0;
            byte_index<=0; b0<=0;b1<=0;b2<=0; waiting_end<=0;
        end else begin
            fifo_we <= 1'b0;
            done <= 1'b0;
            if (!busy && sd_init_done) begin
                busy<=1'b1; sector_index<=0; bytes_seen<=0; byte_index<=0;
                sd_sec_read_addr<=AUDIO_START_SECTOR; sd_sec_read<=1'b1; waiting_end<=0;
            end else if (busy) begin
                if (sd_sec_read_data_valid && bytes_seen < AUDIO_FILE_BYTES) begin
                    // Skip the canonical 44-byte PCM WAV header.  The first
                    // version of this reader accidentally sent the RIFF
                    // header to the HDMI audio path.
                    if (bytes_seen < 32'd44) begin
                        bytes_seen <= bytes_seen + 1'b1;
                    end else if (!fifo_full) begin
                    case (byte_index)
                        2'd0: b0 <= sd_sec_read_data;
                        2'd1: b1 <= sd_sec_read_data;
                        2'd2: b2 <= sd_sec_read_data;
                        2'd3: begin
                            fifo_din <= {sd_sec_read_data,b2,b1,b0};
                            fifo_we <= 1'b1;
                        end
                    endcase
                    byte_index <= byte_index + 1'b1;
                    bytes_seen <= bytes_seen + 1'b1;
                    end
                end
                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (bytes_seen >= AUDIO_FILE_BYTES-1 || sector_index >= ((AUDIO_FILE_BYTES+511)/512)-1) begin
                        busy<=1'b0; done<=1'b1;
                    end else begin
                        sector_index<=sector_index+1'b1;
                        sd_sec_read_addr<=AUDIO_START_SECTOR+sector_index+1'b1;
                        byte_index<=0; sd_sec_read<=1'b1;
                    end
                end
            end
        end
    end
endmodule
