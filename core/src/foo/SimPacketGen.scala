package mini.foo

import chisel3._
import chisel3.util._
import common.axi.AXIS
import generator.{GeneratorConfig, slicer}
import mini.core.VRTConfig

/** Simulation packet source used by the hot-loading test path.
  *
  * Packet construction is intentionally delegated to the same runtime
  * `slicer` used by SlicerArbiterTop. Payload length, idle cycles and
  * QPN/version are therefore sampled from IO for every packet instead of
  * being baked into the elaborated Verilog.
  */
class SimPacketGen(
  genConfig: GeneratorConfig = GeneratorConfig()
) extends Module {
  val io = IO(new Bundle {
    val start = Input(Bool())
    val payload_len = Input(UInt(16.W))
    val idle_cycle = Input(UInt(8.W))
    val qpn = Input(UInt(VRTConfig.VersionWidth.W))
    val out = Decoupled(new AXIS(512))
    val busy = Output(Bool())
    val sent_count = Output(UInt(32.W))
  })

  val source = Module(new slicer(genConfig))
  val sentCount = RegInit(0.U(32.W))

  source.io.start := io.start
  source.io.payload_len := io.payload_len
  source.io.idle_cycle := io.idle_cycle
  source.io.qpn := io.qpn

  io.out.valid := source.io.m_axis.valid
  io.out.bits := source.io.m_axis.bits
  source.io.m_axis.ready := io.out.ready

  when(source.io.m_axis.fire && source.io.m_axis.bits.last.asBool) {
    sentCount := sentCount + 1.U
  }

  io.busy := source.io.busy
  io.sent_count := sentCount
}
