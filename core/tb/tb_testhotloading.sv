`timescale 1ns / 1ns

// Merged Testbench for test_hotloading

module tb_test_hotloading();

reg                 clock                         =0;
reg                 reset                         =0;
reg                 io_loading_start              =0;
reg       [63:0]    io_host_mem_addr              =0;
reg       [31:0]    io_imem_base_addr             =32'h8000_0000;
reg       [31:0]    io_mem_length                 =0;
reg       [23:0]    io_version                    =0;
reg       [15:0]    io_page_idx                   =0;
reg       [15:0]    io_shadow_slot                =0;
reg                 io_vrt_update_enable          =0;
wire                io_vrt_hit;
wire                io_vrt_full;
wire                io_core_started                ;
reg                 io_has_event_wr               = 0;
wire                io_has_event_rd               ;
wire [31:0]         io_event_recv_cnt             ;
wire [31:0]         io_event_processed_cnt        ;
wire [31:0]         io_event_count                ;
wire                io_h2c_cmd_ready              ;
wire                io_h2c_cmd_valid              ;
wire      [63:0]    io_h2c_cmd_bits_addr          ;
wire      [31:0]    io_h2c_cmd_bits_len           ;
wire                io_h2c_cmd_bits_eop           ;
wire                io_h2c_cmd_bits_sop           ;
wire                io_h2c_cmd_bits_mrkr_req      ;
wire                io_h2c_cmd_bits_sdi           ;
wire      [10:0]    io_h2c_cmd_bits_qid           ;
wire                io_h2c_cmd_bits_error         ;
wire      [7:0]     io_h2c_cmd_bits_func          ;
wire      [15:0]    io_h2c_cmd_bits_cidx          ;
wire      [2:0]     io_h2c_cmd_bits_port_id       ;
wire                io_h2c_cmd_bits_no_dma        ;

wire                io_h2c_data_ready             ;
wire                 io_h2c_data_valid             ;
wire       [511:0]   io_h2c_data_bits_data         ;
wire                 io_h2c_data_bits_last         ;

wire       [31:0]    io_h2c_data_bits_tcrc           ;
wire       [10:0]    io_h2c_data_bits_tuser_qid      ;
wire       [2:0]     io_h2c_data_bits_tuser_port_id  ;
wire                 io_h2c_data_bits_tuser_err      ;
wire       [31:0]    io_h2c_data_bits_tuser_mdata    ;
wire       [5:0]     io_h2c_data_bits_tuser_mty      ;
wire                 io_h2c_data_bits_tuser_zero_byte;

//C2H read command
wire                  read_cmd_valid;
wire                  read_cmd_ready;
wire [63:0]           read_cmd_address;
wire [31:0]           read_cmd_length;

// H2C write command
reg                  write_cmd_valid = 0;
wire                 write_cmd_ready;
reg [63:0]           write_cmd_address = 0;
reg [31:0]           write_cmd_length = 0;  

// H2C read data
wire                  read_data_valid;
wire                  read_data_ready;
wire   [511:0]         read_data_data;
wire  [63:0]           read_data_keep;
wire                   read_data_last;
// C2H write data (unused)
wire                 write_data_valid;
wire                 write_data_ready;
wire [511:0]         write_data_data ;
wire [63:0]          write_data_keep ;
wire                 write_data_last ;  
//Back接口
reg                 back_ready = 1;
wire                back_valid;

//内部调试信号
wire hotloading_core_started   = test_hotloading_inst.hotloading.io_core_started;
wire [1:0] hotloading_state   = test_hotloading_inst.hotloading.state;
wire hotloading_wr_active     = test_hotloading_inst.hotloading.writing_active_reg;
wire [31:0] hotloading_bytes_rem     = test_hotloading_inst.hotloading.bytes_remaining;
wire [31:0] hotloading_data_rem      = test_hotloading_inst.hotloading.data_remaining;
wire cpu_running_debug = test_hotloading_inst.mini_core.core.dpath.cpu_running;
wire [31:0] pc = test_hotloading_inst.mini_core.core.dpath.pc;
wire imem_wr_en   = test_hotloading_inst.hotloading.io_imem_wr_en;
wire [31:0] imem_addr    = test_hotloading_inst.hotloading.io_imem_addr;
wire [31:0] imem_data_in = test_hotloading_inst.hotloading.io_imem_data_in;


//================================================================
// Interconnect Logic
//================================================================

//驱动tuser信号
assign io_h2c_data_bits_tcrc          = 32'h0;
assign io_h2c_data_bits_tuser_qid     = 11'h0;
assign io_h2c_data_bits_tuser_port_id = 3'h0;
assign io_h2c_data_bits_tuser_err     = 1'b0;
assign io_h2c_data_bits_tuser_mdata   = 32'h0;
assign io_h2c_data_bits_tuser_mty     = 6'h0;
assign io_h2c_data_bits_tuser_zero_byte = 1'b0;

//connect DUT to QDMA
assign io_h2c_cmd_ready      = read_cmd_ready;
assign read_cmd_valid       = io_h2c_cmd_valid;
assign read_cmd_address = io_h2c_cmd_bits_addr;       
assign read_cmd_length   = io_h2c_cmd_bits_len;

assign io_h2c_data_bits_data = read_data_data;
assign io_h2c_data_bits_last = read_data_last;
assign io_h2c_data_valid    = read_data_valid;
assign read_data_ready    = io_h2c_data_ready;

//未使用的写数据端口
assign write_data_valid = 1'b0;
assign write_data_data  = 512'h0;
assign write_data_keep  = 64'h0;
assign write_data_last  = 1'b0;

//================================================================
// Module Instantiation
//================================================================

// 实例化DMA
DMA #(
    .width(512),
    .READ_DELAY(10),
    .depth(16384)
) dma_inst (
    .clock(clock),
    .reset(reset),
    
    // DMA CMD streams
    .read_cmd_valid(read_cmd_valid),
    .read_cmd_ready(read_cmd_ready),
    .read_cmd_address(read_cmd_address),
    .read_cmd_length(read_cmd_length),
    
    .write_cmd_valid(write_cmd_valid),
    .write_cmd_ready(write_cmd_ready),
    .write_cmd_address(write_cmd_address),
    .write_cmd_length(write_cmd_length),
    
    // DMA Data streams
    .read_data_valid(read_data_valid),
    .read_data_ready(read_data_ready),
    .read_data_data(read_data_data),
    .read_data_keep(read_data_keep),
    .read_data_last(read_data_last),
    
    .write_data_valid(write_data_valid),
    .write_data_ready(write_data_ready),
    .write_data_data(write_data_data),
    .write_data_keep(write_data_keep),
    .write_data_last(write_data_last),
    
    .back_ready(back_ready),
    .back_valid(back_valid)
);

// Instantiate DUT (Device Under Test)
test_hotloading test_hotloading_inst(
    .*
);

//================================================================
//Clock, Monitors, and Waveform Dumping
//================================================================

// Clock Generator
always #5 clock = ~clock;


//-- Monitors for Debugging --//
// Monitor for H2C commands sent by the DUT
always @(posedge clock) begin
    if (read_cmd_valid && read_cmd_ready) begin
        $display("[%0t] H2C CMD SENT: addr=0x%h, len=0x%h",
                 $time, io_h2c_cmd_bits_addr, io_h2c_cmd_bits_len);
    end
end

// Monitor for CPU start signal
always @(posedge clock) begin
    if ($past(io_core_started) === 1'b1 && io_core_started === 1'b0) begin
        $display("[%0t] ========== RISC CPU STARTED! (Transition 1 -> 0) ==========", $time);
    end
end

//打印执行指令时的数据
//always @(posedge clock) begin
//    if (pc == 32'h80000B18) $display("[%0t] PC=0x80000B18 (addi a5,a5,2)", $time);
//    if (pc == 32'h80000B1C) $display("[%0t] PC=0x80000B1C (csrw 0x50,a5)", $time);
//    if (pc == 32'h80000B20) $display("[%0t] PC=0x80000B20 (j 80000b18)", $time);
//end
//================================================================
// Main Test Sequence
//================================================================

initial begin
    // 1. Initialization
    reset <= 1;
    io_has_event_wr = 0;
    #10000;
    reset <= 0;

    // Load recv program image into the simulated host memory.
    dma_inst.init_from_file("/home/lbx/core4nic/core/tb/output.txt");
    #10000;
    $display("[%0t] ========== Test Start ==========", $time);

    // Wait for the CPU to boot with inst_tx.mem (send program).
    repeat (2000) @(posedge clock);
    $display("[%0t] PHASE1 before loading: event_count=%0d (expect 0)",
             $time, $signed(io_event_count));

    // Inject one event -> send loop does event_count + 1.
    @(negedge clock);
    io_has_event_wr = 1'b1;
    @(negedge clock);
    io_has_event_wr = 1'b0;
    repeat (500) @(posedge clock);
    $display("[%0t] PHASE1 after send event: event_count=%0d (expect 1)",
             $time, $signed(io_event_count));

    // 2. Start the CPU RISC-V core loading process (load recv program).
    @(posedge clock);
    io_host_mem_addr  <= 64'h0;
    io_imem_base_addr <= 32'h8000_0000;
    io_mem_length     <= 32'd3456;
    @(posedge clock);
    io_loading_start <= 1'b1;
    @(posedge clock);
    io_loading_start <= 1'b0;
    $display("[%0t] PHASE2 loading started", $time);

    // 3. Wait for loading complete (io_core_started falls).
    fork
        begin
            @(negedge io_core_started);
        end
        begin
            #500000;
            $display("[%0t] Error: Timeout waiting for loading", $time);
            $finish;
        end
    join_any
    $display("[%0t] Loading complete, CPU now runs recv", $time);

    // Wait for recv loop to settle, then observe.
    repeat (500) @(posedge clock);
    $display("[%0t] PHASE3 after loading: event_count=%0d (expect 1)",
             $time, $signed(io_event_count));

    // Inject one event -> recv loop does event_count - 1.
    @(negedge clock);
    io_has_event_wr = 1'b1;
    @(negedge clock);
    io_has_event_wr = 1'b0;
    repeat (500) @(posedge clock);
    $display("[%0t] PHASE3 after recv event: event_count=%0d (expect 0)",
             $time, $signed(io_event_count));

    // 7. End simulation
    $display("[%0t] ========== Test finished. ==========", $time);
    $finish;
end

endmodule
