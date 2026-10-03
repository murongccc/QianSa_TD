// Clients hold request/address until their done pulse. One complete SD
// transaction owns the return path, regardless of subsequent request changes.
module sd_sector_arbiter #(
    parameter integer ENABLE_CHART=0
)(
    input wire clk, input wire rst,
    input wire bmp_req, input wire [31:0] bmp_addr,
    input wire audio_req, input wire [31:0] audio_addr,
    input wire audio_urgent,
    output wire sd_req, output reg [31:0] sd_addr,
    input wire sd_valid, input wire sd_done,
    output wire bmp_valid, output wire bmp_done,
    output wire audio_valid, output wire audio_done,
    input wire chart_req, input wire [31:0] chart_addr,
    output wire chart_valid, output wire chart_done
);
    localparam IDLE=2'd0, ACTIVE=2'd1, GAP=2'd2;
    reg [1:0] state;
    reg owner_audio, last_audio;
    reg owner_chart,last_chart;
    wire chart_request=ENABLE_CHART && chart_req;
    // A sector already in flight is never interrupted.  Between sectors,
    // protect the PCM reservoir before applying normal fair arbitration.
    wire choose_audio = audio_req && (audio_urgent || (!(bmp_req || chart_request)) || !last_audio);
    wire choose_chart = !choose_audio && chart_request && (!bmp_req || !last_chart);
    assign sd_req = (state == ACTIVE);
    assign bmp_valid = sd_valid && state == ACTIVE && !owner_audio && !owner_chart;
    assign bmp_done = sd_done && state == ACTIVE && !owner_audio && !owner_chart;
    assign audio_valid = sd_valid && state == ACTIVE && owner_audio;
    assign audio_done = sd_done && state == ACTIVE && owner_audio;
    assign chart_valid=sd_valid && state==ACTIVE && owner_chart;
    assign chart_done=sd_done && state==ACTIVE && owner_chart;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state<=IDLE; sd_addr<=0; owner_audio<=0; last_audio<=1;
            owner_chart<=0;last_chart<=1;
        end else case (state)
            IDLE: if (bmp_req || audio_req || chart_request) begin
                owner_audio<=choose_audio;
                owner_chart<=choose_chart;
                sd_addr<=choose_audio ? audio_addr : (choose_chart ? chart_addr : bmp_addr);
                state<=ACTIVE;
            end
            ACTIVE: if (sd_done) begin
                last_audio<=owner_audio;
                if(!owner_audio)last_chart<=owner_chart;
                state<=GAP;
            end
            // sd_card_sec_read_write returns to WAIT_READ_WRITE at done.
            // Keep request low while clients retire/update their requests.
            GAP: state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
