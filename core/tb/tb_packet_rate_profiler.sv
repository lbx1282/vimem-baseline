`timescale 1ns / 1ps

// Traditional (non-chunked) hot-loading benchmark.
// VERSION_A is initialized from inst_tx.mem. At window 500, VERSION changes
// to VERSION_B. RX_Meta freezes its XQueue, waits for the in-flight VERSION_A
// packet to complete at io.meta_out.fire, then Scala holds cpu_reset while the
// complete inst_rx.mem image replaces IMEM. New packets remain in the XQueue.
// Each 1 us C2H sample is: (packet_count_send, xqueue_residual_count).
module tb_packet_rate_profiler;
  localparam int WINDOWS = 1000;
  localparam int CYCLES_PER_WINDOW = 250;
  localparam int SAMPLES_PER_C2H_BEAT = 8;
  localparam int C2H_BEATS = WINDOWS / SAMPLES_PER_C2H_BEAT;
  localparam int IMAGE_WORDS = 864;
  localparam int IMAGE_BYTES = IMAGE_WORDS * 4;
  localparam int H2C_BEATS = IMAGE_BYTES / 64;
  localparam int PAYLOAD_BYTES = 1024;
  localparam int VERSION_SWITCH_WINDOW = 500;
  localparam logic [31:0] IMEM_BASE = 32'h8000_0000;
  localparam logic [63:0] IMAGE_HOST_ADDR = 64'h1000;
  localparam logic [63:0] RESULT_HOST_ADDR = 64'h2000;
  localparam logic [23:0] VERSION_A = 24'h000001;
  localparam logic [23:0] VERSION_B = 24'h000002;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic [23:0] io_version = VERSION_A;
  logic io_slicer_start = 1'b0;
  logic [15:0] io_slicer_payload_len = PAYLOAD_BYTES;
  logic [7:0] io_slicer_idle_cycle = 8'd5;

  wire io_core_started;
  wire [23:0] io_active_version;
  wire io_version_load_pending;
  wire io_version_load_busy;
  wire io_h2c_cmd_valid;
  wire [63:0] io_h2c_cmd_bits_addr;
  wire [31:0] io_h2c_cmd_bits_len;
  wire io_h2c_cmd_bits_sop;
  wire io_h2c_cmd_bits_eop;
  wire io_h2c_data_ready;
  logic io_h2c_data_valid = 1'b0;
  logic [511:0] io_h2c_data_bits_data = '0;
  logic io_h2c_data_bits_last = 1'b0;
  wire io_c2h_cmd_valid;
  wire [63:0] io_c2h_cmd_bits_addr;
  wire [31:0] io_c2h_cmd_bits_len;
  wire [10:0] io_c2h_cmd_bits_qid;
  wire io_c2h_data_valid;
  wire [511:0] io_c2h_data_bits_data;
  wire io_c2h_data_bits_last;
  wire [5:0] io_c2h_data_bits_mty;
  wire io_benchmark_busy;
  wire io_benchmark_done;
  wire [31:0] io_benchmark_samples;
  wire [31:0] io_payload_packets_checked;
  wire [31:0] io_payload_length_errors;
  wire [31:0] io_last_payload_bytes;
  wire io_meta_out_valid;
  wire [23:0] io_meta_out_bits_qpn;
  wire [31:0] io_event_recv_cnt;
  wire [31:0] io_event_processed_cnt;
  wire [31:0] io_meta_queue_count;
  wire io_imem_wr_en;
  wire [31:0] io_imem_addr;
  wire [31:0] io_imem_data_in;
  wire io_vrt_update_valid;
  wire io_vrt_update_ready;

  wire cpu_reset = io_core_started;
  wire [23:0] program_version =
    dut.rxMeta.rx_core.core.dpath.csr.program_version;
  wire [31:0] pc = dut.rxMeta.rx_core.core.dpath.pc;
  wire frontend_send_fire =
    dut.frontend_io_meta_out_valid && dut.frontend_io_meta_out_ready;

  logic [31:0] inst_rx_words [0:IMAGE_WORDS-1];
  logic [511:0] inst_rx_beats [0:H2C_BEATS-1];

  ChunkLoadSimTop dut (
    .clock(clock),
    .reset(reset),
    .io_core_started(io_core_started),
    .io_loading_start(1'b0),
    .io_host_mem_addr(IMAGE_HOST_ADDR),
    .io_imem_base_addr(IMEM_BASE),
    .io_mem_length(IMAGE_BYTES),
    .io_version(io_version),
    .io_auto_version_load(1'b1),
    .io_active_version(io_active_version),
    .io_version_load_pending(io_version_load_pending),
    .io_version_load_busy(io_version_load_busy),
    .io_page_idx(16'b0),
    .io_shadow_slot(16'b0),
    .io_vrt_update_enable(1'b0),
    .io_h2c_cmd_ready(1'b1),
    .io_h2c_cmd_valid(io_h2c_cmd_valid),
    .io_h2c_cmd_bits_addr(io_h2c_cmd_bits_addr),
    .io_h2c_cmd_bits_len(io_h2c_cmd_bits_len),
    .io_h2c_cmd_bits_sop(io_h2c_cmd_bits_sop),
    .io_h2c_cmd_bits_eop(io_h2c_cmd_bits_eop),
    .io_h2c_data_ready(io_h2c_data_ready),
    .io_h2c_data_valid(io_h2c_data_valid),
    .io_h2c_data_bits_data(io_h2c_data_bits_data),
    .io_h2c_data_bits_tcrc(32'b0),
    .io_h2c_data_bits_tuser_qid(11'b0),
    .io_h2c_data_bits_tuser_port_id(3'b0),
    .io_h2c_data_bits_tuser_err(1'b0),
    .io_h2c_data_bits_tuser_mdata(32'b0),
    .io_h2c_data_bits_tuser_mty(6'b0),
    .io_h2c_data_bits_tuser_zero_byte(1'b0),
    .io_h2c_data_bits_last(io_h2c_data_bits_last),
    .io_c2h_cmd_ready(1'b1),
    .io_c2h_cmd_valid(io_c2h_cmd_valid),
    .io_c2h_cmd_bits_addr(io_c2h_cmd_bits_addr),
    .io_c2h_cmd_bits_len(io_c2h_cmd_bits_len),
    .io_c2h_cmd_bits_qid(io_c2h_cmd_bits_qid),
    .io_c2h_data_ready(1'b1),
    .io_c2h_data_valid(io_c2h_data_valid),
    .io_c2h_data_bits_data(io_c2h_data_bits_data),
    .io_c2h_data_bits_last(io_c2h_data_bits_last),
    .io_c2h_data_bits_mty(io_c2h_data_bits_mty),
    .io_benchmark_host_addr(RESULT_HOST_ADDR),
    .io_benchmark_busy(io_benchmark_busy),
    .io_benchmark_done(io_benchmark_done),
    .io_benchmark_samples(io_benchmark_samples),
    .io_payload_packets_checked(io_payload_packets_checked),
    .io_payload_length_errors(io_payload_length_errors),
    .io_last_payload_bytes(io_last_payload_bytes),
    .io_packet_start(io_slicer_start),
    .io_packet_qpn(24'b0),
    .io_slicer_start(io_slicer_start),
    .io_slicer_payload_len(io_slicer_payload_len),
    .io_slicer_idle_cycle(io_slicer_idle_cycle),
    .io_rx_data_in_valid(1'b0),
    .io_rx_data_in_bits_data(512'b0),
    .io_rx_data_in_bits_keep(64'b0),
    .io_rx_data_in_bits_last(1'b0),
    .io_payload_out_ready(1'b1),
    .io_meta_out_ready(1'b1),
    .io_meta_out_valid(io_meta_out_valid),
    .io_meta_out_bits_qpn(io_meta_out_bits_qpn),
    .io_event_recv_cnt(io_event_recv_cnt),
    .io_event_processed_cnt(io_event_processed_cnt),
    .io_meta_queue_count(io_meta_queue_count),
    .io_imem_wr_en(io_imem_wr_en),
    .io_imem_addr(io_imem_addr),
    .io_imem_data_in(io_imem_data_in),
    .io_vrt_update_valid(io_vrt_update_valid),
    .io_vrt_update_ready(io_vrt_update_ready)
  );

  always #2 clock = ~clock;

  int unsigned expected_send [0:WINDOWS-1];
  int unsigned expected_residual [0:WINDOWS-1];
  int unsigned host_send [0:WINDOWS-1];
  int unsigned host_residual [0:WINDOWS-1];
  logic [23:0] requested_version_trace [0:WINDOWS-1];
  logic [23:0] active_version_trace [0:WINDOWS-1];
  logic [23:0] program_version_trace [0:WINDOWS-1];
  logic [31:0] pc_trace [0:WINDOWS-1];
  logic reset_trace [0:WINDOWS-1];

  int unsigned capture_cycle = 0;
  int unsigned total_send_count = 0;
  int unsigned total_processed_count = 0;
  int unsigned c2h_command_count = 0;
  int unsigned c2h_beat_count = 0;
  int unsigned h2c_command_count = 0;
  int unsigned imem_write_count = 0;
  int unsigned vrt_commit_count = 0;
  int unsigned cpu_reset_rise_count = 0;
  int unsigned max_queue_count = 0;
  logic version_switch_applied = 1'b0;
  logic old_version_fire_seen = 1'b0;
  logic version_b_meta_seen = 1'b0;
  logic queue_nonzero_during_load = 1'b0;
  logic cpu_reset_q = 1'b0;
  logic [23:0] last_meta_qpn = '0;

  task automatic send_h2c_beat(
    input logic [511:0] data,
    input logic last
  );
    @(negedge clock);
    io_h2c_data_bits_data = data;
    io_h2c_data_bits_last = last;
    io_h2c_data_valid = 1'b1;
    do @(posedge clock); while (!io_h2c_data_ready);
    @(negedge clock);
    io_h2c_data_valid = 1'b0;
    io_h2c_data_bits_last = 1'b0;
  endtask

  initial begin
    wait (!reset);
    wait (io_benchmark_samples == VERSION_SWITCH_WINDOW);
    @(negedge clock);
    io_version = VERSION_B;
    version_switch_applied = 1'b1;
    $display("[%0t] VERSION change A->B at window %0d", $time,
             VERSION_SWITCH_WINDOW);
  end

  initial begin
    wait (!reset);
    forever begin
      @(posedge clock);
      if (io_h2c_cmd_valid)
        for (int beat = 0; beat < H2C_BEATS; beat++)
          send_h2c_beat(inst_rx_beats[beat], beat == H2C_BEATS - 1);
    end
  end

  initial begin
    int inst_file;
    int sample_file;
    int trace_file;
    inst_file = $fopen("inst_tx.mem", "r");
    if (inst_file == 0)
      $fatal(1, "inst_tx.mem is missing from the Vivado simulation files");
    $fclose(inst_file);

    for (int i = 0; i < WINDOWS; i++) begin
      expected_send[i] = 0;
      expected_residual[i] = 0;
      host_send[i] = 0;
      host_residual[i] = 0;
      requested_version_trace[i] = '0;
      active_version_trace[i] = '0;
      program_version_trace[i] = '0;
      pc_trace[i] = '0;
      reset_trace[i] = 1'b0;
    end
    for (int i = 0; i < IMAGE_WORDS; i++)
      inst_rx_words[i] = 32'b0;
    $readmemh("inst_rx.mem", inst_rx_words);
    for (int beat = 0; beat < H2C_BEATS; beat++) begin
      inst_rx_beats[beat] = 512'b0;
      for (int lane = 0; lane < 16; lane++)
        inst_rx_beats[beat][lane*32 +: 32] =
          inst_rx_words[beat*16 + lane];
    end

    repeat (5) @(negedge clock);
    reset = 1'b0;
    wait (io_active_version == VERSION_A);
    repeat (3) @(negedge clock);
    if (cpu_reset !== 1'b0 || h2c_command_count != 0)
      $fatal(1, "VERSION_A initialization unexpectedly started a load");
    io_slicer_start = 1'b1;
    wait (io_benchmark_samples == WINDOWS);
    @(negedge clock);
    io_slicer_start = 1'b0;
    wait (io_benchmark_done);
    wait (io_active_version == VERSION_B && !io_version_load_pending &&
          !io_version_load_busy && !cpu_reset);
    wait (version_b_meta_seen);
    repeat (5) @(posedge clock);

    if (capture_cycle != WINDOWS * CYCLES_PER_WINDOW ||
        c2h_command_count != 1 || c2h_beat_count != C2H_BEATS)
      $fatal(1, "incomplete profiler: cycles=%0d commands=%0d beats=%0d",
             capture_cycle, c2h_command_count, c2h_beat_count);
    if (!version_switch_applied || !old_version_fire_seen ||
        cpu_reset_rise_count != 1)
      $fatal(1, "bad switch boundary: changed=%0d old_fire=%0d rises=%0d",
             version_switch_applied, old_version_fire_seen,
             cpu_reset_rise_count);
    if (h2c_command_count != 1 || imem_write_count != IMAGE_WORDS)
      $fatal(1, "full image load incomplete: commands=%0d writes=%0d",
             h2c_command_count, imem_write_count);
    if (vrt_commit_count != 0)
      $fatal(1, "traditional load must not commit VRT entries");
    if (!queue_nonzero_during_load || max_queue_count == 0)
      $fatal(1, "XQueue did not retain packets during cpu_reset");
    if (io_active_version !== VERSION_B || last_meta_qpn !== VERSION_B)
      $fatal(1, "VERSION_B did not run: active=%h last_qpn=%h",
             io_active_version, last_meta_qpn);
    if (total_send_count == 0 || total_processed_count == 0)
      $fatal(1, "no packets: send=%0d processed=%0d",
             total_send_count, total_processed_count);
    if (io_payload_packets_checked == 0 || io_payload_length_errors != 0 ||
        io_last_payload_bytes != PAYLOAD_BYTES)
      $fatal(1, "payload check failed: checked=%0d errors=%0d last=%0d",
             io_payload_packets_checked, io_payload_length_errors,
             io_last_payload_bytes);

    sample_file = $fopen("/home/lbx/baseline/results/packet_rate_samples.csv", "w");
    if (sample_file == 0)
      $fatal(1, "cannot create packet_rate_samples.csv");
    $fdisplay(sample_file,
      "window_start_us,packet_count_send,xqueue_residual_count");
    for (int i = 0; i < WINDOWS; i++)
      $fdisplay(sample_file, "%0d,%0d,%0d", i, host_send[i],
                host_residual[i]);
    $fclose(sample_file);

    trace_file = $fopen("/home/lbx/baseline/results/packet_rate_version_trace.csv", "w");
    if (trace_file == 0)
      $fatal(1, "cannot create packet_rate_version_trace.csv");
    $fdisplay(trace_file,
      "window_start_us,packet_count_send,xqueue_residual_count,requested_version,active_version,program_version,cpu_reset,pc");
    for (int i = 0; i < WINDOWS; i++)
      $fdisplay(trace_file, "%0d,%0d,%0d,%06x,%06x,%06x,%0d,%08x",
        i, host_send[i], host_residual[i], requested_version_trace[i],
        active_version_trace[i], program_version_trace[i], reset_trace[i],
        pc_trace[i]);
    $fclose(trace_file);

    $display("PASS: VERSION_A fire -> full inst_rx.mem load -> VERSION_B");
    $display("send=%0d processed=%0d max_xqueue=%0d H2C_words=%0d C2H_bytes=%0d",
             total_send_count, total_processed_count, max_queue_count,
             imem_write_count, WINDOWS * 8);
    $display("CSV=packet_rate_samples.csv TRACE=packet_rate_version_trace.csv");
    $finish;
  end

  initial begin
    repeat (800000) @(posedge clock);
    $display("TIMEOUT STATE: samples=%0d benchmark_busy=%0d done=%0d requested=%h active=%h pending=%0d load_busy=%0d cpu_reset=%0d old_fire=%0d h2c_cmd=%0d writes=%0d queue=%0d recv=%0d processed=%0d last_qpn=%h pc=%h",
      io_benchmark_samples, io_benchmark_busy, io_benchmark_done,
      io_version, io_active_version, io_version_load_pending,
      io_version_load_busy, cpu_reset, old_version_fire_seen,
      h2c_command_count, imem_write_count, io_meta_queue_count,
      io_event_recv_cnt, io_event_processed_cnt, last_meta_qpn, pc);
    $fatal(1, "traditional hot-loading/profiler simulation timeout");
  end

  always @(posedge clock) begin
    if (reset) begin
      cpu_reset_q <= 1'b0;
    end else begin
      cpu_reset_q <= cpu_reset;
      if (version_switch_applied && io_meta_out_valid &&
          io_meta_out_bits_qpn == VERSION_A)
        old_version_fire_seen = 1'b1;
      // The first reset release initializes the inst_tx.mem PC. Only count
      // loader reset edges after the VERSION switch request.
      if (version_switch_applied && cpu_reset && !cpu_reset_q) begin
        cpu_reset_rise_count++;
        if (!version_switch_applied || !old_version_fire_seen)
          $fatal(1, "cpu_reset rose before VERSION_A io.meta_out.fire");
      end

      if (io_h2c_cmd_valid) begin
        h2c_command_count++;
        if (!cpu_reset || h2c_command_count != 1 ||
            io_h2c_cmd_bits_addr !== IMAGE_HOST_ADDR ||
            io_h2c_cmd_bits_len !== IMAGE_BYTES ||
            !io_h2c_cmd_bits_sop || !io_h2c_cmd_bits_eop)
          $fatal(1, "bad H2C command %0d addr=%h len=%0d",
                 h2c_command_count, io_h2c_cmd_bits_addr,
                 io_h2c_cmd_bits_len);
      end
      if (io_imem_wr_en) begin
        if (!cpu_reset || imem_write_count >= IMAGE_WORDS ||
            io_imem_addr !== IMEM_BASE + imem_write_count*4 ||
            io_imem_data_in !== inst_rx_words[imem_write_count])
          $fatal(1,
            "bad IMEM word %0d addr=%h data=%h expected=%h reset=%0d",
            imem_write_count, io_imem_addr, io_imem_data_in,
            inst_rx_words[imem_write_count], cpu_reset);
        imem_write_count++;
      end
      if (io_vrt_update_valid && io_vrt_update_ready)
        vrt_commit_count++;
      if (cpu_reset && io_meta_queue_count != 0)
        queue_nonzero_during_load = 1'b1;
      if (io_meta_queue_count > max_queue_count)
        max_queue_count = io_meta_queue_count;

      if (io_meta_out_valid) begin
        total_processed_count++;
        last_meta_qpn = io_meta_out_bits_qpn;
        if (io_meta_out_bits_qpn == VERSION_B)
          version_b_meta_seen = 1'b1;
      end
      if (io_benchmark_busy &&
          capture_cycle < WINDOWS * CYCLES_PER_WINDOW) begin
        if (frontend_send_fire) begin
          expected_send[capture_cycle / CYCLES_PER_WINDOW]++;
          total_send_count++;
        end
        if ((capture_cycle % CYCLES_PER_WINDOW) ==
            CYCLES_PER_WINDOW - 1) begin
          expected_residual[capture_cycle / CYCLES_PER_WINDOW] =
            io_meta_queue_count;
          requested_version_trace[capture_cycle / CYCLES_PER_WINDOW] =
            io_version;
          active_version_trace[capture_cycle / CYCLES_PER_WINDOW] =
            io_active_version;
          program_version_trace[capture_cycle / CYCLES_PER_WINDOW] =
            program_version;
          reset_trace[capture_cycle / CYCLES_PER_WINDOW] = cpu_reset;
          pc_trace[capture_cycle / CYCLES_PER_WINDOW] = pc;
        end
        capture_cycle++;
      end

      if (io_c2h_cmd_valid) begin
        c2h_command_count++;
        if (io_c2h_cmd_bits_addr !== RESULT_HOST_ADDR ||
            io_c2h_cmd_bits_len !== WINDOWS * 8 ||
            io_c2h_cmd_bits_qid !== 0)
          $fatal(1, "bad C2H command addr=%h len=%0d qid=%0d",
                 io_c2h_cmd_bits_addr, io_c2h_cmd_bits_len,
                 io_c2h_cmd_bits_qid);
      end
      if (io_c2h_data_valid) begin
        if (c2h_beat_count >= C2H_BEATS ||
            io_c2h_data_bits_last !== (c2h_beat_count == C2H_BEATS-1) ||
            io_c2h_data_bits_mty !== 0)
          $fatal(1, "bad C2H framing at beat %0d", c2h_beat_count);
        for (int sample = 0; sample < SAMPLES_PER_C2H_BEAT; sample++) begin
          host_send[c2h_beat_count*SAMPLES_PER_C2H_BEAT + sample] =
            io_c2h_data_bits_data[(sample*2)*32 +: 32];
          host_residual[c2h_beat_count*SAMPLES_PER_C2H_BEAT + sample] =
            io_c2h_data_bits_data[(sample*2+1)*32 +: 32];
          if (host_send[c2h_beat_count*SAMPLES_PER_C2H_BEAT + sample] !==
                expected_send[c2h_beat_count*SAMPLES_PER_C2H_BEAT + sample] ||
              host_residual[c2h_beat_count*SAMPLES_PER_C2H_BEAT + sample] !==
                expected_residual[c2h_beat_count*SAMPLES_PER_C2H_BEAT + sample])
            $fatal(1,
              "window %0d mismatch: host=(%0d,%0d) expected=(%0d,%0d)",
              c2h_beat_count*SAMPLES_PER_C2H_BEAT + sample,
              host_send[c2h_beat_count*SAMPLES_PER_C2H_BEAT + sample],
              host_residual[c2h_beat_count*SAMPLES_PER_C2H_BEAT + sample],
              expected_send[c2h_beat_count*SAMPLES_PER_C2H_BEAT + sample],
              expected_residual[c2h_beat_count*SAMPLES_PER_C2H_BEAT + sample]);
        end
        c2h_beat_count++;
      end
    end
  end
endmodule
