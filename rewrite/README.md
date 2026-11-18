# LockDown Browser 2.1.6.03：进程关闭提示的改写（heap 规则表激活）

本实现保留用户提供的原版浏览器主体，在新建主进程启动后，**清空其私有堆内进程规则表的全部匹配串**（1166 条规则、2830 个字符串，首次观测于启动后约 7 秒），使进程扫描永远匹配不到任何"需要关闭的程序"。**不修改任何可执行内存页**，因此不与原版的代码完整性自检发生任何接触；原版磁盘文件、CEF、LMS 适配与驱动均保持原样。

可运行文件：[LockDownBrowser.NoProcessGate.exe](dist/LockDownBrowser.NoProcessGate.exe)（SHA-256 `12f8d8364b3804bf191a07ce2a296256821d61c7dd60ebf67e294b4ea537ff64`）。它与原版一样需要管理员权限。启动后创建原版主进程，完成版本及远程字节校验（十五处补丁字节作为活体版本指纹），恢复执行后轮询规则表，出现即挂起→清空→恢复，并持续监视直至浏览器退出：

1. **启动规则表**（约 +1.6 秒解密出 1166 条规则）——清空全部 2830 个匹配串，删除"必须关闭以下程序"弹框及其启动击杀；
2. **周期扫描门卫**——会话建立（选完服务器）后浏览器会一次性置位 state+0xf388 武装周期进程扫描（实测约 2.3 秒后开始击杀，Iris、向日葵、ToDesk 等皆死于此路径）；门卫在武装当刻将其清零（启动器自身日志记录 `periodic_scan_gate_cleared`），此后扫描永不运行。

两处均为私有堆数据写入，不改任何可执行内存页。激活前失败终止本次子进程；激活后观测异常只记录、不杀浏览器。

## 与代码补丁路线的关系

先前路线在新建进程内存中改写十五处、七十六字节（[patch-plan.json](dist/patch-plan.json) 保留全部定义与静态依据）。该路线在虚拟机内验证时发现两个问题：

- 在 LOCKDOWNCHROME 窗口出现时打补丁，浏览器恢复后约 68 毫秒自行退出；
- 推迟到可见 CEFCLIENT 窗口打补丁，浏览器越过 Choose Server 后约 2.5–4 秒以 exit 1 自行退出。

而原版（未打补丁）在同条件下会继续走到 Canvas 登录页并在 60 秒全程存活。判别实验（`lab/candidates/private-heap-policy/PolicyDataExperiment.exe`，完全不碰可执行内存）给出了答案：清空规则串后，浏览器**不弹框、不杀进程、走到 Canvas、存活至少 7.5 分钟**（最终由实验者主动的切换手势触发浏览器自身的"报告并关闭"路径终止，终止时刻与操作时间完全吻合，NT 验证见 trace）。因此正式版切换为 heap 规则表激活；十五处补丁保留在计划中仅作版本指纹与静态参考，运行时不写入。

## 行为对照（QEMU/Win11 实验虚拟机，真实 MSI 安装）

| 场景 | 原版（未改写） | 改写版（清规则串） |
|---|---|---|
| 4 个黑名单进程（deskpins/sidebar/msmsgs/synergy 改名 cmd） | 约 22 秒弹 "You must close the following application before starting LockDown Browser: Windows Sidebar (sidebar.exe)"（标题 LockDown Browser - Version 2.1.6.03，按钮 Close Application and Continue / Exit LockDown Browser）；点击 Continue 后当场杀死 4 个触发进程中的 3 个；浏览器存活至 60 秒窗口结束 | 全程无任何关闭程序提示；4 个进程全部存活；浏览器走到 Canvas 登录页（"Connecting to CANVAS"）；存活至少 7.5 分钟 |
| 无黑名单进程 | 走到 Canvas 登录页 | 同点位（截图同帧比对） |

凭证：`lab/reports/control-9aff7cd855d9-result.json`（原版点击框全程逐字记录）、`acceptance-d99896a4fbfc479ea567e04cbddd1d4c-trace.json`（改写版 launcher 事件）、`lab/reports/php-patched-*.png`、`ctrl-clean-*.png`、`ctrl-click-*.png`（画面凭证，已由独立视觉模型逐字核验历史截图）。

虚拟机环境自身的残留现象与改写无关：原版在部分运行中也会弹 "Authorization Error — LockDown Browser cannot run because it is corrupted. Please try reinstalling the product."（多模态模型对 `recovery*.png`/`close-check.png` 及未改写基线截图的逐字核验确认该框叠在完整渲染的 Canvas 登录页之上）。该现象属于实验虚拟机环境，未见于任何与改写相关的因果链。

## 使用

需要先通过用户提供的安装包安装原版 2.1.6.03。默认路径 `C:\Program Files\Respondus\LockDown Browser\LockDownBrowser.exe`（也支持 Program Files (x86) 与 App Paths 自动发现）。改写启动器可放在其他目录。

```powershell
.\dist\VerifyVersion.exe                       # 只读校验安装的原版（精确 SHA-256/PE/十五处预期字节）
.\dist\VerifyVersion.exe --exe 'D:\path\to\LockDownBrowser.exe'
.\dist\LockDownBrowser.NoProcessGate.exe       # 正常启动（可转发原版参数，如 -- 'rldb:...')
```

支持的 SHA-256 是 `635ea16e065539f2169121c8666be4095d7c7ab1eeeaad5e21ba73a84aab0582`（2.1.6.03 AMD64）。让 `rldb:` 链接交给该启动器可运行 [Register-Protocol.ps1](dist/Register-Protocol.ps1)（支持 `-WhatIf`/`-Restore`）。

日志在 `%LOCALAPPDATA%\ProcessPolicyRewrite\logs`，记录校验、`policy_data_verified`（规则数/字符串数/表地址/`executableMemoryChanged:false`）、`policy_activated` 与浏览器退出码；不记录启动 URL 或浏览器参数。

## 正式构建的同条件验收（2026-11-18，已通过）

### v2（heap 规则表 + 周期扫描门卫，12f8d836…）

经 `/artifact` 通道下载并哈希校验后完成验收（`lab/reports/acceptance-a6c15af98dac4c5380a0e60fc4652929-*.json`）：

- 选服自动完成（t=8.0s），**无任何弹框**（processPromptObserved=false）；
- 启动器事件链：`policy_data_verified`(1166/2830, +1.6s) → `policy_activated` → **`periodic_scan_gate_cleared {armed:1}`**（t≈9.5s，门卫在生产构建内亲自击落武装位）；
- 168 个采样 × 4 个黑名单诱饵（含第二目录成员 DeskPins/Synergy 系）**全部存活至窗口结束**，浏览器全程健康。

对照原版点击框行为（`control-9aff7cd855d9-result.json`）：同条件 t≈22.4s 弹 ProcessCloseDlg、点击 Continue 后杀 3/4。判别链证据：hunter v5（`hunter6-summary.json`）——不干预则武装后 ~2.3s 击杀 IrisPortable/sunloginclient 诱饵；干预则 240 秒零死亡。

### v1（仅 heap 规则表，8d42637…）

三路凭证互相印证：

- **launcher trace**（`lab/reports/acceptance-689e843e0eb647e1a8159c7952a6caed-trace.json`）：
  `preflight`（15 处字节指纹，status "heap rule-table activation"）→ `child_created_suspended` →
  `policy_data_verified`（1166 规则 / 2830 字符串 / executableMemoryChanged=false，创建后约 2.6 秒）→
  `policy_activated` → 7 分 16 秒后 `child_exit code 0`（退出时刻与实验者主动的切换手势完全吻合，非任何完整性检查）。
- **观察者 60 秒全程采样**（`lab/reports/watch-final-partial.json`，111 个采样）：4 个黑名单触发进程
  **每一个采样点都存活**；浏览器与启动器全程存活；除 Choose Server 外**没有任何 #32770 对话框出现**
  （ProcessCloseDlg 若出现会被逐字捕获）。
- **画面凭证**（`final-patched-mid.png` 14:59:10、`final-patched-end.png` 15:00:21）：浏览器越过选服务器后
  稳定停在 Canvas 登录页，两帧相隔 70 秒，无任何提示框。

对照原版行为（`control-9aff7cd855d9-result.json`）：同条件下 t≈22.4 秒弹 ProcessCloseDlg，点击 Continue 后
杀死 4 个触发进程中的 3 个。**"不提醒、不杀程序"的目标功能在生产构建上成立。**

## 已知边界

- 用户宿主机安装的是 2.1.3.08 x86，不受本版本支持（固定哈希保护是特性不是缺陷：取消检查不等于版本适配）。
- 实验虚拟机内请勿挂载任何光驱：附加 IDE 光驱会暴露虚拟机特征，导致原版 VM 检测拦截（`lab/lab.py` 已将 tools 投递盘改为 `--attach-tools` 可选项）。实验脚本的长程收尾路径存在偶发挂死（今日 4 例中 3 例），已用"分离执行 + 增量上传"模式绕开（`lab/guest/WatchFinal.ps1`、`lab/enqueue_watcher.py`），不影响本验收结论。
- 定时扫描与完整考试会话的兼容性仍以真实使用为准；虚拟机内未做考试登录。

## 构建与测试

```powershell
python .\build.py
python -m unittest discover -s .\tests -p 'test_*.py' -v
```

本机构建使用系统自带 .NET Framework x64 编译器（无需 .NET SDK），Python 构建辅助需要 pefile。2026-11-18 构建：17 项测试全部通过（5 项自建无害宿主集成、7 项启动时序、5 项路径发现）。

源码：[ProcessPolicyLauncher.cs](src/ProcessPolicyLauncher.cs)（主流程与激活分支）、[PolicyData.cs](src/PolicyData.cs)（规则表观测/清空/监视）、[BrowserReadiness.cs](src/BrowserReadiness.cs)、[TargetDiscovery.cs](src/TargetDiscovery.cs)。原版字节分析的完整材料（含对原版二进制的静态解析转储）不属于本公开仓库。
