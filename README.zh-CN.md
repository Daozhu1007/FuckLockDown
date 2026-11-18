# LockDown Browser 进程策略启动器

**Respondus LockDown Browser 2.1.6.03（x64）** 的版本锁定伴随启动器：删除 *"You must close the following application before starting LockDown Browser"*（必须先关闭以下程序）提醒及其两条击杀路径——**不改动磁盘上的浏览器，也不写任何可执行内存页**。

**[English README](README.md)**

## 它做什么

LockDown Browser 内置约 1,166 条进程黑名单（Iris 等护眼软件、ToDesk、向日葵、TeamViewer、壁纸工具……）：启动时弹"必须关闭"框并击杀命中进程；选完学校服务器后还会按定时器**无声清扫**后台进程。本启动器**完整保留**浏览器的考试环境完整性（反切换看门狗、防篡改自检、事件上报一概不动），只中和进程黑名单行为：

| 浏览器行为 | 用本启动器 |
|---|---|
| 启动"必须关闭以下程序"弹框 | 永不出现 |
| 启动黑名单击杀 | 永不发生 |
| 选服后的周期静默清扫 | 永不武装 |

## 原理（两处机制，全部只写私有堆数据）

1. **启动规则表**：浏览器启动数秒后在私有堆解密出 1,166 条规则的进程表。启动器轮询定位该表（四个已知显示名锚定 + 可写堆区校验），短暂挂起子进程，把全部 2,830 个匹配串清零后恢复——启动扫描从此匹配不到任何东西。
2. **周期扫描门卫**：选完服务器约 2 秒后，浏览器通过置位一个 4 字节标志（`state+0xf388`）一次性武装周期清扫。启动器以 250ms 轮询，在武装当刻将其清零（日志记录 `periodic_scan_gate_cleared`），清扫永不运行。

不写任何代码页。[rewrite/dist/patch-plan.json](rewrite/dist/patch-plan.json) 中保留的 15 处 `.text` 补丁字节仅作活体版本指纹，运行时从不写入。

## 验证（2026-11-18，QEMU/Win11 实验室 + 真机）

- 生产构建 VM 验收：自动选服 → `policy_data_verified`(1166/2830) → `policy_activated` → `periodic_scan_gate_cleared{armed:1}`，168 个采样 × 4 个黑名单诱饵**零死亡**，浏览器全程健康（全部证据在 [rewrite/lab/reports](rewrite/lab/reports)）。
- 同条件未改写原版对照：t≈22s 弹出关闭框、点击 Continue 后杀死 4 个诱饵中的 3 个（[control-9aff7cd855d9-result.json](rewrite/lab/reports/control-9aff7cd855d9-result.json)）。
- 真机：`%LOCALAPPDATA%\ProcessPolicyRewrite\logs` 可见 `policy_activated`、`periodic_scan_gate_cleared`、干净退出码 0；用户的护眼软件首次在 LockDown 启动后存活。

已知开放边界（如实记录）：存在第三条**间歇性**击杀路径，发生在选服之前（真机观察到一次，启动后 <10 秒）。它按**行为**（显示操纵）而非名字触发——惰性同名诱饵在实验室 120+ 秒存活。调查进行中，见 [rewrite/RESUME-STATUS-2026-11-18.md](rewrite/RESUME-STATUS-2026-11-18.md)。

## 使用

1. 安装原版 LockDown Browser **2.1.6.03 x64**（从你所在学校的下载渠道）。其他版本（如 2.1.3.08 x86）会被有意拒绝。
2. 运行 `VerifyVersion.exe`（只读校验）——应输出 `verified=true`。
3. 右键**以管理员身份运行** `LockDownBrowser.NoProcessGate.exe`。它会拉起真正的浏览器并驻留维护两处机制；浏览器参数（如 `rldb:...` 链接）原样转发。
4. 可选：`Register-Protocol.ps1` 把 `rldb:` 链接交给本启动器（支持 `-WhatIf` / `-Restore`）。

日志：`%LOCALAPPDATA%\ProcessPolicyRewrite\logs`（仅记录启动器事件，不记录 URL 或浏览器参数）。

## 构建与测试

```powershell
python build.py                                    # 使用系统自带 .NET Framework x64 编译器
python -m unittest discover -s tests -p "test_*.py" # 17/17 通过
```

构建辅助需要 `pefile`。源码：[rewrite/src](rewrite/src)。

## 范围与非目标

- 本项目解决的是**让无害后台软件与 LockDown Browser 共存**（护眼、输入、壁纸工具……）。它**不**移除或绕过任何考试完整性控制：反切换看门狗、代码完整性自检、安全事件上报、考试锁屏边界全部原样保留、照常工作。
- 仅支持 2.1.6.03 x64（精确 SHA-256）；版本门卫是特性不是缺陷。
- 与 Respondus 无隶属、无合作、无背书。仅供互操作与教育用途；使用请遵守你所在机构的规定。

## 仓库结构

```
rewrite/
  dist/        启动器 + 校验器 + 计划 + 协议注册脚本
  src/         C# 源码（ProcessPolicyLauncher.cs、PolicyData.cs 等）
  plans/       版本锁定的字节指纹
  tests/       集成与发现测试（自建无害夹具）
  lab/         QEMU 实验室工具链、guest 脚本与全部实验证据
  README.md     技术深潜文档（中文）
```

## 许可

MIT——见 [LICENSE](LICENSE)。本仓库不含任何 Respondus 二进制或派生转储；用户需从自己学校获取原版安装包。
