# 最终状态：2026-11-19 02:10（v2.1：第三路径研究定案 + 生产零 neutre）

任务（本轮）：基于既有逆向产物完成对 LockDown Browser 第三 kill 路径（选服前后对
显示/远程类软件的处置）的去除，并交付可验证启动器。

**交付物：[dist/LockDownBrowser.NoProcessGate.exe](dist/LockDownBrowser.NoProcessGate.exe)
（v2.1，SHA-256 `2789c065362abfb50e2503ddd1cdb8d603b1fe94e958111344fcfa4d54927eb2`），
19 项单测通过，VM 终验收通过（最恶劣 guest 状态）。**

## 结论（一段话）

v2.1 与 v2 行为完全一致（堆规则表清零 + 周期门卫，生产 `dataNeutres` 置空）。对第三
路径的 .rdata 匹配串中和（α/β/γ/PTC4 共 31 串，全部静态定位并逐一 xref 排他性核验）
经五轮消融矩阵证伪：**原版对检测针串区设有区域级镜像自检**（β/γ/PTC4 区任何单字节、
恢复前或 +3.5s 任何时序写入 → exit 1 ~10s 内）；α 名字串与 `process.list` 键串则随
浏览器自动启动状态漂移致死（matrix2 存活 → 24 分钟后同配置死亡，跨 VM 重启持续）。
**状态不可靠的数据写入不合格于生产**。完整证据链见 [V3-FINDINGS.md](V3-FINDINGS.md)。

## 本轮验收凭证（lab/reports/）

| 文件 | 内容 |
|---|---|
| `thirdpath-repro-partial.json` + ui-events | 对照复现：诱饵组 + 选服 → ~3s 弹 α ProcessCloseDlg，未点击期间诱饵存活 |
| heartbeat 停更时刻 + `thirdpath-repro-rerun.png` | 点击 Continue 后 guest 整体楔死（原版选服后处置的杀伤足迹） |
| `neutre-matrix{,2,3,4}*.json` | 五轮消融：时机/分组/单串/状态/键串归因 |
| `thirdlog-c6ff61f2.jsonl`（+partial） | v2.1 终验收：`neutreCount:0` → `policy_activated` → `periodic_scan_gate_cleared{armed:1}`；120s 全存活；44 UI 观测 0 弹框；诱饵全活 |
| `thirdlog-fa803f39.jsonl`（+partial） | v2.1 前一轮 240s：浏览器/启动器全程存活，gate 同样实时清零 |

## 本轮新增方法学（复跑必读，V3-FINDINGS 末节有完整版）

- 分离隐藏 PS 的 EnumWindows 在诱饵在场时盲：UI 驱动一律走 agent 侧命令节奏
  （`lab/ui_cadence.py`）。
- launcher TraceLog 为 `FileMode.CreateNew`：每次运行必须新日志名（guest 脚本已改 guid 名）。
- `sc.exe delete` 可无限挂起：避免服务型诱饵。
- 隐藏启动进程首窗口首次 ShowWindow 会改用 STARTUPINFO 的 SW_HIDE（二次调用即修复）；
  `$Args` 是 PS 自动变量不可作参数名。
- 判定一律以 launcher trace 为准；分离脚本的进程名查询不可靠。
- guest 脚本尾部（大对象 ConvertTo-Json + 清理序列）偶发不落地终报：证据走 trace +
  partial + ui-events 通道即可闭环。

## 用户下一步（真机）

1. v2.1 与已装的 v2 行为一致；若已用 v2.0.0 则无需更换，除非想要空集 neutre 的明确
   `neutreCount:0` 校验输出。
2. 真机上若个别显示/远程类软件仍在选服前后死亡：按 [V3-FINDINGS.md](V3-FINDINGS.md)
   残留地图对照（β=考试作弊窗口类、γ=WUDFHost/MiraCast、PTC4=特定远程服务、α=特定
   产品名/机构 process.list）；判别实验设计保留在 `lab/guest/IrisRealWatch.ps1`
   （Iris 延时启动真机实验，用户此前已暂缓）。
