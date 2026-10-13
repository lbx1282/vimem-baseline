package mini.foo

import chisel3._
import chisel3.util._
import common.axi._
import generator.{GeneratorConfig, HeadProcessMeta, SlicerFrontend}
import mini.core.VRTEntry

/** Complete packet-source/RX pipeline with metadata processed by the RISC-V Tile. */
class SlicerArbiterTop(
  genConfig: GeneratorConfig = GeneratorConfig()
) extends Module {
  val io = IO(new Bundle {
    val start = Input(Bool())
    val payload_len = Input(UInt(16.W))
    val idle_cycle = Input(UInt(8.W))
    val qpn = Input(UInt(24.W))

    val meta_out = Decoupled(new HeadProcessMeta)
    val m_axis = Decoupled(new AXIS(512))

    val event_count = Output(UInt(32.W))
    val cpu_reset = Input(Bool())
    val imem_addr     = Input(UInt(32.W))
    val imem_wr_en    = Input(Bool())
    val imem_musk     = Input(UInt(4.W))
    val imem_data_in  = Input(UInt(32.W))
    val vrt_update = Flipped(Decoupled(new VRTEntry))
    val vrt_hit = Output(Bool())
    val vrt_full = Output(Bool())
    val axi = new AXI(33, 256, 6, 0, 4)
  })

  val packetSource = Module(new SimPacketGen(genConfig))
  val front = Module(new SlicerFrontend(genConfig))
  val rxMeta = Module(new RX_Meta)

  packetSource.io.start := io.start
  packetSource.io.payload_len := io.payload_len
  packetSource.io.idle_cycle := io.idle_cycle
  packetSource.io.qpn := io.qpn

  // Source-to-frontend direction is intentionally explicit.
  front.io.s_axis <> packetSource.io.out

  rxMeta.io.meta_in <> front.io.meta_out
  io.meta_out <> rxMeta.io.meta_out
  io.m_axis <> front.io.m_axis
  io.event_count := rxMeta.io.event_count
  
  rxMeta.io.cpu_reset := io.cpu_reset
  rxMeta.io.imem_addr := io.imem_addr
  rxMeta.io.imem_wr_en := io.imem_wr_en
  rxMeta.io.imem_musk := io.imem_musk
  rxMeta.io.imem_data_in := io.imem_data_in
  rxMeta.io.vrt_update <> io.vrt_update
  io.vrt_hit := rxMeta.io.vrt_hit
  io.vrt_full := rxMeta.io.vrt_full
  io.axi <> rxMeta.io.axi
}
