package mini.foo

import chisel3._
import chisel3.util._
import qdma._
import hbm._
import common._
import common.storage._
import common.axi._
import qdma.examples._
import common.partialReconfig.AlveoStaticIO
import mini.foo._
import mini.core._
import mini.junctions._

class test_hotloading extends Module {
    val io = IO(new Bundle {
        val core_started     = Output(Bool())
        val loading_start   = Input(Bool())
        val host_mem_addr   = Input(UInt(64.W))//程序镜像在主机内存中的源地址
        val imem_base_addr  = Input(UInt(32.W))//CPU指令BRAM中的目标基地址
        val mem_length      = Input(UInt(32.W))//CPU中RISCV程序代码的长度
        val version         = Input(UInt(VRTConfig.VersionWidth.W))
        val page_idx        = Input(UInt(VRTConfig.IndexWidth.W))
        val shadow_slot     = Input(UInt(VRTConfig.IndexWidth.W))
        val vrt_update_enable = Input(Bool())
        val is_tx           = Input(Bool())   // false = RX, true = TX
        val vrt_hit         = Output(Bool())
        val vrt_full        = Output(Bool())
        val h2c_cmd		    = (Decoupled(new H2C_CMD))
		val h2c_data	    = Flipped(Decoupled(new H2C_DATA))
        val has_event_wr       = Input(Bool())     //write pkg_meta & cc_state
        val has_event_rd       = Output(Bool())    // has_event_rd==0 && event_recv_cnt==event_processed_cnt
        val event_recv_cnt      = Output(UInt(32.W))
        val event_processed_cnt = Output(UInt(32.W))
        val event_count         = Output(UInt(32.W))
    })
    val config = MiniConfig()
    //实例化hotloading
    val hotloading = Module(new hotloading())
    io.core_started := hotloading.io.core_started

    val indexTable = Module(new IndexTable(
    numLogicalBlocks = 45,
    indexWidth       = VRTConfig.IndexWidth,
    blockWords       = VRTConfig.ChunkWords,
    hostBase         = 0x1000
    ))

    //实例化tile
    val mini_core = withClockAndReset(clock, reset.asBool) {
        Module(new Tile(
        enable_hbm = config.enable_hbm,
        coreParams = config.core,
        bramParams = config.bram,
        nastiParams = config.nasti,
        cacheParams = config.cache
        ))
    }

    indexTable.io.logical_block := io.page_idx
    indexTable.io.is_tx     := io.is_tx

    //imem inf /*writ code here*/连接hotloading和mini_core
    mini_core.io.cpu_reset      := hotloading.io.core_started
    hotloading.io.loading_start := io.loading_start
    hotloading.io.imem_base_addr := io.imem_base_addr
    hotloading.io.version := io.version
    hotloading.io.vrt_update_enable := io.vrt_update_enable

    hotloading.io.host_mem_addr := indexTable.io.host_mem_addr
    hotloading.io.mem_length    := indexTable.io.mem_length
    hotloading.io.page_idx      := indexTable.io.page_idx
    hotloading.io.shadow_slot   := indexTable.io.shadow_slot
    

    //连接hotloading的输出(驱动层IO)
    io.h2c_cmd.valid := hotloading.io.h2c_cmd.valid
    io.h2c_cmd.bits  := hotloading.io.h2c_cmd.bits
    hotloading.io.h2c_cmd.ready := io.h2c_cmd.ready
    // hotloading.io.h2c_data      <> io.h2c_data
    hotloading.io.h2c_data.valid := io.h2c_data.valid
    hotloading.io.h2c_data.bits  := io.h2c_data.bits
    io.h2c_data.ready := hotloading.io.h2c_data.ready
    

    /*end*/
   

    // //imem inf /*writ code here*/
    mini_core.io.imem_addr      := hotloading.io.imem_addr // 连接到 mini_core 的某个状态信号
    mini_core.io.imem_wr_en     := hotloading.io.imem_wr_en // 这个信号由测试逻辑或顶层逻辑控制
    mini_core.io.imem_musk      := hotloading.io.imem_musk     // 同上，由测试/顶层逻辑控制
    mini_core.io.imem_data_in   := hotloading.io.imem_data_in     // 同上，由测试/顶层逻辑控制

    mini_core.io.vrt_update <> hotloading.io.vrt_update
    io.vrt_hit := mini_core.io.vrt_hit
    io.vrt_full := mini_core.io.vrt_full

    mini_core.io.pkg_type_to_cc := DontCare
    mini_core.io.user_header_len := DontCare
    mini_core.io.user_table_size := DontCare
    mini_core.io.has_event_wr := io.has_event_wr
    io.has_event_rd := mini_core.io.has_event_rd
    io.event_recv_cnt := mini_core.io.event_recv_cnt
    io.event_processed_cnt := mini_core.io.event_processed_cnt
    io.event_count := mini_core.io.event_count
    mini_core.io.event_type := DontCare
    mini_core.io.user_csr_wr := VecInit(Seq.fill(32)(0.U(32.W)))
    mini_core.io.user_csr_rd := DontCare

    mini_core.io.host := DontCare
    mini_core.io.nasti := DontCare
    mini_core.io.rdma_print_addr := DontCare
    mini_core.io.rdma_print_string_num := DontCare
    mini_core.io.rdma_print_string_len := DontCare
    mini_core.io.rdma_trap := DontCare


}
