# v3 研究：第三 kill 路径的扩展去除尝试与实测边界

日期：2026-11-18/19（Asia/Shanghai）。对象：本仓库锁定的 LockDown Browser 2.1.6.03 x64
（SHA-256 `635ea16e…aab0582`）。全部动态证据来自 QEMU 实验室（`lab/reports/`），全部静态
证据来自 `analysis/lockdown-2.1.6.03/` 的既有产物；证据规则与既有档案一致。

## 一句话结论

**v2 的纯堆数据方案（B1 规则表清零 + B3 周期门卫）保持为生产机制；对第三 kill 路径的
.rdata 匹配串中和方案在实验室被完整尝试并证伪——原版对检测针串区设有区域级镜像自检，
且 α 名字串的腐蚀致死性随浏览器自身状态漂移。v2.1 交付 = v2 行为（零 neutre）+ 全套
经单测的机器能力 + 本文档的完整证据链。**

## 静态定位（本轮核验，全部与 REA 产物对齐）

| 路径 | 函数 | 数据来源 | 消费者（xref 排他性） |
|---|---|---|---|
| α 扩展黑名单 | `0x14022b1b0`（调用链 `0x14016d200`→`0x14016ecf9`） | 7 个硬编码名 `.rdata` 直引 + `process.list` 配置键（`0x140b45700`，与 `0x14023aee0` 规则加载器共享）+ 进程快照（`[global+0xb08]`）+ PID 数组（state+0xf380 对象 +0x2008） | 名字串仅 α 引用；键串另被环境信息对话框 `0x140135140` 引用（外观性共享） |
| β 窗口类名 timer | `0x140245530`（无直接调用者） | 21 个 `.rdata` 类名/标题直引 + 4 个解密表 ID（0xad4/0xa92/0xaa8/0xabe，移屏管理）+ 0xe70（恢复窗口） | 全部仅 β 引用；XLMAIN/OpusApp 另有 2 个 Office 谓词消费者（同属 Office 击杀机制） |
| γ WMI 无线显示 | `0x140262690`（无直接调用者） | WQL `.rdata`（UTF-16）+ 'Wireless display toolbar' 窗口标题 | 仅 γ 引用 |
| PTC4 远程服务 | `0x140261340`（无直接调用者） | 8 个服务名 `.rdata` 直引 | 仅 PTC4 引用 |

击杀收敛：α → `0x140225cb0` 对话框包装（`0x14022cf69` 调用点）与内联 `TerminateProcess`
（`0x14022bd57`）；β → `0x1402538b0`（PACE 混淆，日志字面量锚定）；γ → `0x14026378e`；
PTC4 → `0x140227950`。**分支分类**（β asm 逐段核验）：击杀=XLMAIN/OpusApp/AutoHotkeyGUI/
`Save a`/`Select File`/StickyKeys/`Sticky Keys`/`Power Options`/`Message` 组/`Wireless display
toolbar`；取消= `Print`（WM_COMMAND）；**非击杀**（排除中和）=Credential Dialog 提升分支、
`Connect to `+`Password` 提升分支、Shell_SecondaryTrayWnd（任务栏管理）、4 个表 ID 串
（移屏）。IFEO utilman 为无条件 `RegDeleteKeyExA` 清理（锁定防御，非击杀），同样排除。

## 对照实验（第三路径首次在 VM 复现）

诱饵组（对齐锚点）：`WUDFHost.exe`（命令行含 MiraCast）、`Spyrix Monitor.exe`、
`ReadAndWrite.exe`、`SelfService.exe`（命令行含 Citrix Workspace）+ XLMAIN/AutoHotkeyGUI
类与 Sticky Keys/Print/Power Options/Wireless display toolbar 标题窗口 + `EFRService` 服务。

| 观察 | 证据 |
|---|---|
| 选服后 ~3s 弹出 "You must close the following application before starting LockDown Browser"（α 的 ProcessCloseDlg 路径），保持 2 分钟未点击时诱饵存活 | `thirdpath-repro-partial.json` + ui-events（`lab/guest/ThirdPathRepro3.ps1` + `lab/ui_cadence.py`） |
| 点击 "Close Application and Continue" 后整个 guest 会话楔死（agent 心跳、队列、采样同时停止，屏幕黑）——原版选服后处置动作杀伤会话关键进程的直接足迹 | `heartbeat.json` 停更于点击时刻；`thirdpath-repro-rerun.png` |
| 无选服（脚本盲区时代）+ 诱饵 → 无弹框无击杀：弹框与选服因果绑定 | `thirdpath-repro.json`（前两轮） |

UI 驱动注记：分离隐藏 PS 的 EnumWindows 在诱饵在场时不可见 Choose Server（机制未定），
选服改由 agent 侧命令驱动（`lab/ui_cadence.py`，已两次实证）。早前把 XLMAIN 被隐藏归因
β 是**伪影**——隐藏启动进程的首窗口首次 ShowWindow 无视参数改用 STARTUPINFO 的 SW_HIDE
（经典 Windows 行为），已在 `DecoyWindowsHost.ps1` 修复（二次 ShowWindow）。

## 消融矩阵（五轮，全部 trace 判定）

1. **matrix（时机）**：`--no-data-neutres` 45s 存活（v2 等价基线）；31 串恢复前写入死
   （exit 1 ~5s）；`--data-neuter-timing activation`（+3.5s）同样死。
2. **matrix2（分组）**：keep-alpha（8 串含键串）**真存活 40s**（跑满窗口、无 error/exit）；
   keep-beta / keep-gamma / keep-ptc4 各自单独死。
3. **matrix3（单串）**：β/γ/PTC4 区域内**任何单串**（含 1 条 WQL、1 条标题）单独致死 →
   区域级镜像自检（同页 α 块豁免：0x140b45700..458ec 不在受保护区）。
4. **matrix4（状态消融，VM 重启后）**：no-neutres 存活；7 名字串 / 8 含键串全部死；
   skip-key 的"存活"经复核为 error 提前 break 的假阳性。结合 matrix2：**α 名字串的致死性
   随浏览器状态成熟（选服记忆→自动启动流程）出现，且跨 VM 重启持续**——同配置 24 分钟
   前存活、后死亡。
5. **matrix4-扩展（键串归因）**：键串在自动启动流程启动期配置读取中被消费，腐蚀即
   exit 1；名字串在部分状态存活、当前状态死。

生产判据：**一个周二可用、周三杀掉用户考试会话的机制不合格。** v2.1 生产计划
`dataNeutres` 置空（`plans/generate_data_neutres.py` 保留全部 31 个已试条目与逐条测量
结论）。

## v2.1 交付形态

- **dist/LockDownBrowser.NoProcessGate.exe = v2 行为 + 中和机器**：preflight 对 neutre
  的字节级校验与"拒绝可执行节"守卫、幂等远程写入（`src/ImageDataNeutralizer.cs`）、
  实验构建的 `--data-neutres-keep/--data-neutres-skip/--data-neuter-timing` 消融旗标，
  全部保留且经夹具端到端测试（夹具标记串内存腐蚀 + 磁盘不变断言）。
- `VerifyVersion` 报告 `neutreCount:0`；`tests/test_data_neutres.py` 断言空集与测量依据。
- 19 项单测全过（1 项在空集下正确跳过）。

## 残留地图（本轮实测边界）

| 未覆盖面 | 性质 | 对常见后台软件的威胁 |
|---|---|---|
| β 窗口击杀（XLMAIN/AutoHotkeyGUI/Sticky Keys/Print 等） | 针串区被自检保护，纯数据不可去 | 低：目标是考试作弊类窗口 |
| γ WMI 无线显示（WUDFHost+MiraCast） | 同上 | 低：仅无线显示环境 |
| PTC4 远程管理服务名单 | 同上 | 低：仅特定远程组件 |
| α 硬编码名（Spyrix/Citrix/WUDFHost 等） | 状态依赖致死，不可靠 | 低：名单均为特定产品 |
| α 机构配置 `process.list`、B11 `<hackfiles>` | 配置驱动；默认 profile 无实例 | 取决于机构 profile |
| B10/C2 | 宿主零 xref（未索引代码） | 未定 |

## 后续选项（未实施，含风险）

- 迟到时序（+15s）写入：自检若为一次性早期检查或可绕过，但自动启动流程在 +2-5s 已跑
  α，覆盖无效；且未测自检是否周期性。
- 失败重试模式（child exit 1 → 免中和重启子进程）：CEF 单实例孤儿锁与"只碰自己 PID"
  安全契约冲突，风险高于收益。
- 驱动层/外部拦截：超出纯数据契约，另行立项。

## 实验方法学新增（复跑必读）

- 分离脚本 UI 盲区：选服等 UI 驱动一律走 agent 侧命令节奏（`lab/ui_cadence.py`）。
- launcher TraceLog 为 `FileMode.CreateNew`：**每次运行必须新日志名**（已改 guest 脚本为
  guid 名）。
- `sc.exe delete` 可无限挂起：guest 脚本避免服务型诱饵或在作业中限时。
- 隐藏启动进程首窗口 ShowWindow 陷阱（见上）；`$Args` 为 PS 自动变量，不可作参数名。
- 判定一律以 launcher trace 为准（child_exit/error 事件），分离脚本的进程名查询不可靠。
