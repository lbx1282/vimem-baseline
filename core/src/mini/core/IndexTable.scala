package mini.core

import chisel3._
import chisel3.util._
import chisel3.util.experimental.loadMemoryFromFile

/** Index table for instruction part remapping.
  *
  * Maps a logical instruction block to a physical part stored in
  * `parts.mem`. RX and TX directions have independent mappings
  * (`inst_rx.index.mem` and `inst_tx.index.mem`).
  */
class IndexTable(
  numLogicalBlocks: Int,
  indexWidth: Int = VRTConfig.IndexWidth,
  blockWords: Int = VRTConfig.ChunkWords,
  hostBase: BigInt = 0x1000
) extends Module {
  require(numLogicalBlocks > 0)
  require(indexWidth > 0)
  require(blockWords > 0)

  val blockBytes = blockWords * 4

  val io = IO(new Bundle {
    // Query interface
    val logical_block = Input(UInt(indexWidth.W))
    val is_tx     = Input(Bool())   // false = RX, true = TX

    val physical_part = Output(UInt(indexWidth.W))
    val valid         = Output(Bool())

    // Convenience outputs for hotloading
    val page_idx      = Output(UInt(VRTConfig.IndexWidth.W))
    val shadow_slot   = Output(UInt(VRTConfig.IndexWidth.W))
    val host_mem_addr = Output(UInt(64.W))
    val mem_length    = Output(UInt(32.W))
  })

  // RX / TX mapping tables
  val rxTable = SyncReadMem(numLogicalBlocks, UInt(indexWidth.W))
  val txTable = SyncReadMem(numLogicalBlocks, UInt(indexWidth.W))

  val rxValid = RegInit(VecInit(Seq.fill(numLogicalBlocks)(false.B)))
  val txValid = RegInit(VecInit(Seq.fill(numLogicalBlocks)(false.B)))

  // Initialize from index files.
  loadMemoryFromFile(rxTable, "inst_parts/inst_rx.index.mem")
  loadMemoryFromFile(txTable, "inst_parts/inst_tx.index.mem")

  // Synchronous read
  val rxData = rxTable.read(io.logical_block, io.is_tx === false.B)
  val txData = txTable.read(io.logical_block, io.is_tx === true.B)

  val selected  = Mux(io.is_tx, txData, rxData)
  val entryValid = Mux(io.is_tx, txValid(io.logical_block), rxValid(io.logical_block))

  io.physical_part := selected
  io.valid         := entryValid

  // Convenience outputs
  io.page_idx      := io.logical_block
  io.shadow_slot   := selected
  io.host_mem_addr := hostBase.U(64.W) + (selected * blockBytes.U)
  io.mem_length    := blockBytes.U
}