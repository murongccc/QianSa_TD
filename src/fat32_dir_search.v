// Searches one FAT32 directory cluster for the 8.3 name WAN_CAN_GE.WAV.
// Feed directory-sector bytes sequentially. Directory entries are 32 bytes.
module fat32_dir_search #(
    // FAT32 short-name alias for the long file name WAN_CAN_GE.WAV.
    // The directory entry stores at most 8 base characters.
    parameter [7:0] N0=8'h57, N1=8'h41, N2=8'h4E, N3=8'h5F, N4=8'h43,
    parameter [7:0] N5=8'h41, N6=8'h4E, N7=8'h5F,
    parameter [7:0] E0=8'h57, E1=8'h41, E2=8'h56
) (
    input wire clk, input wire rst, input wire start,
    input wire byte_valid, input wire [7:0] byte_data,
    output reg busy, output reg done, output reg found,
    output reg [31:0] first_cluster, output reg [31:0] file_size
);
    reg [8:0] pos; reg [7:0] ent[0:31]; integer i;
    wire [4:0] ep = pos[4:0];
    always @(posedge clk or posedge rst) begin
        if (rst) begin busy<=0; done<=0; found<=0; pos<=0; first_cluster<=0; file_size<=0; for(i=0;i<32;i=i+1) ent[i]<=0; end
        else begin
            done<=0;
            if (start && !busy) begin busy<=1; found<=0; pos<=0; end
            else if (busy && byte_valid) begin
                ent[ep] <= byte_data;
                if (ep==5'd31) begin
                    // byte_data is entry byte 31; nonblocking assignment to
                    // ent[31] is not visible until the next clock.
                    if (ent[0]!=8'h00 && ent[0]!=8'hE5 && ent[11]!=8'h0F &&
                        ent[0]==N0 && ent[1]==N1 && ent[2]==N2 && ent[3]==N3 && ent[4]==N4 &&
                        ent[5]==N5 && ent[6]==N6 && ent[7]==N7 &&
                        ent[11]!=8'h0F && ent[8]==E0 && ent[9]==E1 && ent[10]==E2) begin
                        found<=1; first_cluster<={ent[21],ent[20],ent[27],ent[26]}; file_size<={byte_data,ent[30],ent[29],ent[28]};
                    end
                    if (ent[0]==8'h00) begin busy<=0; done<=1; end
                end
                pos<=pos+1'b1;
            end
        end
    end
endmodule
