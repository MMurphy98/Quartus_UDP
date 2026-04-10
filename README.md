# eth_pc_loop (Quartus Project)

这是一个基于 Intel Quartus 的 FPGA 以太网/UDP 回环与 SDRAM 读写测试工程。

核心目标：
- PC 通过 UDP 将随机 `int32` 数据发送到 FPGA，写入 SDRAM
- FPGA 从 SDRAM 回读数据并通过 UDP 返回 PC
- MATLAB 脚本对回传数据进行完整性比较，并可导出错误列表

## 项目结构

```text
.
├─ eth_pc_loop.qpf / eth_pc_loop.qsf    # Quartus 工程与配置
├─ async_fifo_2048x32b.v                # FIFO 相关模块
├─ rtl/                                 # RTL 源码目录
├─ db/ incremental_db/ output_files/    # Quartus 编译数据库与输出
├─ udp_test_assistant.m                 # MATLAB UDP 测试脚本
├─ MATLAB.md                            # MATLAB 脚本逐行说明（含流程图）
└─ send.mat / stp2.stp / 其他工程文件
```

## 环境要求

- Windows（已在该环境下开发）
- Intel Quartus（与本工程版本兼容）
- MATLAB（支持 `udpport` 接口，推荐较新版本）
- FPGA 开发板（网口可用，SDRAM 控制逻辑可用）

## MATLAB 测试脚本说明

脚本文件：`udp_test_assistant.m`

功能命令：
- `send`：发送 `flag + payload + padding` 到 FPGA
- `read`：发送 `READ` 指令，接收 FPGA 回传数据并比较
- `quit`：关闭 UDP 对象并退出

详细逐行解释与 Mermaid 流程图见：`MATLAB.md`

## 快速开始

1. 打开 Quartus 工程并完成编译：
   - `eth_pc_loop.qpf`
2. 下载 bitstream 到 FPGA，确认网口链路正常。
3. 根据你的网络环境修改 `udp_test_assistant.m` 中 IP/端口：
   - `local_ip`
   - `target_ip`
4. 在 MATLAB 命令行运行：

```matlab
udp_test_assistant
```

5. 按提示输入待传输的 `int32` 数量，并使用：
   - `send`
   - `read`
   - `quit`

## 数据协议要点

- 发送端按 `int32` 组织数据：`FLAG(0x7FFFFFFF) + payload + zero padding`
- 发送分组逻辑按 128 个 `int32` 对齐
- 回读路径中单包按 RTL 协议解析（包含包序号和数据区）
- 脚本内置 flag 与端序兼容检查（含反序 flag 诊断）

## 常见问题

- 修改传输长度后，建议先 `quit` 再重启脚本，避免 `persistent` 状态干扰。
- 回传不完整时，会输出接收统计与局部比较结果。
- 发现错误后可导出 `error_list_时间戳.xlsx` 进行离线分析。

## 许可证

当前仓库未附带许可证文件。如需开源发布，建议补充 `LICENSE`（例如 MIT/BSD/GPL）。
