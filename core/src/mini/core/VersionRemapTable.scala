package mini.core

import chisel3._
import chisel3.util._

/** Shared layout constants for the version remap table (VRT).
  *
  * Instruction images are split into 19-word chunks by split_inst_parts.py.
  * The VRT changes only the physical chunk (shadow slot); the word offset
  * inside the chunk is preserved so instructions are fetched in order.
  */
object VRTConfig {
  val VersionWidth = 24
  val IndexWidth = 16
  val ChunkWords = 45
  val Entries = 64
}

/** One content-addressed VRT mapping.
  *
  * `version` is the packet QPN copied into the RISC-V metadata CSR.
  */
class VRTEntry extends Bundle {
  val valid = Bool()
  val version = UInt(VRTConfig.VersionWidth.W)
  val page_idx = UInt(VRTConfig.IndexWidth.W)
  val shadow_slot = UInt(VRTConfig.IndexWidth.W)
}

/** Remaps a logical instruction address to a version-specific shadow chunk.
  *
  * An absent mapping is an identity mapping. Updates replace an existing
  * `{version, page_idx}` entry or consume the first invalid entry. A clear
  * update (`valid = false`) removes the matching entry. Because a mapping is
  * committed with one register write, a CPU can never observe a half-updated
  * VRT entry.
  */
class VersionRemapTable(
  xlen: Int,
  imemBase: BigInt,
  imemWords: Int,
  chunkWords: Int = VRTConfig.ChunkWords,
  numEntries: Int = VRTConfig.Entries
) extends Module {
  require(xlen >= 32)
  require(imemBase >= 0)
  require(imemWords > 0)
  require(chunkWords > 0)
  require(numEntries > 0)

  val io = IO(new Bundle {
    val logical_addr = Input(UInt(xlen.W))
    val version = Input(UInt(VRTConfig.VersionWidth.W))
    val update = Flipped(Decoupled(new VRTEntry))

    val physical_addr = Output(UInt(xlen.W))
    val hit = Output(Bool())
    val full = Output(Bool())
  })

  val entries = RegInit(VecInit(Seq.fill(numEntries)(0.U.asTypeOf(new VRTEntry))))

  val existingMatch = VecInit(entries.map { entry =>
    entry.valid &&
      entry.version === io.update.bits.version &&
      entry.page_idx === io.update.bits.page_idx
  })
  val freeEntry = VecInit(entries.map(entry => !entry.valid))
  val hasExisting = existingMatch.asUInt.orR
  val hasFree = freeEntry.asUInt.orR
  val existingIndex = PriorityEncoder(existingMatch)
  val freeIndex = PriorityEncoder(freeEntry)
  val updateIndex = Mux(hasExisting, existingIndex, freeIndex)

  // Clears are idempotent. Inserts backpressure only when every entry is live.
  io.update.ready := !io.update.bits.valid || hasExisting || hasFree
  io.full := !hasFree

  when(io.update.fire) {
    when(io.update.bits.valid) {
      entries(updateIndex) := io.update.bits
    }.elsewhen(hasExisting) {
      entries(existingIndex).valid := false.B
    }
  }

  val imemBaseU = imemBase.U(xlen.W)
  val imemEndU = (imemBase + imemWords * 4L).U(xlen.W)
  val inImem = io.logical_addr >= imemBaseU && io.logical_addr < imemEndU
  val logicalWord = (io.logical_addr - imemBaseU) >> 2
  val logicalPage = logicalWord / chunkWords.U
  val wordOffset = logicalWord % chunkWords.U

  val lookupMatch = VecInit(entries.map { entry =>
    entry.valid &&
      entry.version === io.version &&
      entry.page_idx === logicalPage
  })
  val hasLookup = lookupMatch.asUInt.orR
  val mappedSlot = Mux1H(lookupMatch, entries.map(_.shadow_slot))
  val physicalSlot = Mux(hasLookup, mappedSlot, logicalPage)
  val physicalWord = physicalSlot * chunkWords.U + wordOffset
  val remappedAddr = imemBaseU + (physicalWord << 2)

  io.hit := inImem && hasLookup
  io.physical_addr := Mux(io.hit, remappedAddr, io.logical_addr)
}
