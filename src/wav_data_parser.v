// Streaming WAV chunk parser. Searches for fmt  and data in arbitrary order.
module wav_data_parser(
 input wire clk,input wire rst,input wire start,input wire byte_valid,input wire [7:0] byte_data,
 output reg busy,output reg done,output reg format_ok,output reg data_found,
 output reg [31:0] data_length,output reg [31:0] data_skip,
 output reg [15:0] channels,output reg [31:0] sample_rate,output reg [15:0] bits_per_sample
);
 reg [31:0] pos; reg [7:0] q0,q1,q2; reg [31:0] chunk_size; reg [1:0] chunk_type;
 reg fmt_seen; reg [15:0] afmt;
 always @(posedge clk or posedge rst) begin
  if(rst) begin busy<=0;done<=0;format_ok<=0;data_found<=0;pos<=0;q0<=0;q1<=0;q2<=0;chunk_size<=0;chunk_type<=0;fmt_seen<=0;afmt<=0;channels<=0;sample_rate<=0;bits_per_sample<=0;data_length<=0;data_skip<=0; end
  else begin done<=0;
   if(start&&!busy) begin busy<=1;pos<=0;fmt_seen<=0;data_found<=0;format_ok<=0;end
   else if(busy&&byte_valid) begin
    q2<=q1;q1<=q0;q0<=byte_data;
    if({q2,q1,q0,byte_data}=="fmt ") chunk_type<=1;
    if({q2,q1,q0,byte_data}=="data") begin chunk_type<=2; data_found<=1; data_skip<=pos+1; end
    if(chunk_type==1 && pos>=19 && pos<=38) begin
      if(pos==20) afmt<={q1,q0};
      if(pos==22) channels<={q1,q0};
      if(pos==24) sample_rate<={q2,q1,q0,byte_data};
      if(pos==34) bits_per_sample<={q1,q0};
      if(pos==38) fmt_seen<=1;
    end
    if(data_found && pos==data_skip+3) data_length<={q2,q1,q0,byte_data};
    if(pos==32'h0000FFFF || (data_found&&pos>=data_skip+3)) begin busy<=0;done<=1;format_ok<=fmt_seen&&(afmt==1)&&(channels==2)&&(sample_rate==48000)&&(bits_per_sample==16);end
    pos<=pos+1;
   end
  end
 end
endmodule
