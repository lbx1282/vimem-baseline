`include "vrt_config.vh"
`timescale 1ns / 1ps

module tb_hotloading_chunk;
  localparam logic [31:0] IMEM_BASE = `VRT_IMEM_BASE;
  localparam integer CHUNK_WORDS = `VRT_CHUNK_WORDS;
  localparam integer CHUNK_BYTES = CHUNK_WORDS * 4;
  // Runtime controls shared with tb_packet_rate_profiler. Scala accepts any
  // non-zero VERSION change and samples payload/idle controls per packet.
  localparam logic [23:0] VERSION_A = 24'h00_0001;
  localparam logic [23:0] VERSION_B = 24'h00_0002;
  localparam integer PAYLOAD_BYTES = 192;
  localparam integer IDLE_CYCLE = 2;

  localparam integer TEST_LOGICAL_PAGE = 17;

  localparam integer LOGICAL_BLOCKS = 19;
  localparam integer STORED_PARTS   = 20;
  localparam integer PART_WORDS = STORED_PARTS * CHUNK_WORDS;
  localparam integer COMMON_TAIL_WORDS = 2;
  localparam integer IMAGE_WORDS =
    LOGICAL_BLOCKS * CHUNK_WORDS + COMMON_TAIL_WORDS;

  localparam integer FIRST_FREE_SLOT =
    (IMAGE_WORDS + CHUNK_WORDS - 1) / CHUNK_WORDS; // 20

  // Use the same VRT layout as tb_packet_rate_profiler: VERSION_A maps the
  // TX part into its logical base slot and VERSION_B maps the RX part into the
  // first free physical slot after the complete base image.
  localparam integer SHADOW_SLOT_TX = TEST_LOGICAL_PAGE; // 17
  localparam integer SHADOW_SLOT_RX = FIRST_FREE_SLOT;   // 20

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic io_loading_start = 1'b0;
  logic [63:0] io_host_mem_addr = 64'h1000;
  logic [31:0] io_imem_base_addr = IMEM_BASE;
  logic [31:0] io_mem_length = CHUNK_BYTES;
  logic [23:0] io_version = '0;
  logic [15:0] io_page_idx = 16'd0;
  logic [15:0] io_shadow_slot = '0;
  logic io_vrt_update_enable = 1'b1;
  logic io_h2c_cmd_ready = 1'b1;
  logic io_h2c_data_valid = 1'b0;
  logic [511:0] io_h2c_data_bits_data = '0;
  wire [31:0] io_payload_packets_checked;
  wire [31:0] io_payload_length_errors;
  wire [31:0] io_last_payload_bytes;
  logic io_packet_start = 1'b0;
  logic [23:0] io_packet_qpn = '0;
  wire io_packet_busy;
  wire [31:0] io_packet_sent_count;
  logic io_slicer_start = 1'b0;
  logic [15:0] io_slicer_payload_len = PAYLOAD_BYTES;
  logic [7:0] io_slicer_idle_cycle = IDLE_CYCLE;
  logic io_rx_data_in_valid = 1'b0;
  logic [511:0] io_rx_data_in_bits_data = '0;
  logic [63:0] io_rx_data_in_bits_keep = '0;
  logic io_rx_data_in_bits_last = 1'b0;
  wire io_rx_data_in_ready;
  logic io_payload_out_ready = 1'b1;
  wire io_payload_out_valid;
  wire [511:0] io_payload_out_bits_data;
  wire [63:0] io_payload_out_bits_keep;
  wire io_payload_out_bits_last;
  logic io_meta_out_ready = 1'b1;
  wire io_meta_out_valid;
  wire [31:0] io_meta_out_bits_src_ipv4;
  wire [31:0] io_meta_out_bits_dst_ipv4;
  wire [15:0] io_meta_out_bits_src_port;
  wire [15:0] io_meta_out_bits_dst_port;
  wire [7:0] io_meta_out_bits_op_code;
  wire [23:0] io_meta_out_bits_qpn;

  wire io_core_started;
  wire io_h2c_cmd_valid;
  wire [63:0] io_h2c_cmd_bits_addr;
  wire [31:0] io_h2c_cmd_bits_len;
  wire io_h2c_cmd_bits_eop;
  wire io_h2c_cmd_bits_sop;
  wire io_h2c_cmd_bits_mrkr_req;
  wire io_h2c_cmd_bits_sdi;
  wire [10:0] io_h2c_cmd_bits_qid;
  wire io_h2c_cmd_bits_error;
  wire [7:0] io_h2c_cmd_bits_func;
  wire [15:0] io_h2c_cmd_bits_cidx;
  wire [2:0] io_h2c_cmd_bits_port_id;
  wire io_h2c_cmd_bits_no_dma;
  wire io_h2c_data_ready;
  logic [31:0] io_h2c_data_bits_tcrc = '0;
  logic [10:0] io_h2c_data_bits_tuser_qid = '0;
  logic [2:0] io_h2c_data_bits_tuser_port_id = '0;
  logic io_h2c_data_bits_tuser_err = 1'b0;
  logic [31:0] io_h2c_data_bits_tuser_mdata = '0;
  logic [5:0] io_h2c_data_bits_tuser_mty = '0;
  logic io_h2c_data_bits_tuser_zero_byte = 1'b0;
  logic io_h2c_data_bits_last = 1'b0;
  wire io_has_event_rd;
  wire [31:0] io_event_recv_cnt;
  wire [31:0] io_event_processed_cnt;
  wire [31:0] io_event_count;
  wire [31:0] io_meta_queue_count;
  wire [31:0] io_rdma_print_addr;
  wire [31:0] io_rdma_print_string_num;
  wire [31:0] io_rdma_print_string_len;
  wire [31:0] io_rdma_trap;
  wire io_vrt_hit;
  wire io_vrt_full;
  wire io_vrt_update_ready;
  wire io_vrt_update_valid;
  wire [23:0] io_vrt_update_version;
  wire [15:0] io_vrt_update_page_idx;
  wire [15:0] io_vrt_update_shadow_slot;
  wire [31:0] io_imem_addr;
  wire io_imem_wr_en;
  wire [31:0] io_imem_data_in;

  // These hierarchy probes exist because this top contains the full Tile.
  wire [31:0] pc = dut.rxMeta.rx_core.core.dpath.pc;
  wire [23:0] program_version = dut.rxMeta.rx_core.core.dpath.csr.program_version;
  wire fetch_req_valid = dut.rxMeta.rx_core.arb.ibram_io_req_valid;
  wire [31:0] fetch_logical_addr = dut.rxMeta.rx_core.arb.vrt_io_logical_addr;
  wire [31:0] fetch_physical_addr = dut.rxMeta.rx_core.arb.vrt_io_physical_addr;
  wire fetch_resp_valid = dut.rxMeta.rx_core.arb.ibram_io_resp_valid;
  wire [31:0] fetch_instruction = dut.rxMeta.rx_core.arb.ibram_io_resp_bits_data;
  // fe_reg is the instruction currently decoded/executed.  A request on the
  // fetch interface can be speculative and must not be treated as execution.
  wire [31:0] execute_pc = dut.rxMeta.rx_core.core.dpath.fe_reg_pc;
  wire [31:0] execute_instruction = dut.rxMeta.rx_core.core.dpath.fe_reg_inst;
  wire execute_stall = dut.rxMeta.rx_core.core.dpath.stall;
  wire cpu_reset = dut.rxMeta.rx_core.io_cpu_reset;

  logic [511:0] first_beat = '0;
  logic [511:0] second_beat = '0;
  logic [511:0] third_beat  = '0;
  logic [23:0] active_load_version = VERSION_A;
  integer active_load_slot = 0;
  integer write_count = 0;
  logic [CHUNK_WORDS-1:0] seen_offsets = '0;
  integer verified_fetch_count = 0;
  integer executed_changed_word_count = 0;
  logic vrt_committed = 1'b0;
  logic observe_fetches = 1'b0;
  integer processed_before = 0;

  logic fetch_req_valid_q = 1'b0;
  logic fetch_hit_q = 1'b0;
  logic [31:0] fetch_logical_q = '0;
  logic [31:0] fetch_physical_q = '0;
  logic [23:0] fetch_version_q = '0;

  integer offset;
  integer execute_offset;
  integer expected_slot;
  logic [31:0] expected_data;
  logic [31:0] expected_execute_data;
  integer active_part;
  integer active_logical_page;
  logic active_is_tx = 1'b1;
  integer total_imem_write_count = 0;
  integer h2c_command_count = 0;
  logic [31:0] parts_mem    [0:PART_WORDS-1];
  logic [31:0] rx_index_mem [0:LOGICAL_BLOCKS-1];
  logic [31:0] tx_index_mem [0:LOGICAL_BLOCKS-1];

  initial begin
    $display(
      "CONFIG: CHUNK_WORDS=%0d CHUNK_BYTES=%0d",
      CHUNK_WORDS,
      CHUNK_BYTES
    );
    if (CHUNK_WORDS != 45)
      $fatal(1, "expected CHUNK_WORDS=45, got %0d", CHUNK_WORDS);
  end

  initial begin
  $readmemh(
    "/home/lbx/core4nic/core/tb/inst_parts/parts.mem",
    parts_mem
  );

  $readmemh(
    "/home/lbx/core4nic/core/tb/inst_parts/inst_rx.index.mem",
    rx_index_mem
  );

  $readmemh(
    "/home/lbx/core4nic/core/tb/inst_parts/inst_tx.index.mem",
    tx_index_mem
  );
end

  // Match the packet-rate benchmark clock so both VRT paths are exercised
  // under the same 250 MHz cycle timing.
  always #2 clock = ~clock;

  // The DUT has a profiler port, but this test exercises hotloading only.
  ChunkLoadSimTop dut (
    .*,
    .io_auto_version_load(1'b0),
    .io_active_version(),
    .io_version_load_pending(),
    .io_version_load_busy(),
    .io_c2h_cmd_ready(1'b1),
    .io_c2h_cmd_valid(),
    .io_c2h_cmd_bits_addr(),
    .io_c2h_cmd_bits_qid(),
    .io_c2h_cmd_bits_error(),
    .io_c2h_cmd_bits_func(),
    .io_c2h_cmd_bits_port_id(),
    .io_c2h_cmd_bits_pfch_tag(),
    .io_c2h_cmd_bits_len(),
    .io_c2h_data_ready(1'b1),
    .io_c2h_data_valid(),
    .io_c2h_data_bits_data(),
    .io_c2h_data_bits_tcrc(),
    .io_c2h_data_bits_ctrl_marker(),
    .io_c2h_data_bits_ctrl_ecc(),
    .io_c2h_data_bits_ctrl_len(),
    .io_c2h_data_bits_ctrl_port_id(),
    .io_c2h_data_bits_ctrl_qid(),
    .io_c2h_data_bits_ctrl_has_cmpt(),
    .io_c2h_data_bits_last(),
    .io_c2h_data_bits_mty(),
    .io_benchmark_host_addr(64'h2000),
    .io_benchmark_busy(),
    .io_benchmark_done(),
    .io_benchmark_samples()
  );

  task automatic build_beats_from_parts(
    input logic is_tx,
    input integer logical_page
  );
    integer i;
    integer base;
    begin
      active_logical_page = logical_page;

      if (logical_page < 0 || logical_page >= LOGICAL_BLOCKS)
      $fatal(
          1,
          "logical page out of range: %0d",
          logical_page
      );

      if (is_tx)
        active_part = tx_index_mem[logical_page];
      else
        active_part = rx_index_mem[logical_page];
      
      if (active_part < 0 || active_part >= STORED_PARTS)
      $fatal(
          1,
          "physical part out of range: direction=%s page=%0d part=%0d",
          is_tx ? "TX" : "RX",
          logical_page,
          active_part
      );

      base = active_part * CHUNK_WORDS;

      first_beat  = '0;
      second_beat = '0;
      third_beat  = '0;

      // 前16条指令组成第一个512-bit beat
      for (i = 0; i < 16; i = i + 1)
        first_beat[32*i +: 32] = parts_mem[base + i];

      // word 16～31
      for (i = 0; i < 16; i = i + 1)
        second_beat[32*i +: 32] =
          parts_mem[base + 16 + i];

      // word 32～44，共13条
      for (i = 0; i < CHUNK_WORDS - 32; i = i + 1)
      third_beat[32*i +: 32] =
        parts_mem[base + 32 + i];

      $display(
        "LOAD PART: direction=%s logical_page=%0d physical_part=%0d",
        is_tx ? "TX" : "RX",
        logical_page,
        active_part
      );
    end
  endtask

  task automatic send_beat(
    input logic [511:0] beat,
    input logic         last
  );
    begin
      @(negedge clock);
      io_h2c_data_bits_data = beat;
      io_h2c_data_bits_last = last;
      io_h2c_data_valid = 1'b1;

      do begin
        @(posedge clock);
      end while (!io_h2c_data_ready);

      @(negedge clock);
      io_h2c_data_valid = 1'b0;
      io_h2c_data_bits_last = 1'b0;
    end
  endtask

  task automatic select_version(input logic [23:0] version);
    integer timeout;
    begin
      @(negedge clock);
      // io_version is the single VERSION control: it selects the committed
      // VRT entry and is also copied into the generated packet's QPN.
      io_version = version;
      io_packet_start = 1'b1;
      @(negedge clock);
      io_packet_start = 1'b0;
      timeout = 0;
      while (program_version !== version) begin
        @(posedge clock);
        timeout = timeout + 1;
        if (timeout > 1000)
          $fatal(1, "CSR program_version timeout: expected=%h actual=%h", version, program_version);
      end
      $display("[%0t] CSR VERSION SWITCH: qpn=%h program_version=%h recv_cnt=%0d",
               $time, version, program_version, io_event_recv_cnt);
    end
  endtask

  // The packet source must honor the runtime idle-cycle control.
  integer source_gap_remaining = -1;
  integer source_gap_expected = 0;
  always @(posedge clock) begin
    if (reset) begin
      source_gap_remaining = -1;
    end else begin
      if (source_gap_remaining > 0) begin
        if (dut.packetSource_io_out_valid)
          $fatal(1, "packet source idle gap shorter than %0d cycles",
                 source_gap_expected);
        source_gap_remaining = source_gap_remaining - 1;
      end else if (source_gap_remaining == 0) begin
        if (!dut.packetSource_io_out_valid)
          $fatal(1, "packet source idle gap longer than %0d cycles",
                 source_gap_expected);
        source_gap_remaining = -1;
      end
      if (dut.packetSource_io_out_valid &&
          dut.packetSource_io_out_ready &&
          dut.packetSource_io_out_bits_last && io_packet_start) begin
        source_gap_expected = io_slicer_idle_cycle;
        source_gap_remaining = io_slicer_idle_cycle;
      end
    end
  end

  integer payload_packet_count = 0;
  integer payload_beat_count = 0;
  integer payload_expected_beats;
  integer payload_last_bytes;
  logic [63:0] payload_expected_keep;
  integer meta_count = 0;
  integer tx_packet_boundary = 32'h7fff_ffff;
  always @(posedge clock) begin
    if (!reset && io_payload_out_valid && io_payload_out_ready) begin
      payload_expected_beats = (io_slicer_payload_len + 63) / 64;
      payload_last_bytes = io_slicer_payload_len -
                           (payload_expected_beats - 1) * 64;
      payload_expected_keep =
        (payload_last_bytes == 64) ? 64'hffff_ffff_ffff_ffff :
        ((64'h1 << payload_last_bytes) - 1);
      if (io_payload_out_bits_keep !==
            ((payload_beat_count == payload_expected_beats - 1) ?
              payload_expected_keep : 64'hffff_ffff_ffff_ffff) ||
          io_payload_out_bits_last !==
            (payload_beat_count == payload_expected_beats - 1))
        $fatal(1, "payload beat framing mismatch: beat=%0d keep=%h last=%b",
               payload_beat_count, io_payload_out_bits_keep, io_payload_out_bits_last);
      payload_beat_count = payload_beat_count + 1;
      if (io_payload_out_bits_last) begin
        payload_beat_count = 0;
        payload_packet_count = payload_packet_count + 1;
      end
    end
    if (!reset && io_meta_out_valid && io_meta_out_ready) begin
      if (io_meta_out_bits_src_ipv4 !== 32'hc0a80101 ||
          io_meta_out_bits_dst_ipv4 !== 32'hc0a80102 ||
          io_meta_out_bits_src_port !== 16'd4791 ||
          io_meta_out_bits_dst_port !== 16'd4791 ||
          io_meta_out_bits_op_code !== 8'h0a ||
          io_meta_out_bits_qpn !== (meta_count < tx_packet_boundary ? VERSION_A : VERSION_B))
        $fatal(1, "RX_Meta output mismatch: index=%0d opcode=%h qpn=%h",
               meta_count, io_meta_out_bits_op_code, io_meta_out_bits_qpn);
      meta_count = meta_count + 1;
    end
  end

  task automatic load_version_from_parts(
    input logic [23:0] version,
    input logic        is_tx,
    input integer      logical_page,
    input integer      load_slot
  );
    integer timeout;
    begin
      active_load_version = version;
      active_logical_page = logical_page;
      active_is_tx = is_tx;
      processed_before = io_event_processed_cnt;

      // 从 index mem 查 physical part，并从 parts.mem 构造3个 beat
      build_beats_from_parts(is_tx, logical_page);

      active_load_slot = load_slot;

      write_count = 0;
      seen_offsets = '0;
      verified_fetch_count = 0;
      executed_changed_word_count = 0;
      vrt_committed = 1'b0;
      observe_fetches = 1'b0;

      io_version = version;
      io_page_idx = logical_page[15:0];
      io_shadow_slot = active_load_slot[15:0];
      io_host_mem_addr =
        64'h1000 + active_part * CHUNK_BYTES;
      io_mem_length = CHUNK_BYTES;

      if (cpu_reset !== 1'b0)
        $fatal(1, "CPU reset must be idle before VERSION %h load request", version);

      // TB only pulses the load request. Scala must pull and release cpu_reset.
      @(negedge clock);
      io_loading_start = 1'b1;

      @(negedge clock);
      if (!io_core_started || cpu_reset !== 1'b1)
        $fatal(1, "Scala did not assert CPU reset for VERSION %h load", version);
      io_loading_start = 1'b0;

      // 等待 H2C command
      while (!io_h2c_cmd_valid)
        @(posedge clock);

      if (
        io_h2c_cmd_bits_addr !== io_host_mem_addr ||
        io_h2c_cmd_bits_len !== CHUNK_BYTES ||
        !io_h2c_cmd_bits_sop ||
        !io_h2c_cmd_bits_eop
      )
        $fatal(
          1,
          "H2C command mismatch: version=%h page=%0d part=%0d",
          version,
          logical_page,
          active_part
        );

      // 将 parts.mem 中选中的45条指令送给 hotloading
      send_beat(first_beat, 1'b0);
      send_beat(second_beat, 1'b0);
      send_beat(third_beat, 1'b1);

      // 等待 VRT 原子提交
      timeout = 0;

      while (!(io_vrt_update_valid &&
              io_vrt_update_ready)) begin
        @(posedge clock);

        timeout = timeout + 1;

        if (timeout > 200)
          $fatal(
            1,
            "VRT commit timeout: writes=%0d core_reset=%b h2c_ready=%b vrt_valid=%b vrt_ready=%b vrt_full=%b",
            write_count,
            io_core_started,
            io_h2c_data_ready,
            io_vrt_update_valid,
            io_vrt_update_ready,
            io_vrt_full
          );
      end

      @(posedge clock);

      // 等待 loader 撤销其复位请求
      while (io_core_started)
        @(posedge clock);

      if (cpu_reset !== 1'b0)
        $fatal(1, "Scala did not release CPU reset after VERSION %h commit", version);

      @(posedge clock);

      observe_fetches = 1'b1;

      $display(
        "[%0t] VERSION %h COMMITTED: direction=%s page=%0d source_part=%0d shadow_slot=%0d",
        $time,
        version,
        is_tx ? "TX" : "RX",
        logical_page,
        active_part,
        active_load_slot
      );
    end
  endtask

  always @(posedge clock) begin
    if (io_h2c_cmd_valid && io_h2c_cmd_ready)
      h2c_command_count = h2c_command_count + 1;

    // 检查45条指令是否按顺序写入正确的物理part
  if (io_imem_wr_en) begin
    if (!io_core_started || cpu_reset !== 1'b1)
      $fatal(1, "Scala CPU reset missing during IMEM write %0d", write_count);

    if (write_count >= CHUNK_WORDS)
      $fatal(
        1,
        "too many IMEM writes: count=%0d",
        write_count
      );

    if (
      io_imem_addr !==
      IMEM_BASE +
      active_load_slot * CHUNK_BYTES +
      write_count * 4
    )
      $fatal(
        1,
        "write address mismatch: part=%0d word=%0d got=%h expected=%h",
        active_load_slot,
        write_count,
        io_imem_addr,
        IMEM_BASE +
        active_load_slot * CHUNK_BYTES +
        write_count * 4
      );

    if (
      io_imem_data_in !==
      parts_mem[
        active_part * CHUNK_WORDS +
        write_count
      ]
    )
      $fatal(
        1,
        "write data mismatch: source_part=%0d shadow_slot=%0d word=%0d got=%h expected=%h",
        active_part,
        active_load_slot,
        write_count,
        io_imem_data_in,
        parts_mem[
          active_part * CHUNK_WORDS +
          write_count
        ]
      );

      write_count = write_count + 1;
      total_imem_write_count = total_imem_write_count + 1;
    end

    // fe_reg holds through a stall and can contain a killed NOP.  Only a
    // running, non-stalled, non-NOP instruction counts as executed here.
    if (
      observe_fetches &&
      !cpu_reset &&
      !execute_stall &&
      execute_instruction != 32'h00000013 &&
      program_version == active_load_version &&
      execute_pc >= IMEM_BASE + active_logical_page * CHUNK_BYTES &&
      execute_pc < IMEM_BASE + (active_logical_page + 1) * CHUNK_BYTES
    ) begin
      execute_offset =
        (execute_pc - IMEM_BASE - active_logical_page * CHUNK_BYTES) >> 2;
      expected_execute_data =
        parts_mem[active_part * CHUNK_WORDS + execute_offset];

      if (execute_instruction !== expected_execute_data)
        $fatal(
          1,
          "executed wrong version: version=%h pc=%h offset=%0d got=%h expected=%h",
          program_version,
          execute_pc,
          execute_offset,
          execute_instruction,
          expected_execute_data
        );

      if (
        parts_mem[tx_index_mem[active_logical_page] * CHUNK_WORDS + execute_offset] !==
        parts_mem[rx_index_mem[active_logical_page] * CHUNK_WORDS + execute_offset]
      ) begin
        executed_changed_word_count = executed_changed_word_count + 1;
        $display(
          "[%0t] EXECUTED VERSION DIFFERENCE: direction=%s version=%h pc=%h offset=%0d instruction=%h",
          $time,
          active_is_tx ? "TX" : "RX",
          program_version,
          execute_pc,
          execute_offset,
          execute_instruction
        );
      end
    end

  // 检查VRT提交内容
  if (io_vrt_update_valid && io_vrt_update_ready) begin
    if (!io_core_started || cpu_reset !== 1'b1)
      $fatal(1, "Scala CPU reset missing during VRT commit");

    if (write_count != CHUNK_WORDS)
      $fatal(
        1,
        "VRT committed after only %0d/%0d writes",
        write_count,
        CHUNK_WORDS
      );

    if (
      io_vrt_update_version !== active_load_version ||
      io_vrt_update_page_idx !==
        active_logical_page[15:0] ||
      io_vrt_update_shadow_slot !==
        active_load_slot[15:0]
    )
      $fatal(
        1,
        "VRT mismatch: got version=%h page=%0d slot=%0d; expected version=%h page=%0d slot=%0d",
        io_vrt_update_version,
        io_vrt_update_page_idx,
        io_vrt_update_shadow_slot,
        active_load_version,
        active_logical_page,
        active_load_slot
      );

    vrt_committed = 1'b1;
  end

  // 保存本周期取指请求，用于和下一周期BRAM响应对齐
  fetch_req_valid_q <= fetch_req_valid;

  if (fetch_req_valid) begin
    fetch_hit_q <= io_vrt_hit;
    fetch_logical_q <= fetch_logical_addr;
    fetch_physical_q <= fetch_physical_addr;
    fetch_version_q <= program_version;

    if (
      observe_fetches &&
      !active_is_tx &&
      program_version == active_load_version &&
      fetch_logical_addr >= IMEM_BASE + active_logical_page * CHUNK_BYTES &&
      fetch_logical_addr < IMEM_BASE + (active_logical_page + 1) * CHUNK_BYTES &&
      !io_vrt_hit
    )
      $fatal(
        1,
        "VRT miss after commit: version=%h logical=%h page=%0d",
        program_version,
        fetch_logical_addr,
        active_logical_page
      );
  end

  // 检查CPU实际取到的page 17指令
  if (
    fetch_resp_valid &&
    fetch_req_valid_q &&
    fetch_hit_q &&
    observe_fetches &&
    fetch_version_q == active_load_version &&
    fetch_logical_q >=
      IMEM_BASE +
      active_logical_page * CHUNK_BYTES &&
    fetch_logical_q <
      IMEM_BASE +
      (active_logical_page + 1) * CHUNK_BYTES
  ) begin
    offset =
      (
        fetch_logical_q -
        (
          IMEM_BASE +
          active_logical_page * CHUNK_BYTES
        )
      ) >> 2;

    expected_slot = active_load_slot;

    expected_data =
      parts_mem[
        active_part * CHUNK_WORDS +
        offset
      ];

    if (
      fetch_physical_q !==
      IMEM_BASE +
      active_load_slot * CHUNK_BYTES +
      offset * 4
    )
      $fatal(
        1,
        "VRT address mismatch: version=%h logical=%h physical=%h expected=%h offset=%0d",
        fetch_version_q,
        fetch_logical_q,
        fetch_physical_q,
        IMEM_BASE +
        expected_slot * CHUNK_BYTES +
        offset * 4,
        offset
      );

    if (fetch_instruction !== expected_data)
      $fatal(
        1,
        "instruction mismatch: version=%h logical=%h got=%h expected=%h offset=%0d",
        fetch_version_q,
        fetch_logical_q,
        fetch_instruction,
        expected_data,
        offset
      );

    if (!seen_offsets[offset]) begin
      seen_offsets[offset] = 1'b1;
      verified_fetch_count =
        verified_fetch_count + 1;

      $display(
        "[%0t] FETCH PASS: direction=%s version=%h logical=%h physical=%h instruction=%h offset=%0d event_count=%0d",
        $time,
        active_is_tx ? "TX" : "RX",
        fetch_version_q,
        fetch_logical_q,
        fetch_physical_q,
        fetch_instruction,
        offset,
        io_event_count
      );
    end
  end
end

  task automatic wait_for_version_fetch(
    input logic [23:0] version
    );
    integer timeout;
    begin
      timeout = 0;

      while (
        verified_fetch_count == 0 ||
        executed_changed_word_count == 0 ||
        io_event_processed_cnt == processed_before
      ) begin
        @(posedge clock);
        timeout = timeout + 1;

        if (timeout > 5000)
          $fatal(
            1,
            "timeout waiting for execution: direction=%s version=%h page=%0d pc=%h program_version=%h fetched=%0d executed_changed=%0d processed_before=%0d processed_now=%0d",
            active_is_tx ? "TX" : "RX",
            version,
            active_logical_page,
            pc,
            program_version,
            verified_fetch_count,
            executed_changed_word_count,
            processed_before,
            io_event_processed_cnt
          );
      end

      if (program_version !== version)
        $fatal(
          1,
          "program version changed unexpectedly: expected=%h actual=%h",
          version,
          program_version
        );

      $display(
        "[%0t] VERSION EXECUTION PASS: direction=%s version=%h page=%0d slot=%0d verified_offsets=%h executed_changed=%0d processed=%0d event_count=%0d",
        $time,
        active_is_tx ? "TX" : "RX",
        version,
        active_logical_page,
        active_load_slot,
        seen_offsets,
        executed_changed_word_count,
        io_event_processed_cnt,
        io_event_count
      );
    end
  endtask

  initial begin
    integer timeout;
    integer expected_packets;
    integer drain_timeout;

    // Present the initial valid VERSION before releasing module reset. Scala
    // holds cpu_reset until it has latched this initial program version.
    io_version = VERSION_A;
    // Release reset away from the active clock edge to avoid a TB/DUT race.
    repeat (5) @(negedge clock);
    reset = 1'b0;
    wait (cpu_reset === 1'b0);

    if (cpu_reset !== 1'b0)
      $fatal(1, "Scala CPU reset must be idle before VERSION_A request");

    // Phase 1 uses the same cmd+data+VRT path as the packet-rate benchmark.
    load_version_from_parts(
      VERSION_A,
      1'b1,
      TEST_LOGICAL_PAGE,
      SHADOW_SLOT_TX
    );

    if (h2c_command_count != 1 ||
        total_imem_write_count != CHUNK_WORDS || !vrt_committed)
      $fatal(1,
        "VERSION_A load mismatch: commands=%0d writes=%0d committed=%b",
        h2c_command_count, total_imem_write_count, vrt_committed);

    select_version(VERSION_A);

    timeout = 0;
    while (executed_changed_word_count == 0 ||
           io_event_processed_cnt == processed_before) begin
      @(posedge clock);
      timeout = timeout + 1;
      if (timeout > 5000)
        $fatal(
          1,
          "timeout waiting for one TX execution: pc=%h changed_words=%0d processed_before=%0d processed_now=%0d",
          pc,
          executed_changed_word_count,
          processed_before,
          io_event_processed_cnt
        );
    end

    if (io_event_processed_cnt !== processed_before + 1)
      $fatal(
        1,
        "TX processed count did not advance exactly once: before=%0d now=%0d",
        processed_before,
        io_event_processed_cnt
      );

    $display(
      "[%0t] TX ONCE PASS: version=%h changed_words=%0d processed=%0d",
      $time,
      VERSION_A,
      executed_changed_word_count,
      io_event_processed_cnt
    );

    // TX send loop: keep start asserted for a bounded time, then drain the
    // packets already accepted by the generator and the RISC-V event path.
    @(negedge clock);
    io_packet_start = 1'b1;
    repeat (800) @(posedge clock);
    @(negedge clock);
    io_packet_start = 1'b0;
    drain_timeout = 0;
    while (io_packet_busy) begin
      @(posedge clock);
      drain_timeout = drain_timeout + 1;
      if (drain_timeout > 10000)
        $fatal(1, "continuous TX packet source did not stop");
    end
    expected_packets = io_packet_sent_count;
    if (expected_packets <= 1)
      $fatal(1, "continuous TX phase sent no additional packets");
    drain_timeout = 0;
    while (payload_packet_count < expected_packets ||
           meta_count < expected_packets ||
           io_event_recv_cnt < expected_packets ||
           io_event_processed_cnt < expected_packets) begin
      @(posedge clock);
      drain_timeout = drain_timeout + 1;
      if (drain_timeout > 30000)
        $fatal(1, "TX drain timeout: sent=%0d payload=%0d meta=%0d recv=%0d processed=%0d event_count=%0d",
               expected_packets, payload_packet_count, meta_count,
               io_event_recv_cnt, io_event_processed_cnt, io_event_count);
    end
    repeat (4) @(posedge clock);
    if (payload_packet_count != expected_packets ||
        meta_count != expected_packets ||
        io_event_recv_cnt != expected_packets ||
        io_event_processed_cnt != expected_packets ||
        io_event_count != expected_packets)
      $fatal(1, "TX counts disagree: sent=%0d payload=%0d meta=%0d recv=%0d processed=%0d event_count=%0d",
             expected_packets, payload_packet_count, meta_count,
             io_event_recv_cnt, io_event_processed_cnt, io_event_count);
    tx_packet_boundary = expected_packets;
    $display("CONTINUOUS_TX_PASS sent=%0d event_count=%0d",
             expected_packets, io_event_count);

    // The traffic is drained at a clean boundary. Scala owns reset while the
    // replacement page is written and its VRT entry is committed.
    observe_fetches = 1'b0;

    // Phase 2: the same loader path writes the RX page and commits VERSION_B.
    load_version_from_parts(
      VERSION_B,
      1'b0,
      TEST_LOGICAL_PAGE,
      SHADOW_SLOT_RX
    );

    if (program_version !== VERSION_A)
      $fatal(
        1,
        "loader changed running version unexpectedly: expected=%h actual=%h",
        VERSION_A,
        program_version
      );

    if (h2c_command_count != 2 ||
        total_imem_write_count != 2 * CHUNK_WORDS)
      $fatal(
        1,
        "expected TX+RX block loads: commands=%0d writes=%0d expected_writes=%0d",
        h2c_command_count,
        total_imem_write_count,
        2 * CHUNK_WORDS
      );

    if (!vrt_committed || io_core_started)
      $fatal(
        1,
        "cannot switch version before VRT commit and loader release: committed=%b loader_reset=%b",
        vrt_committed,
        io_core_started
      );

    select_version(VERSION_B);
    $display(
      "[%0t] SAFE VERSION SWITCH: committed=%b version=%h page=%0d slot=%0d",
      $time,
      vrt_committed,
      VERSION_B,
      TEST_LOGICAL_PAGE,
      active_load_slot
    );

    wait_for_version_fetch(VERSION_B);

    if (io_event_processed_cnt !== processed_before + 1)
      $fatal(
        1,
        "RX processed count did not advance exactly once: before=%0d now=%0d",
        processed_before,
        io_event_processed_cnt
      );

    if (io_event_recv_cnt !== tx_packet_boundary + 1)
      $fatal(1, "RX version event count mismatch: tx=%0d recv=%0d",
             tx_packet_boundary, io_event_recv_cnt);

    if (h2c_command_count != 2 ||
        total_imem_write_count != 2 * CHUNK_WORDS)
      $fatal(
        1,
        "load repeated during version switch: commands=%0d writes=%0d",
        h2c_command_count,
        total_imem_write_count
      );

    // Hold start high for a bounded interval, like the slicer traffic test.
    // The generator finishes any packet already in flight after start drops.
    @(negedge clock);
    io_packet_start = 1'b1;
    repeat (800) @(posedge clock);
    @(negedge clock);
    io_packet_start = 1'b0;

    drain_timeout = 0;
    while (io_packet_busy) begin
      @(posedge clock);
      drain_timeout = drain_timeout + 1;
      if (drain_timeout > 10000)
        $fatal(1, "continuous packet source did not stop");
    end
    expected_packets = io_packet_sent_count;
    if (expected_packets <= tx_packet_boundary + 1)
      $fatal(1, "continuous RX phase sent no additional packets: sent=%0d", expected_packets);

    drain_timeout = 0;
    while (payload_packet_count < expected_packets ||
           meta_count < expected_packets ||
           io_event_recv_cnt < expected_packets ||
           io_event_processed_cnt < expected_packets) begin
      @(posedge clock);
      drain_timeout = drain_timeout + 1;
      if (drain_timeout > 30000)
        $fatal(1, "packet drain timeout: sent=%0d payload=%0d meta=%0d recv=%0d processed=%0d event_count=%0d",
               expected_packets, payload_packet_count, meta_count,
               io_event_recv_cnt, io_event_processed_cnt, io_event_count);
    end
    repeat (4) @(posedge clock);
    if (payload_packet_count != expected_packets ||
        meta_count != expected_packets ||
        io_event_recv_cnt != expected_packets ||
        io_event_processed_cnt != expected_packets)
      $fatal(1, "packet counts disagree: sent=%0d payload=%0d meta=%0d recv=%0d processed=%0d",
             expected_packets, payload_packet_count, meta_count,
             io_event_recv_cnt, io_event_processed_cnt);
    if (io_payload_packets_checked != expected_packets ||
        io_payload_length_errors != 0 ||
        io_last_payload_bytes != PAYLOAD_BYTES)
      $fatal(1, "payload length check failed: checked=%0d errors=%0d last=%0d",
             io_payload_packets_checked, io_payload_length_errors,
             io_last_payload_bytes);
    $display("CONTINUOUS_PACKET_PASS sent=%0d payload=%0d meta=%0d processed=%0d event_count=%0d",
             expected_packets, payload_packet_count, meta_count,
             io_event_processed_cnt, io_event_count);
    $display(
      "HOTLOADING_MATCHED_VRT_VERSION_EXECUTION_TEST_PASS commands=%0d writes=%0d",
      h2c_command_count,
      total_imem_write_count
    );

    // Change payload length through the TB port and verify the next generated
    // packet uses the new value; this is no longer a mismatch-only probe.
    @(negedge clock);
    io_slicer_payload_len = 16'd128;
    io_packet_start = 1'b1;
    @(negedge clock);
    io_packet_start = 1'b0;
    drain_timeout = 0;
    while (io_payload_packets_checked < expected_packets + 1) begin
      @(posedge clock);
      drain_timeout = drain_timeout + 1;
      if (drain_timeout > 10000)
        $fatal(1, "payload mismatch probe did not complete");
    end
    repeat (2) @(posedge clock);
    if (io_payload_length_errors != 0 || io_last_payload_bytes != 128)
      $fatal(1, "runtime payload length was not applied: errors=%0d last=%0d",
             io_payload_length_errors, io_last_payload_bytes);
    $display("RUNTIME_PAYLOAD_LENGTH_PASS expected=128 actual=%0d errors=%0d",
             io_last_payload_bytes,
             io_payload_length_errors);

    $finish;
  end

endmodule
