`timescale 1ns / 1ps

module tb_SlicerArbiterTop;

localparam int MAX_WAIT_CYCLES = 2_000_000;

logic         clock = 1'b0;
logic         reset = 1'b1;
logic         io_start = 1'b0;
logic [15:0]  io_payload_len = 16'd64;
logic [7:0]   io_idle_cycle = 8'd0;

wire          io_s_axis_ready;
logic         io_s_axis_valid = 1'b0;
logic         io_s_axis_bits_last = 1'b0;
logic [511:0] io_s_axis_bits_data = '0;
logic [63:0]  io_s_axis_bits_keep = '0;

logic         io_meta_out_ready = 1'b1;
wire          io_meta_out_valid;
wire [31:0]   io_meta_out_bits_src_ipv4;
wire [31:0]   io_meta_out_bits_dst_ipv4;
wire [15:0]   io_meta_out_bits_src_port;
wire [15:0]   io_meta_out_bits_dst_port;
wire [7:0]    io_meta_out_bits_op_code;
wire [23:0]   io_meta_out_bits_qpn;

logic         io_m_axis_ready = 1'b1;
wire          io_m_axis_valid;
wire          io_m_axis_bits_last;
wire [511:0]  io_m_axis_bits_data;
wire [63:0]   io_m_axis_bits_keep;

wire [31:0]   io_event_count;
logic         io_cpu_reset = 1'b1;
logic [31:0]  io_imem_addr;
logic         io_imem_wr_en;
logic [3:0]   io_imem_musk;
logic [31:0]  io_imem_data_in;

logic         io_axi_aw_ready = 1'b1;
wire          io_axi_aw_valid;
wire [32:0]   io_axi_aw_bits_addr;
wire [1:0]    io_axi_aw_bits_burst;
wire [3:0]    io_axi_aw_bits_cache;
wire [5:0]    io_axi_aw_bits_id;
wire [3:0]    io_axi_aw_bits_len;
wire          io_axi_aw_bits_lock;
wire [2:0]    io_axi_aw_bits_prot;
wire [3:0]    io_axi_aw_bits_qos;
wire [3:0]    io_axi_aw_bits_region;
wire [2:0]    io_axi_aw_bits_size;

logic         io_axi_ar_ready = 1'b1;
wire          io_axi_ar_valid;
wire [32:0]   io_axi_ar_bits_addr;
wire [1:0]    io_axi_ar_bits_burst;
wire [3:0]    io_axi_ar_bits_cache;
wire [5:0]    io_axi_ar_bits_id;
wire [3:0]    io_axi_ar_bits_len;
wire          io_axi_ar_bits_lock;
wire [2:0]    io_axi_ar_bits_prot;
wire [3:0]    io_axi_ar_bits_qos;
wire [3:0]    io_axi_ar_bits_region;
wire [2:0]    io_axi_ar_bits_size;

logic         io_axi_w_ready = 1'b1;
wire          io_axi_w_valid;
wire [255:0]  io_axi_w_bits_data;
wire          io_axi_w_bits_last;
wire [31:0]   io_axi_w_bits_strb;

wire          io_axi_r_ready;
logic         io_axi_r_valid = 1'b0;
logic [255:0] io_axi_r_bits_data = '0;
logic         io_axi_r_bits_last = 1'b0;
logic [1:0]   io_axi_r_bits_resp = '0;
logic [5:0]   io_axi_r_bits_id = '0;

wire          io_axi_b_ready;
logic         io_axi_b_valid = 1'b0;
logic [5:0]   io_axi_b_bits_id = '0;
logic [1:0]   io_axi_b_bits_resp = '0;

integer payload_count = 0;
integer meta_count = 0;

// RX program image loaded from inst_rx.mem (flat 32-bit words).
// inst_rx.mem holds words at addrs 0x000..0x358 (857 words).
localparam int RX_WORDS = 857;
logic [31:0] rx_image [0:4095];

initial begin
    $readmemh("/home/lbx/core4nic/core/tb/inst_rx.mem", rx_image);
end

function automatic [511:0] expected_payload_data;
    integer word_index;
    integer byte_index;
    reg [63:0] word_value;
    reg [511:0] result;
    begin
        result = '0;
        for (word_index = 0; word_index < 8; word_index = word_index + 1) begin
            word_value = 64'h0000_0000_cafe_babe + word_index;
            for (byte_index = 0; byte_index < 8; byte_index = byte_index + 1) begin
                result[(word_index * 64) + (byte_index * 8) +: 8] =
                    word_value[63 - (byte_index * 8) -: 8];
            end
        end
        expected_payload_data = result;
    end
endfunction

// All testbench signals intentionally use the generated DUT port names.
SlicerArbiterTop dut (
    .io_imem_addr(io_imem_addr),
    .io_imem_wr_en(io_imem_wr_en),
    .io_imem_musk(io_imem_musk),
    .io_imem_data_in(io_imem_data_in),
    .*);

always #3.2 clock = ~clock;

always @(posedge clock) begin
    if (!reset && io_m_axis_valid && io_m_axis_ready) begin
        payload_count <= payload_count + 1;
        if (payload_count != 0)
            $fatal(1, "Unexpected extra payload beat");
        if (!io_m_axis_bits_last)
            $fatal(1, "64-byte payload must complete in one beat");
        if (io_m_axis_bits_keep !== 64'hffff_ffff_ffff_ffff)
            $fatal(1, "Unexpected payload keep: %h", io_m_axis_bits_keep);
        if (io_m_axis_bits_data !== expected_payload_data())
            $fatal(1, "Payload data mismatch: got=%h expected=%h",
                   io_m_axis_bits_data, expected_payload_data());
    end
end

always @(posedge clock) begin
    if (!reset && io_meta_out_valid && io_meta_out_ready) begin
        meta_count <= meta_count + 1;
        if (meta_count != 0)
            $fatal(1, "Unexpected extra metadata output");
        if ($isunknown({
            io_meta_out_bits_src_ipv4,
            io_meta_out_bits_dst_ipv4,
            io_meta_out_bits_src_port,
            io_meta_out_bits_dst_port,
            io_meta_out_bits_op_code,
            io_meta_out_bits_qpn
        })) begin
            $fatal(1, "Metadata output contains X/Z values");
        end
        if ({
            io_meta_out_bits_src_ipv4,
            io_meta_out_bits_dst_ipv4,
            io_meta_out_bits_src_port,
            io_meta_out_bits_dst_port,
            io_meta_out_bits_op_code,
            io_meta_out_bits_qpn
        } !== {
            32'hc0a80101,
            32'hc0a80102,
            16'd4791,
            16'd4791,
            8'h0a,
            24'd1
        }) begin
            $fatal(1,
                   "Metadata output mismatch: src_ip=%h dst_ip=%h src_port=%0d dst_port=%0d opcode=%h qpn=%h",
                   io_meta_out_bits_src_ipv4,
                   io_meta_out_bits_dst_ipv4,
                   io_meta_out_bits_src_port,
                   io_meta_out_bits_dst_port,
                   io_meta_out_bits_op_code,
                   io_meta_out_bits_qpn);
        end
    end
end

initial begin : main_test
    integer wait_cycles;
    integer i;

    $timeformat(-9, 3, " ns", 12);
    reset = 1'b1;
    io_cpu_reset = 1'b1;
    io_imem_addr = 32'h8000_0000;
    io_imem_data_in = 32'h0;
    io_imem_musk = 4'h0;
    io_imem_wr_en = 1'b0;

    repeat (20) @(posedge clock);
    reset = 1'b0;
    // Let the XRam usr_rst_delay (ShiftRegister(reset,4)) clear before writing imem.
    repeat (20) @(posedge clock);

    // Load inst_rx.mem into instruction memory while the CPU is held in reset.
    for (i = 0; i < RX_WORDS; i++) begin
        @(negedge clock);
        io_imem_addr    = 32'h8000_0000 + i * 4;
        io_imem_data_in = rx_image[i];
        io_imem_musk    = 4'hf;
        io_imem_wr_en   = 1'b1;
    end
    @(negedge clock);
    io_imem_wr_en = 1'b0;
    io_imem_musk  = 4'h0;

    // Release the CPU reset so the loaded RX firmware starts running.
    repeat (2) @(posedge clock);
    io_cpu_reset = 1'b0;

    // Allow the RX firmware to initialize its CSR layout and polling loop.
    repeat (2000) @(posedge clock);

    // A one-cycle level assertion starts exactly one packet.
    @(negedge clock);
    io_start = 1'b1;
    @(negedge clock);
    io_start = 1'b0;

    wait_cycles = 0;
    while (
        payload_count < 1 ||
        meta_count < 1
    ) begin
        @(posedge clock);
        wait_cycles = wait_cycles + 1;
        if (wait_cycles >= MAX_WAIT_CYCLES)
            $fatal(1,
                "Timeout: payload=%0d metadata=%0d",
                payload_count, meta_count);
    end

    repeat (20) @(posedge clock);
    if (payload_count != 1 || meta_count != 1)
        $fatal(1,
            "Unexpected counts: payload=%0d metadata=%0d",
            payload_count, meta_count);

    $display("[%0t] PASS: payload and metadata pipeline completed", $time);
    $finish;
end


endmodule
