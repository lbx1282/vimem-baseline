package mini.foo

import chisel3._
import chisel3.util._
import qdma._
import mini.core.{VRTConfig, VRTEntry}

/** Loads instruction bytes from host memory into IMEM.
  *
  * Legacy full-image loading remains available when `vrt_update_enable` is
  * false. For a versioned chunk update, data is written to `shadow_slot` in
  * instruction order and the VRT entry is committed only after the last word
  * has reached IMEM.
  */
class hotloading extends Module {
  val io = IO(new Bundle {
    // Historical name kept for compatibility. This is an active-high CPU
    // reset request for every accepted instruction load. It remains asserted
    // through all IMEM writes and, for versioned loads, through VRT commit.
    val core_started = Output(Bool())
    val ready = Output(Bool())
    val busy = Output(Bool())
    val done = Output(Bool())
    val loading_start = Input(Bool())
    val host_mem_addr = Input(UInt(64.W))
    // Physical IMEM base (normally 0x80000000), not a per-page destination.
    val imem_base_addr = Input(UInt(32.W))
    val mem_length = Input(UInt(32.W))

    val version = Input(UInt(VRTConfig.VersionWidth.W))
    val page_idx = Input(UInt(VRTConfig.IndexWidth.W))
    val shadow_slot = Input(UInt(VRTConfig.IndexWidth.W))
    val vrt_update_enable = Input(Bool())
    val vrt_update = Decoupled(new VRTEntry)

    val h2c_cmd = Decoupled(new H2C_CMD)
    val h2c_data = Flipped(Decoupled(new H2C_DATA))

    val imem_addr = Output(UInt(32.W))
    val imem_wr_en = Output(Bool())
    val imem_musk = Output(UInt(4.W))
    val imem_data_in = Output(UInt(32.W))
  })

  val sIdle :: sTransfer :: sCommit :: sDone :: Nil = Enum(4)
  val state = RegInit(sIdle)

  val core_started_reg = RegInit(false.B)
  val current_addr = RegInit(0.U(64.W))
  val bytes_remaining = RegInit(0.U(32.W))
  val data_remaining = RegInit(0.U(32.W))
  val imem_wr_addr = RegInit(0.U(32.W))

  val data_buffer = RegInit(0.U(512.W))
  val word_cnt = RegInit(0.U(4.W))
  val wordsInBuffer = RegInit(0.U(5.W))
  val writing_active_reg = RegInit(false.B)

  val updateEnabled = RegInit(false.B)
  val updateVersion = RegInit(0.U(VRTConfig.VersionWidth.W))
  val updatePage = RegInit(0.U(VRTConfig.IndexWidth.W))
  val updateShadow = RegInit(0.U(VRTConfig.IndexWidth.W))

  io.core_started := core_started_reg
  io.ready := state === sIdle
  io.busy := state === sTransfer || state === sCommit
  io.done := state === sDone
  io.h2c_cmd.valid := false.B
  io.h2c_cmd.bits := 0.U.asTypeOf(new H2C_CMD)
  io.h2c_data.ready := false.B

  io.imem_addr := imem_wr_addr
  io.imem_wr_en := false.B
  io.imem_musk := "b1111".U
  io.imem_data_in := (data_buffer >> (word_cnt << 5))(31, 0)

  io.vrt_update.valid := false.B
  io.vrt_update.bits.valid := true.B
  io.vrt_update.bits.version := updateVersion
  io.vrt_update.bits.page_idx := updatePage
  io.vrt_update.bits.shadow_slot := updateShadow

  switch(state) {
    is(sIdle) {
      core_started_reg := false.B

      when(io.loading_start) {
        assert(io.mem_length =/= 0.U, "instruction load must contain data")
        assert(io.mem_length(1, 0) === 0.U, "instruction load length must be word aligned")
        when(io.vrt_update_enable) {
          assert(
            io.mem_length <= (VRTConfig.ChunkWords * 4).U,
            "a versioned update must fit in one instruction chunk"
          )
        }

        state := sTransfer
        // Scala owns the complete CPU reset interval.  The TB/software only
        // requests a load; reset is asserted before transfer and released
        // after the final IMEM write and optional atomic VRT commit.
        core_started_reg := true.B
        current_addr := io.host_mem_addr
        bytes_remaining := io.mem_length
        data_remaining := io.mem_length
        writing_active_reg := false.B

        updateEnabled := io.vrt_update_enable
        updateVersion := io.version
        updatePage := io.page_idx
        updateShadow := io.shadow_slot

        val shadowByteOffset = io.shadow_slot * (VRTConfig.ChunkWords * 4).U
        imem_wr_addr := Mux(
          io.vrt_update_enable,
          io.imem_base_addr + shadowByteOffset,
          io.imem_base_addr
        )
      }
    }

    is(sTransfer) {
      // Issue one or more H2C commands. QDMA limits a command to 4096 bytes.
      when(bytes_remaining =/= 0.U && !writing_active_reg) {
        val burstLength = Mux(bytes_remaining > 4096.U, 4096.U, bytes_remaining)

        io.h2c_cmd.valid := true.B
        io.h2c_cmd.bits.addr := current_addr
        io.h2c_cmd.bits.len := burstLength
        io.h2c_cmd.bits.sop := true.B
        io.h2c_cmd.bits.eop := bytes_remaining <= 4096.U
        io.h2c_cmd.bits.qid := 1.U

        when(io.h2c_cmd.fire) {
          current_addr := current_addr + burstLength
          bytes_remaining := bytes_remaining - burstLength
        }
      }

      // Buffer one 512-bit beat, then write only its valid 32-bit words.
      when(!writing_active_reg) {
        io.h2c_data.ready := true.B
        when(io.h2c_data.fire) {
          val beatBytes = Mux(data_remaining > 64.U, 64.U, data_remaining)
          val beatWords = beatBytes >> 2

          data_buffer := io.h2c_data.bits.data
          word_cnt := 0.U
          wordsInBuffer := beatWords(4, 0)
          writing_active_reg := beatWords =/= 0.U
          data_remaining := data_remaining - beatBytes
        }
      }.otherwise {
        io.imem_wr_en := true.B
        imem_wr_addr := imem_wr_addr + 4.U

        // `word_cnt` is intentionally kept at four bits for compatibility
        // with the existing testbench.  Use the widening add here so that
        // 15 + 1 compares as 16 instead of wrapping back to zero.
        when((word_cnt +& 1.U) === wordsInBuffer) {
          writing_active_reg := false.B
        }.otherwise {
          word_cnt := word_cnt + 1.U
        }
      }

      when(bytes_remaining === 0.U && data_remaining === 0.U && !writing_active_reg) {
        when(updateEnabled) {
          state := sCommit
        }.otherwise {
          core_started_reg := false.B
          state := sDone
        }
      }
    }

    is(sCommit) {
      // Atomic publication: the new chunk is unreachable until this handshake.
      io.vrt_update.valid := true.B
      when(io.vrt_update.fire) {
        core_started_reg := false.B
        state := sDone
      }
    }

    is(sDone) {
      core_started_reg := false.B
      when(!io.loading_start) {
        state := sIdle
      }
    }
  }
}
