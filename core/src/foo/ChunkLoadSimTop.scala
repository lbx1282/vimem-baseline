package mini.foo

import chisel3._
import chisel3.util._
import common.axi.AXIS
import generator.{HeadProcessMeta, SlicerFrontend}
import qdma._
import mini.core._

/** Passive packet/queue observation; never backpressures the packet path.
  * Each 1 us window produces two little-endian 32-bit words:
  * processed packets and {12'h515, window_index[9:0], queue_max[9:0]}.
  * Eight records occupy one 512-bit beat. The queue point is the maximum
  * occupancy sampled on every clock edge in the window, not its last value.
  * The board uses 200 cycles/us; the 250 MHz simulation harness overrides it.
  */
class PacketRateProfiler(cyclesPerUs: Int = 200, samples: Int = 1000)
    extends Module {
  require(cyclesPerUs > 0)
  require(samples > 0)
  require(samples <= 1024)

  private val countBits = 32
  private val recordBits = 2 * countBits
  private val countsPerBeat = 512 / recordBits
  private val beats = (samples + countsPerBeat - 1) / countsPerBeat
  private val resultBytes = samples * recordBits / 8
  private val lastMty = (beats * 64) - resultBytes

  val io = IO(new Bundle {
    val start = Input(Bool())
    val processed = Input(Bool())
    val residual_count = Input(UInt(10.W))
    val host_addr = Input(UInt(64.W))
    val busy = Output(Bool())
    val done = Output(Bool())
    val samples_captured = Output(UInt(32.W))
    val c2h_cmd = Decoupled(new C2H_CMD)
    val c2h_data = Decoupled(new C2H_DATA)
  })

  val sIdle :: sCollect :: sCommand :: sData :: sDone :: Nil = Enum(5)
  val state = RegInit(sIdle)
  val startPrev = RegNext(io.start, false.B)
  val startPulse = io.start && !startPrev
  val hostAddr = Reg(UInt(64.W))
  val cycleInWindow = RegInit(0.U(log2Ceil(cyclesPerUs max 2).W))
  val windowIndex = RegInit(0.U(log2Ceil(samples + 1).W))
  val packetCount = RegInit(0.U(countBits.W))
  val queuePeak = RegInit(0.U(10.W))
  val packed = RegInit(VecInit(Seq.fill(countsPerBeat)(0.U(recordBits.W))))
  val beatIndex = RegInit(0.U(log2Ceil((beats + 1) max 2).W))
  val resultFifo = Module(new Queue(UInt(512.W), beats))

  val peakIncludingCurrent = Mux(io.residual_count > queuePeak,
    io.residual_count, queuePeak)
  val nextPacked = Wire(Vec(countsPerBeat, UInt(recordBits.W)))
  nextPacked := packed
  nextPacked(windowIndex(log2Ceil(countsPerBeat) - 1, 0)) :=
    Cat("h515".U(12.W), windowIndex.pad(10)(9, 0), peakIncludingCurrent,
      packetCount + io.processed.asUInt)
  val endWindow = state === sCollect && cycleInWindow === (cyclesPerUs - 1).U
  val endGroup = windowIndex(log2Ceil(countsPerBeat) - 1, 0) ===
    (countsPerBeat - 1).U || windowIndex === (samples - 1).U

  resultFifo.io.enq.valid := endWindow && endGroup
  resultFifo.io.enq.bits := nextPacked.asUInt
  resultFifo.io.deq.ready := state === sData && io.c2h_data.ready
  when(resultFifo.io.enq.valid) {
    assert(resultFifo.io.enq.ready, "packet-rate result FIFO overflow")
  }

  io.busy := state =/= sIdle && state =/= sDone
  io.done := state === sDone
  io.samples_captured := windowIndex
  io.c2h_cmd.valid := state === sCommand
  io.c2h_cmd.bits := 0.U.asTypeOf(new C2H_CMD)
  io.c2h_cmd.bits.addr := hostAddr
  io.c2h_cmd.bits.len := resultBytes.U
  io.c2h_cmd.bits.qid := 0.U

  io.c2h_data.valid := state === sData && resultFifo.io.deq.valid
  io.c2h_data.bits := 0.U.asTypeOf(new C2H_DATA)
  io.c2h_data.bits.data := resultFifo.io.deq.bits
  io.c2h_data.bits.ctrl_len := resultBytes.U
  io.c2h_data.bits.ctrl_qid := 0.U
  // QDMA.scala does not expose a C2H completion stream.
  io.c2h_data.bits.ctrl_has_cmpt := false.B
  io.c2h_data.bits.last := beatIndex === (beats - 1).U
  io.c2h_data.bits.mty := Mux(io.c2h_data.bits.last, lastMty.U, 0.U)

  switch(state) {
    is(sIdle) {
      when(startPulse) {
        assert(io.host_addr(11, 0) === 0.U,
          "packet-rate C2H buffer must be 4 KiB aligned")
        hostAddr := io.host_addr
        cycleInWindow := 0.U
        windowIndex := 0.U
        packetCount := 0.U
        queuePeak := 0.U
        packed := VecInit(Seq.fill(countsPerBeat)(0.U(recordBits.W)))
        beatIndex := 0.U
        state := sCollect
      }
    }
    is(sCollect) {
      when(endWindow) {
        cycleInWindow := 0.U
        packetCount := 0.U
        queuePeak := 0.U
        windowIndex := windowIndex + 1.U
        when(endGroup) {
          packed := VecInit(Seq.fill(countsPerBeat)(0.U(recordBits.W)))
        }.otherwise {
          packed := nextPacked
        }
        when(windowIndex === (samples - 1).U) {
          state := sCommand
        }
      }.otherwise {
        cycleInWindow := cycleInWindow + 1.U
        packetCount := packetCount + io.processed.asUInt
        queuePeak := peakIncludingCurrent
      }
    }
    is(sCommand) {
      when(io.c2h_cmd.fire) {
        state := sData
      }
    }
    is(sData) {
      when(io.c2h_data.fire) {
        beatIndex := beatIndex + 1.U
        when(beatIndex === (beats - 1).U) {
          state := sDone
        }
      }
    }
    is(sDone) {
      when(startPulse) {
        assert(io.host_addr(11, 0) === 0.U,
          "packet-rate C2H buffer must be 4 KiB aligned")
        hostAddr := io.host_addr
        cycleInWindow := 0.U
        windowIndex := 0.U
        packetCount := 0.U
        queuePeak := 0.U
        packed := VecInit(Seq.fill(countsPerBeat)(0.U(recordBits.W)))
        beatIndex := 0.U
        state := sCollect
      }
    }
  }
}

/** Instruction loading and receive-packet integration harness.
  *
  * H2C supplies instruction bytes to hotloading. SimPacketGen builds
  * simulation packets in Scala; HeadProcess removes the 70-byte header and
  * sends only payload to payload_out. Metadata is handled by RX_Meta's Tile,
  * the Tile receiving the hotloading IMEM writes and VRT updates.
  */
class ChunkLoadSimTop extends Module {
  val io = IO(new Bundle {
    val core_started = Output(Bool())
    val loading_start = Input(Bool())
    val host_mem_addr = Input(UInt(64.W))
    val imem_base_addr = Input(UInt(32.W))
    val mem_length = Input(UInt(32.W))

    val version = Input(UInt(VRTConfig.VersionWidth.W))
    // When enabled, changing `version` queues one complete H2C load.  The new
    // version becomes active for generated packet QPNs only after VRT commit.
    val auto_version_load = Input(Bool())
    val active_version = Output(UInt(VRTConfig.VersionWidth.W))
    val version_load_pending = Output(Bool())
    val version_load_busy = Output(Bool())
    val page_idx = Input(UInt(VRTConfig.IndexWidth.W))
    val shadow_slot = Input(UInt(VRTConfig.IndexWidth.W))
    val vrt_update_enable = Input(Bool())

    val h2c_cmd = Decoupled(new H2C_CMD)
    val h2c_data = Flipped(Decoupled(new H2C_DATA))
    val c2h_cmd = Decoupled(new C2H_CMD)
    val c2h_data = Decoupled(new C2H_DATA)
    val benchmark_host_addr = Input(UInt(64.W))
    val benchmark_busy = Output(Bool())
    val benchmark_done = Output(Bool())
    val benchmark_samples = Output(UInt(32.W))
    val payload_packets_checked = Output(UInt(32.W))
    val payload_length_errors = Output(UInt(32.W))
    val last_payload_bytes = Output(UInt(32.W))

    val packet_start = Input(Bool())
    val packet_qpn = Input(UInt(VRTConfig.VersionWidth.W))
    val packet_busy = Output(Bool())
    val packet_sent_count = Output(UInt(32.W))
    val slicer_start = Input(Bool())
    val slicer_payload_len = Input(UInt(16.W))
    val slicer_idle_cycle = Input(UInt(8.W))
    val rx_data_in = Flipped(Decoupled(new AXIS(512)))
    val payload_out = Decoupled(new AXIS(512))
    val meta_out = Decoupled(new HeadProcessMeta)
    val has_event_rd = Output(Bool())
    val event_recv_cnt = Output(UInt(32.W))
    val event_processed_cnt = Output(UInt(32.W))
    val event_count = Output(UInt(32.W))
    val rdma_print_addr = Output(UInt(32.W))
    val rdma_print_string_num = Output(UInt(32.W))
    val rdma_print_string_len = Output(UInt(32.W))
    val rdma_trap = Output(UInt(32.W))

    val vrt_hit = Output(Bool())
    val vrt_full = Output(Bool())
    val vrt_update_ready = Output(Bool())
    val vrt_update_valid = Output(Bool())
    val vrt_update_version = Output(UInt(VRTConfig.VersionWidth.W))
    val vrt_update_page_idx = Output(UInt(VRTConfig.IndexWidth.W))
    val vrt_update_shadow_slot = Output(UInt(VRTConfig.IndexWidth.W))

    val imem_addr = Output(UInt(32.W))
    val imem_wr_en = Output(Bool())
    val imem_data_in = Output(UInt(32.W))
  })

  val loader = Module(new hotloading())
  val packetSource = Module(new SimPacketGen())
  val frontend = Module(new SlicerFrontend())
  val rxMeta = Module(new RX_Meta(initFile = "inst_tx.mem"))
  val profiler = Module(new PacketRateProfiler(cyclesPerUs = 250))

  // A version write is a load request, not an immediate QPN change.  Snapshot
  // the complete descriptor when the request changes, issue one loader start
  // pulse when the loader is ready, and publish activeVersion only after the
  // loader has transferred cmd+data and completed its atomic VRT commit.
  val seenRequestedVersion = RegInit(0.U(VRTConfig.VersionWidth.W))
  val pendingValid = RegInit(false.B)
  val pendingVersion = RegInit(0.U(VRTConfig.VersionWidth.W))
  val pendingHostAddr = RegInit(0.U(64.W))
  val pendingImemBase = RegInit(0.U(32.W))
  val pendingLength = RegInit(0.U(32.W))
  val pendingPage = RegInit(0.U(VRTConfig.IndexWidth.W))
  val pendingShadow = RegInit(0.U(VRTConfig.IndexWidth.W))
  val pendingVrtEnable = RegInit(false.B)
  val loadInFlight = RegInit(false.B)
  val loadVersion = RegInit(0.U(VRTConfig.VersionWidth.W))
  val activeVersion = RegInit(0.U(VRTConfig.VersionWidth.W))
  // Replacing a page cannot affect a CPU that is already looping in the old
  // program. Arm a one-cycle PC/pipeline restart after commit, but wait until
  // RX_Meta has accepted the first event carrying the new QPN. CSR state and
  // that pending event survive cpu_reset, so startup fetches the committed VRT
  // entry and then processes the same event with the new program.
  val restartArmed = RegInit(false.B)
  val runningVersion = RegInit(0.U(VRTConfig.VersionWidth.W))

  // Zero is the unconfigured sentinel. Every change between non-zero VERSION
  // values is a real request; no test-specific A/B value appears here.
  val requestedVersionValid = io.version =/= 0.U
  val requestedVersionChanged = io.version =/= seenRequestedVersion
  val cpuLoadSafe = rxMeta.io.load_safe
  val manualStartAccepted = io.loading_start && loader.io.ready && cpuLoadSafe
  when(io.auto_version_load && requestedVersionValid && requestedVersionChanged) {
    seenRequestedVersion := io.version
    when(manualStartAccepted) {
      // A simultaneous manual start already carries this descriptor.
      pendingValid := false.B
    }.otherwise {
      pendingValid := true.B
      pendingVersion := io.version
      pendingHostAddr := io.host_mem_addr
      pendingImemBase := io.imem_base_addr
      pendingLength := io.mem_length
      pendingPage := io.page_idx
      pendingShadow := io.shadow_slot
      pendingVrtEnable := io.vrt_update_enable
    }
  }

  // Never interrupt a live event. RX_Meta also blocks event injection for the
  // complete reset interval, so the first post-release event is well formed.
  val autoStart = pendingValid && loader.io.ready && !io.loading_start &&
    cpuLoadSafe
  val loaderStart = (io.loading_start || autoStart) && cpuLoadSafe
  val loaderStartAccepted = loaderStart && loader.io.ready

  when(loaderStartAccepted) {
    loadInFlight := true.B
    when(autoStart) {
      loadVersion := pendingVersion
      pendingValid := false.B
    }.otherwise {
      loadVersion := io.version
      when(pendingValid && pendingVersion === io.version) {
        pendingValid := false.B
      }
    }
  }

  when(loadInFlight && loader.io.done) {
    activeVersion := loadVersion
    loadInFlight := false.B
    restartArmed := true.B
  }

  val programRestartPulse = restartArmed &&
    rxMeta.io.program_version === activeVersion &&
    activeVersion =/= runningVersion
  when(programRestartPulse) {
    runningVersion := activeVersion
    restartArmed := false.B
  }

  io.active_version := activeVersion
  io.version_load_pending := pendingValid || loadInFlight
  io.version_load_busy := loader.io.busy

  packetSource.io.start := io.packet_start
  packetSource.io.payload_len := io.slicer_payload_len
  packetSource.io.idle_cycle := io.slicer_idle_cycle
  // Both generated traffic paths use the version published only after the
  // cmd+data transfer and atomic VRT commit. Keep packet_qpn as a compatibility
  // fallback before the first committed VERSION exists.
  packetSource.io.qpn := Mux(activeVersion =/= 0.U,
    activeVersion, io.packet_qpn)
  io.packet_busy := packetSource.io.busy
  io.packet_sent_count := packetSource.io.sent_count
  // The internal source is the only frontend producer in this harness.
  frontend.io.s_axis <> packetSource.io.out
  // Keep the external CMAC1 RX path enabled without mixing it into this stream.
  io.rx_data_in.ready := true.B
  rxMeta.io.meta_in <> frontend.io.meta_out
  io.meta_out <> rxMeta.io.meta_out
  io.payload_out <> frontend.io.m_axis
  // Capture the first 1 ms after the slicer starts sending.
  profiler.io.start := io.slicer_start
  profiler.io.host_addr := io.benchmark_host_addr
  profiler.io.processed := io.meta_out.fire
  profiler.io.residual_count := rxMeta.io.meta_queue_count
  io.c2h_cmd <> profiler.io.c2h_cmd
  io.c2h_data <> profiler.io.c2h_data
  io.benchmark_busy := profiler.io.busy
  io.benchmark_done := profiler.io.done
  io.benchmark_samples := profiler.io.samples_captured

  // Validate the actual payload stream without changing the packet-count
  // samples returned by C2H. The expected length is latched per packet.
  val payloadBytesInPacket = RegInit(0.U(32.W))
  val expectedPayloadBytes = RegInit(0.U(16.W))
  val payloadInPacket = RegInit(false.B)
  val payloadPacketsChecked = RegInit(0.U(32.W))
  val payloadLengthErrors = RegInit(0.U(32.W))
  val lastPayloadBytes = RegInit(0.U(32.W))
  when(io.payload_out.fire) {
    val actualBytes = payloadBytesInPacket + PopCount(io.payload_out.bits.keep)
    val expectedBytes = Mux(payloadInPacket, expectedPayloadBytes,
      io.slicer_payload_len)
    when(!payloadInPacket) {
      expectedPayloadBytes := io.slicer_payload_len
      payloadInPacket := true.B
    }
    when(io.payload_out.bits.last.asBool) {
      lastPayloadBytes := actualBytes
      payloadPacketsChecked := payloadPacketsChecked + 1.U
      when(actualBytes =/= expectedBytes) {
        payloadLengthErrors := payloadLengthErrors + 1.U
      }
      payloadBytesInPacket := 0.U
      payloadInPacket := false.B
    }.otherwise {
      payloadBytesInPacket := actualBytes
    }
  }
  io.payload_packets_checked := payloadPacketsChecked
  io.payload_length_errors := payloadLengthErrors
  io.last_payload_bytes := lastPayloadBytes

  io.core_started := loader.io.core_started || programRestartPulse
  loader.io.loading_start := loaderStart
  loader.io.host_mem_addr := Mux(autoStart, pendingHostAddr, io.host_mem_addr)
  loader.io.imem_base_addr := Mux(autoStart, pendingImemBase, io.imem_base_addr)
  loader.io.mem_length := Mux(autoStart, pendingLength, io.mem_length)
  loader.io.version := Mux(autoStart, pendingVersion, io.version)
  loader.io.page_idx := Mux(autoStart, pendingPage, io.page_idx)
  loader.io.shadow_slot := Mux(autoStart, pendingShadow, io.shadow_slot)
  loader.io.vrt_update_enable := Mux(
    autoStart, pendingVrtEnable, io.vrt_update_enable
  )

  io.h2c_cmd <> loader.io.h2c_cmd
  loader.io.h2c_data <> io.h2c_data

  rxMeta.io.cpu_reset := loader.io.core_started || programRestartPulse
  rxMeta.io.imem_addr := loader.io.imem_addr
  rxMeta.io.imem_wr_en := loader.io.imem_wr_en
  rxMeta.io.imem_musk := loader.io.imem_musk
  rxMeta.io.imem_data_in := loader.io.imem_data_in
  io.imem_addr := loader.io.imem_addr
  io.imem_wr_en := loader.io.imem_wr_en
  io.imem_data_in := loader.io.imem_data_in
  rxMeta.io.vrt_update <> loader.io.vrt_update
  rxMeta.io.axi := DontCare

  io.vrt_update_ready := loader.io.vrt_update.ready
  io.vrt_update_valid := loader.io.vrt_update.valid
  io.vrt_update_version := loader.io.vrt_update.bits.version
  io.vrt_update_page_idx := loader.io.vrt_update.bits.page_idx
  io.vrt_update_shadow_slot := loader.io.vrt_update.bits.shadow_slot
  io.vrt_hit := rxMeta.io.vrt_hit
  io.vrt_full := rxMeta.io.vrt_full

  io.has_event_rd := rxMeta.io.has_event_rd
  io.event_recv_cnt := rxMeta.io.event_recv_cnt
  io.event_processed_cnt := rxMeta.io.event_processed_cnt
  io.event_count := rxMeta.io.event_count
  io.rdma_print_addr := rxMeta.io.rdma_print_addr
  io.rdma_print_string_num := rxMeta.io.rdma_print_string_num
  io.rdma_print_string_len := rxMeta.io.rdma_print_string_len
  io.rdma_trap := rxMeta.io.rdma_trap

  }
