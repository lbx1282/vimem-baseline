package mini.foo

import chisel3._
import chisel3.util._
import common.LatencyBucket
import common.storage._

/** Measures one packet from the first CMAC0-bound slicer beat until both its
  * last CMAC1-received beat and RXcore's event_processed_cnt increment occur.
  * Both streams are ordered. Each capture contains at most 32768 packets;
  * canSend pauses the slicer once the capture RAM is full. Software stops
  * traffic and drains RX before clearing for the next capture.
  */
class SlicerRxLatency extends Module {
  val io = IO(new Bundle {
    val sendFire = Input(Bool())
    val sendLast = Input(Bool())
    val rxLast = Input(Bool())
    val sendQpn = Input(UInt(24.W))
    val sendCycle = Input(UInt(32.W))
    val coreDone = Input(Bool())
    val enable = Input(Bool())
    val bucketRdId = Input(UInt(10.W))
    val recordRdId = Input(UInt(15.W))
    val clear = Input(Bool())
    val canSend = Output(Bool())
    val bucketValue = Output(UInt(32.W))
    val recordValue = Output(UInt(32.W))
    val recordQpn = Output(UInt(24.W))
    val recordStartCycle = Output(UInt(32.W))
    val recordsWritten = Output(UInt(32.W))
    val captureFull = Output(Bool())
    val pairingError = Output(Bool())
    val resetDone = Output(Bool())
    val sentPackets = Output(UInt(32.W))
    val processedPackets = Output(UInt(32.W))
    val outstandingPackets = Output(UInt(32.W))
  })

  // A packet can follow the previous packet with no idle beat. The last beat
  // clears this flag, so the next accepted beat is a new start even then.
  val inPacket = RegInit(false.B)
  val firstBeat = io.sendFire && !inPacket
  // Break the frontend FIFO-count -> result BRAM write-enable timing path.
  // Retiming both completion observations by one clock preserves their order.
  val lastBeat = RegNext(io.rxLast, false.B)
  val coreDone = RegNext(io.coreDone, false.B)
  when(io.sendFire) {
    inPacket := !io.sendLast
  }

  val sent = RegInit(0.U(32.W))
  val receivedLast = RegInit(0.U(32.W))
  val processed = RegInit(0.U(32.W))
  when(firstBeat) { sent := sent + 1.U }
  when(lastBeat) { receivedLast := receivedLast + 1.U }
  when(coreDone) { processed := processed + 1.U }
  io.sentPackets := sent
  io.processedPackets := processed
  io.outstandingPackets := sent -
    Mux(receivedLast < processed, receivedLast, processed)

  // Clear the uninitialized histogram RAM after reset. Software may request
  // another clear with a rising edge after stopping traffic and draining RX.
  val powerOnClear = RegInit(true.B)
  powerOnClear := false.B
  val clearPrev = RegNext(io.clear, false.B)
  val clearPulse = io.clear && !clearPrev

  val latency_bucket = Module(new LatencyBucket(
    BUCKET_SIZE = 1024,
    LATENCY_STRIDE = 32,
    MAX_INFLIGHT = 4096
  ))

  // Keep a timestamp for every packet admitted to this capture. The existing
  // RX metadata FIFO has 2048 entries. The timestamp FIFO covers that plus
  // frontend buffering; the result RAM covers the full timed capture.
  val timer = RegInit(0.U(64.W))
  timer := timer + 1.U
  val capturedStarts = RegInit(0.U(16.W))
  val capturedLasts = RegInit(0.U(16.W))
  val capturedCoreDones = RegInit(0.U(16.W))
  val capturedEnds = RegInit(0.U(16.W))
  val pairError = RegInit(false.B)
  when(clearPulse) {
    capturedStarts := 0.U
    capturedLasts := 0.U
    capturedCoreDones := 0.U
    capturedEnds := 0.U
    pairError := false.B
  }

  val captureReady = latency_bucket.io.resetDone && !powerOnClear &&
    !clearPulse
  io.captureFull := capturedStarts === 32768.U
  io.canSend := !io.enable || (captureReady && !io.captureFull)
  val captureStart = firstBeat && io.enable && captureReady &&
    !io.captureFull
  // Both the slicer and RXcore preserve packet order. The nth result is
  // written only after the nth received last beat and nth core completion,
  // whichever occurs later. Include same-cycle events in these comparisons.
  val captureLast = lastBeat &&
    (capturedLasts < capturedStarts || captureStart)
  val captureCoreDone = coreDone &&
    (capturedCoreDones < capturedStarts || captureStart)
  val captureEnd = capturedEnds < (capturedStarts + captureStart.asUInt) &&
    (capturedLasts + captureLast.asUInt) > capturedEnds &&
    (capturedCoreDones + captureCoreDone.asUInt) > capturedEnds

  latency_bucket.io.enable       := io.enable && latency_bucket.io.resetDone &&
    !powerOnClear && !clearPulse
  // Start and end both reach LatencyBucket one clock after the actual event.
  latency_bucket.io.start        := RegNext(captureStart, false.B)
  latency_bucket.io.end          := captureEnd
  latency_bucket.io.bucketRdId   := io.bucketRdId
  latency_bucket.io.resetBucket  := powerOnClear || clearPulse
  io.bucketValue                 := latency_bucket.io.bucketValue
  io.resetDone                   := latency_bucket.io.resetDone && !powerOnClear

  val startTimes = XQueue(UInt(120.W), entries = 4096)
  startTimes.io.in.valid := captureStart
  startTimes.io.in.bits := Cat(io.sendCycle, io.sendQpn, timer)
  startTimes.io.out.ready := captureEnd

  val records = XRam(UInt(88.W), entries = 32768, latency = 2)
  records.io.addr_a := capturedEnds(14, 0)
  records.io.wr_en_a := captureEnd && startTimes.io.out.valid
  records.io.data_in_a := Cat(
    startTimes.io.out.bits(119, 88),
    startTimes.io.out.bits(87, 64),
    (timer - startTimes.io.out.bits(63, 0) - 1.U)(31, 0)
  )
  records.io.addr_b := io.recordRdId
  io.recordValue := records.io.data_out_b(31, 0)
  io.recordQpn := records.io.data_out_b(55, 32)
  io.recordStartCycle := records.io.data_out_b(87, 56)
  io.recordsWritten := capturedEnds
  io.pairingError := pairError

  when(captureStart) {
    capturedStarts := capturedStarts + 1.U
    when(!startTimes.io.in.ready) { pairError := true.B }
  }
  when(captureLast) { capturedLasts := capturedLasts + 1.U }
  when(captureCoreDone) { capturedCoreDones := capturedCoreDones + 1.U }
  when(io.enable && ((lastBeat && !captureLast) ||
      (coreDone && !captureCoreDone))) {
    pairError := true.B
  }
  when(captureEnd) {
    when(startTimes.io.out.valid) {
      capturedEnds := capturedEnds + 1.U
    }.otherwise {
      pairError := true.B
    }
  }

}
