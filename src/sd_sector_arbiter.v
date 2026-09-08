// Clients hold request/address until their done pulse. One complete SD
// transaction owns the return path, regardless of subsequent request changes.
module sd_sector_arbiter (
    input wire clk, input wire rst,
    input wire bmp_req, input wire [31:0] bmp_addr,
    input wire audio_req, input wire [31:0] audio_addr,
    output wire sd_req, output reg [31:0] sd_addr,
    input wire sd_valid, input wire sd_done,
    output wire bmp_valid, output wire bmp_done,
    output wire audio_valid, output wire audio_done
);
    localparam IDLE=2'd0, ACTIVE=2'd1, GAP=2'd2;
    reg [1:0] state;
    reg owner_audio, last_audio;
    wire choose_audio = audio_req && (!bmp_req || !last_audio);
    assign sd_req = (state == ACTIVE);
    assign bmp_valid = sd_valid && state == ACTIVE && !owner_audio;
    assign bmp_done = sd_done && state == ACTIVE && !owner_audio;
    assign audio_valid = sd_valid && state == ACTIVE && owner_audio;
    assign audio_done = sd_done && state == ACTIVE && owner_audio;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state<=IDLE; sd_addr<=0; owner_audio<=0; last_audio<=1;
        end else case (state)
            IDLE: if (bmp_req || audio_req) begin
                owner_audio<=choose_audio;
                sd_addr<=choose_audio ? audio_addr : bmp_addr;
                state<=ACTIVE;
            end
            ACTIVE: if (sd_done) begin
                last_audio<=owner_audio;
                state<=GAP;
            end
            // sd_card_sec_read_write returns to WAIT_READ_WRITE at done.
            // Keep request low while clients retire/update their requests.
            GAP: state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
