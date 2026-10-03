// 直接使用器件已有 BRAM9K/BRAM32K 原语，避免小容量多路复用内存占用 LUT。
// 同步读一拍，内容不复位；消费者必须用有效标志隔离旧数据。不生成/修改厂商 IP。
module rhythm_block_ram #(
    parameter IMPLEMENT="32K",parameter integer WIDTH=8,parameter integer ADDRESS_BITS=6,parameter integer DEPTH=64
)(
    input wire write_clk,input wire write_enable,input wire [ADDRESS_BITS-1:0] write_address,
    input wire [WIDTH-1:0] write_data,
    input wire read_clk,input wire [ADDRESS_BITS-1:0] read_address,output wire [WIDTH-1:0] read_data
);
    EG_LOGIC_BRAM #(.DATA_WIDTH_A(WIDTH),.DATA_WIDTH_B(WIDTH),.ADDR_WIDTH_A(ADDRESS_BITS),.ADDR_WIDTH_B(ADDRESS_BITS),
        .DATA_DEPTH_A(DEPTH),.DATA_DEPTH_B(DEPTH),.MODE("PDPW"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.RESETMODE("SYNC"),.IMPLEMENT(IMPLEMENT),.INIT_FILE("NONE"),.FILL_ALL("NONE")) ram(
        .dia(write_data),.dib({WIDTH{1'b0}}),.addra(write_address),.addrb(read_address),.cea(write_enable),.ceb(1'b1),
        .ocea(1'b0),.oceb(1'b1),.clka(write_clk),.clkb(read_clk),.wea(1'b1),.web(1'b0),.bea(1'b0),.beb(1'b0),
        .rsta(1'b0),.rstb(1'b0),.doa(),.dob(read_data));
endmodule
