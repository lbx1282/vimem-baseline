package mini.foo

import chisel3._
import chisel3.util._
import common._
import common.axi._
import common.storage._
import generator.HeadProcessMeta
import mini.core._

class RX_Meta(initFile: String = "inst_rx.mem") extends Module {
  val io = IO(new Bundle {
    val meta_in = Flipped(Decoupled(new HeadProcessMeta))
    val meta_out = Decoupled(new HeadProcessMeta)
    val event_count = Output(UInt(32.W))
    val has_event_rd = Output(Bool())
    val event_recv_cnt = Output(UInt(32.W))
    val event_processed_cnt = Output(UInt(32.W))
    // Occupancy of the 2048-entry metadata FIFO, excluding the event in core.
    val meta_queue_count = Output(UInt(12.W))
    val program_version = Output(UInt(VRTConfig.VersionWidth.W))
    val debug_pc = Output(UInt(32.W))
    // True only at an event boundary where the loader may safely reset CPU.
    val load_safe = Output(Bool())
    val rdma_print_addr = Output(UInt(32.W))
    val rdma_print_string_num = Output(UInt(32.W))
    val rdma_print_string_len = Output(UInt(32.W))
    val rdma_trap = Output(UInt(32.W))
    //cpu_reset
    val cpu_reset = Input(Bool())
    // imem hot-loading interface
    val imem_addr     = Input(UInt(32.W))
    val imem_wr_en    = Input(Bool())
    val imem_musk     = Input(UInt(4.W))
    val imem_data_in  = Input(UInt(32.W))
    val vrt_update = Flipped(Decoupled(new VRTEntry))
    val vrt_hit = Output(Bool())
    val vrt_full = Output(Bool())
    val axi = new AXI(33, 256, 6, 0, 4)
  })

  val config = MiniConfig()
  val rx_core = Module(new Tile(
    enable_hbm = config.enable_hbm,
    coreParams = config.core,
    bramParams = config.bram,
    nastiParams = config.nasti,
    cacheParams = config.cache,
    file = initFile
  ))

  // Tile uses its dedicated CPU reset for program loading. The Tile module
  // itself remains on this module's normal clock/reset domain.
  io.event_count := rx_core.io.event_count
  io.has_event_rd := rx_core.io.has_event_rd
  io.event_recv_cnt := rx_core.io.event_recv_cnt
  io.event_processed_cnt := rx_core.io.event_processed_cnt
  io.program_version := rx_core.io.program_version
  io.debug_pc := rx_core.io.debug_pc
  io.rdma_print_addr := rx_core.io.rdma_print_addr
  io.rdma_print_string_num := rx_core.io.rdma_print_string_num
  io.rdma_print_string_len := rx_core.io.rdma_print_string_len
  io.rdma_trap := rx_core.io.rdma_trap
  rx_core.io.cpu_reset := io.cpu_reset
  rx_core.io.imem_addr := io.imem_addr
  rx_core.io.imem_wr_en := io.imem_wr_en
  rx_core.io.imem_musk := io.imem_musk
  rx_core.io.imem_data_in := io.imem_data_in
  rx_core.io.vrt_update <> io.vrt_update
  io.vrt_hit := rx_core.io.vrt_hit
  io.vrt_full := rx_core.io.vrt_full

  io.axi.aw <> rx_core.io.nasti.aw
  io.axi.w <> rx_core.io.nasti.w
  io.axi.ar <> rx_core.io.nasti.ar
  io.axi.r <> rx_core.io.nasti.r
  io.axi.b <> rx_core.io.nasti.b

  rx_core.io.host := DontCare

  val meta_fifo = XQueue(new HeadProcessMeta, entries = 2048)
  io.meta_in <> meta_fifo.io.in
  io.meta_queue_count := meta_fifo.io.count

  val meta_reg = RegInit(0.U.asTypeOf(new HeadProcessMeta))

  val sIDLE :: sWR_CORE :: sDONE :: Nil = Enum(3)
  val state = RegInit(sIDLE)
  val meta_addr_base = RegInit(0.U(5.W))

  // Do not advance metadata into the event injector while the loader owns
  // cpu_reset. A packet already selected on the reset-assertion edge remains
  // in meta_reg and is injected only after reset is released.
  meta_fifo.io.out.ready := state === sIDLE && !io.cpu_reset
  io.load_safe := state === sIDLE && !rx_core.io.has_event_rd &&
    rx_core.io.event_recv_cnt === rx_core.io.event_processed_cnt

  ToZero(rx_core.io.has_event_wr)
  ToZero(rx_core.io.user_csr_wr)
  ToZero(io.meta_out.valid)
  ToZero(io.meta_out.bits)

  switch(state) {
    is(sIDLE) {
      when(!io.cpu_reset && meta_fifo.io.out.fire) {
        meta_reg := meta_fifo.io.out.bits
        meta_addr_base := rx_core.io.user_table_size(4, 0)
        state := sWR_CORE
      }
    }

    is(sWR_CORE) {
      when(!io.cpu_reset && rx_core.io.has_event_rd === 0.U) {
        rx_core.io.has_event_wr := true.B

        // HeadProcessMeta is 128 bits and occupies four 32-bit CSRs.
        rx_core.io.user_csr_wr(meta_addr_base) := meta_reg.src_ipv4
        rx_core.io.user_csr_wr(meta_addr_base + 1.U) := meta_reg.dst_ipv4
        rx_core.io.user_csr_wr(meta_addr_base + 2.U) :=
          Cat(meta_reg.src_port, meta_reg.dst_port)
        rx_core.io.user_csr_wr(meta_addr_base + 3.U) :=
          Cat(meta_reg.op_code, meta_reg.qpn)
        state := sDONE
      }
    }

    is(sDONE) {
      when(
        rx_core.io.has_event_rd === 0.U &&
          rx_core.io.event_recv_cnt === rx_core.io.event_processed_cnt
      ) {
        io.meta_out.valid := true.B
        io.meta_out.bits := meta_reg
        io.meta_out.bits.src_ipv4 := rx_core.io.user_csr_rd(meta_addr_base)
        io.meta_out.bits.dst_ipv4 := rx_core.io.user_csr_rd(meta_addr_base + 1.U)
        io.meta_out.bits.src_port := rx_core.io.user_csr_rd(meta_addr_base + 2.U)(31, 16)
        io.meta_out.bits.dst_port := rx_core.io.user_csr_rd(meta_addr_base + 2.U)(15, 0)
        io.meta_out.bits.op_code := rx_core.io.user_csr_rd(meta_addr_base + 3.U)(31, 24)
        io.meta_out.bits.qpn := rx_core.io.user_csr_rd(meta_addr_base + 3.U)(23, 0)

        when(io.meta_out.ready) {
          state := sIDLE
        }
      }
    }
  }
}
