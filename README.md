# vimem-baseline

`baseline` 是 [vimem](https://github.com/lbx1282/vimem)（core4nic）的对照 / 简化工程，
用于 slicer RX 时延测量与 hotloading 验证。

## ⚠️ clone 本仓库前，必须先 clone vimem

本仓库根目录下的 **`cmac` / `hbm` / `qdma` 是指向 vimem（core4nic）的软链接**，
不是真实目录，所以**没有被提交进本仓库**（已在 `.gitignore` 里忽略）：

```
cmac -> /home/lbx/core4nic/cmac
hbm  -> /home/lbx/core4nic/hbm
qdma -> /home/lbx/core4nic/qdma
```

`build.sc` 中 `moduleDeps = Seq(common, generator, qdma, hbm, cmac)`，缺少这三个目录
`mill` 编译会直接失败。**因此 clone 顺序必须是：先 vimem，再本仓库，最后重建软链。**

### 1) 先 clone vimem 到 /home/lbx/core4nic

```bash
git clone git@github.com:lbx1282/vimem.git /home/lbx/core4nic
cd /home/lbx/core4nic
git submodule update --init --recursive    # vimem 的 core 是 submodule
```

### 2) 再 clone 本仓库

```bash
git clone git@github.com:lbx1282/vimem-baseline.git /home/lbx/baseline
cd /home/lbx/baseline
```

### 3) 重建三个软链接（关键步骤）

```bash
ln -s /home/lbx/core4nic/cmac cmac
ln -s /home/lbx/core4nic/hbm  hbm
ln -s /home/lbx/core4nic/qdma qdma
```

> 若 vimem 不在 `/home/lbx/core4nic`，把软链指向它的实际路径即可。

### 4) 编译 / 生成 Verilog

```bash
cd /home/lbx/baseline
~/.cache/mill/download/0.11.9 mini.compile
~/.cache/mill/download/0.11.9 mini.runMain mini.elaborate MiniCoreTop
# 产物：Verilog/MiniCoreTop.sv
```

## 目录结构

| 路径 | 说明 |
| --- | --- |
| `cmac` `hbm` `qdma` | **软链到 vimem（core4nic）**，共用模块，未提交 |
| `common` `core` `generator` | 本仓库自己的源码 |
| `build.sc` | mill 构建配置 |
| `Verilog/` `out/` `gen/` `results/` `.Xil/` | 生成产物，已 ignore |
| `postElaborating.py` `create_vivado_project.tcl` `run_vivado_sim.tcl` | 生成 / 仿真脚本 |

## 本仓库相对 vimem 的主要改动

- `core/src/foo/SlicerRxLatency.scala` —— 每包时延采集 + `latency_bucket` 直方图（1024 桶 × 32 拍）
- `core/src/foo/MiniCoreTop.scala` —— 例化 `SlicerRxLatency`；`CMACTop(TX_DELAY_CYCLES = 300)`
  （1.5µs TX 延迟线，模拟网络 / 交换机时延）；payload 长度校验打一拍
- 注：`AxisCycleDelay` 延迟线与 `TX_DELAY_CYCLES` 参数加在**共享的
  `cmac/src/CMACTop.scala`**（即 vimem / core4nic 里那一份），不在本仓库内。
