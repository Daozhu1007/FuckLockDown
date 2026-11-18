# rewrite 现存产物复审

日期：2026-11-17，Asia/Shanghai。审查对象为本次开始时保留的源码、dist 和既有实验记录；不覆盖之前的审查。

**结论：现存产物有实质修复，但仍不能按“重写 LockDown Browser，并删除启动时要求关闭其他程序的功能”验收完成。**

需要区分两件事：交付形态仍然是依赖原版的内存补丁启动器，未实现独立浏览器重写；对于用户特别强调的“不再提示关闭程序”，源码已有针对性实现，但当前正式 EXE 尚缺有效的修改后行为验证。不能把“尚未证明可用”写成“本次已实测失败”，也不能继续照搬旧审查中已过时的事实。

## 上次看不到的后续工作，文件能确认到哪里

| 本地文件时间 | 现存结果 | 能证明的范围 |
|---|---|---|
| 05:58 | 新增 TargetDiscovery.cs 和六项发现/诊断测试 | 支持从两种 Program Files 目录、App Paths 和卸载注册信息中寻找匹配的原版；版本不符时给出版本、架构及哈希诊断。 |
| 06:03 | 新增进程规则及启动可达性分析 | 识别了 Choose Server 之后的初始扫描，以及触发程序的不同策略标志。它是静态分析材料。 |
| 06:05 | 新原版正对照完成 | 选择服务器后确实出现 Windows Sidebar 关闭提示，补上了原版正例。 |
| 06:05–06:06 | 新增 BrowserReadiness.cs，修改启动器和计划，重编译 dist | 正式版改为等待 LOCKDOWNCHROME 窗口后挂起进程、写入补丁、恢复进程；VM 字符串改写移入实验编译条件。 |

这些文件支持“已经继续修实现并重编译”的判断。现存目录中没有随后用该正式版完成相同场景对照的记录，因此不能推断当时已经完成最终验收。文件时间不代表完整操作历史。

## 旧审查哪些结论已经变化

| 旧审查问题 | 当前状态 |
|---|---|
| 默认路径只认 Program Files | **已修复发现逻辑。** 本次默认运行只读校验器，确实找到了 Program Files (x86) 内的旧版。 |
| 用户安装的是 2.1.3.08 x86，计划只支持 2.1.6.03 x64 | **仍然成立。** 发现路径并不等于兼容旧版；本机默认校验仍退出 1。 |
| 正式版仍在第一次 ResumeThread 前立即打补丁 | **已变化。** 当前正式版默认使用 startup 模式，不能继续据旧时序断言它必然早退。 |
| 原版从未触发目标关闭提示 | **已补上正例。** 新记录选择服务器后出现目标提示；仍缺当前正式版的对应反例。 |
| VM 字符串改写混在正式行为中 | **已修复隔离。** 正式 EXE 中没有 ResourceNeutralizer 类型，调用也已处于实验条件内。 |
| 交付是原版补丁启动器，非独立重写 | **没有变化。** |

源码依据：[TargetDiscovery.cs:156](D:/Code/FuckLockDown/rewrite/src/TargetDiscovery.cs:156)、[ProcessPolicyLauncher.cs:733](D:/Code/FuckLockDown/rewrite/src/ProcessPolicyLauncher.cs:733)、[ProcessPolicyLauncher.cs:756](D:/Code/FuckLockDown/rewrite/src/ProcessPolicyLauncher.cs:756)。

## 仍不能验收的主要原因

### 1. 当前正式版没有完成核心功能的同条件对照

新原版记录是 [reply-1794866647916248300-a759407e.json](D:/Code/FuckLockDown/rewrite/lab/reports/reply-1794866647916248300-a759407e.json)。对应 [PositiveControl.ps1:45](D:/Code/FuckLockDown/rewrite/lab/guest/PositiveControl.ps1:45) 启动四个改名 cmd 触发进程，然后直接启动原版并自动选择第一个服务器。

记录中的原版哈希为 `635ea16e065539f2169121c8666be4095d7c7ab1eeeaad5e21ba73a84aab0582`，服务器选项为 Kean Canvas / Kean University Production LMS，实际选择索引 0。80 次采样中，约第 11 秒记录到 Windows Sidebar（sidebar.exe）的“必须关闭应用后继续”提示，按钮为 Close Application and Continue / Exit LockDown Browser。同一时点 deskpins.exe 已不存活，另外三个触发进程仍存活。

这已经是有效的原版正例。但该运行直接执行原版，完成时间早于 06:06:07 生成的当前正式 EXE，不能证明正式版效果。审查所见 lab/reports 中，旧报告之后只有两次原版尝试及一次机器环境查询，没有当前正式启动器的对应运行。

旧 [ComparisonTest2.ps1:123](D:/Code/FuckLockDown/rewrite/lab/guest/ComparisonTest2.ps1:123) 仍使用 ExperimentLauncher.exe --patch-mode delayed，也没有新正对照中的选择服务器步骤。原版静态汇编在 [0x14016d200.asm:521](D:/Code/FuckLockDown/analysis/lockdown-2.1.6.03/rewrite-compatibility/static-assembly/main/0x14016d200.asm:521) 记录服务器模态框调用，在 [第 1449 行](D:/Code/FuckLockDown/analysis/lockdown-2.1.6.03/rewrite-compatibility/static-assembly/main/0x14016d200.asm:1449) 记录后面的初始扫描调用。旧实验停在 Choose Server 并让触发进程保持存活，不能代替越过该步骤后的验证。

注意：positive-control.png 仍属于较早一次被 VM 检测拦住的尝试，不能作为这次 Windows Sidebar 正例的截图。有效的新证据是上述 JSON；便于复核的提取结果见 [positive-control-summary.json](D:/Code/FuckLockDown/rewrite/review-followup-artifacts-2026-11-17/positive-control-summary.json)。

### 2. 新启动时序已经进入正式 EXE，但可靠性未验证

[ProcessPolicyLauncher.cs:737](D:/Code/FuckLockDown/rewrite/src/ProcessPolicyLauncher.cs:737) 先恢复原版主线程，再等待指定窗口，随后挂起整个进程并写入代码补丁。[BrowserReadiness.cs:26](D:/Code/FuckLockDown/rewrite/src/BrowserReadiness.cs:26) 最长等待 60 秒，每轮未找到窗口时休眠 10 毫秒。

新原版记录中，LOCKDOWNCHROME 在约 6.5 秒出现，服务器选择框约 8 秒出现，目标提示约 11 秒出现。这给该方案提供了单次观测上的时序依据；它并不证明该窗口一定晚于所有完整性检查，也不证明所有启动参数、单服务器配置及调度条件下都能先于目标扫描完成补丁。

窗口轮询与后续挂起之间没有让原版等待的同步约定：原版在被观察和挂起之前继续执行。这里存在尚未验证的时序风险；本次没有实际复现它导致失败，因此将其记录为风险和验收缺口，不写成确定发生的故障。

### 3. 当前安装环境仍不能直接运行这份交付

本次执行实际 dist/VerifyVersion.exe 的默认只读校验，程序正确发现：

- 路径：C:\Program Files (x86)\Respondus\LockDown Browser\LockDownBrowser.exe。
- 文件版本：2, 1, 3, 08；架构：x86。
- SHA-256：`a9f5b4918f2dfb0ea654c38713feee6db431e1e07e63a011e611a5ae50854cc3`。
- 结果：退出 1，明确报告与支持的哈希不匹配；没有创建浏览器子进程。

再指定项目中提取的 2.1.6.03 AMD64 原版，校验退出 0，报告 verified=true、patchCount=15。两次结果分别保存在 [本机校验日志](D:/Code/FuckLockDown/rewrite/review-followup-artifacts-2026-11-17/verify-installed.jsonl) 和 [提取原版校验日志](D:/Code/FuckLockDown/rewrite/review-followup-artifacts-2026-11-17/verify-extracted.jsonl)。

因此路径发现已解决，旧版兼容仍未实现；指定提取文件通过静态校验，也不等于该提取目录具备完整的正常运行条件。固定哈希保护应被保留，不能把取消检查当成版本适配。

### 4. 独立重写要求没有实现

[ProcessPolicyLauncher.cs:670](D:/Code/FuckLockDown/rewrite/src/ProcessPolicyLauncher.cs:670) 解析原版路径，[第 699 行](D:/Code/FuckLockDown/rewrite/src/ProcessPolicyLauncher.cs:699) 创建原版进程，[第 843 行](D:/Code/FuckLockDown/rewrite/src/ProcessPolicyLauncher.cs:843) 实现远程内存补丁。52,224 字节的正式 EXE 不包含独立浏览器主体，浏览器能力由原版提供。

这可以作为局部功能修改方案审查；即使后续行为测试成功，也应准确称为依赖原版的功能修改启动器，不能因此声称完成独立重写。对于仅删除该提示的目标，采用这种交付形态是否可接受，需要与“独立重写”要求分开判断。

## 本次确认的有效实现和测试

本次直接按原版 PE RVA 校验全部 15 处预期字节：全部匹配，替换长度均相等，共 76 字节。六处核心改写跳过对话框/终止包装函数调用，其中一处设置零返回值，其他设置一；它不是单纯自动点击 OK。其余补丁处理 Office 和浏览器扩展提示及相关清理路径。静态匹配不证明运行时覆盖所有场景。

实际正式 EXE 的 SHA-256 为：

`3027b601a406e7e5b4a980c7648993e0185f647fefef943d87525d3547e3aad9`

本次 REA 直接读取该文件的 CIL，确认含 TargetDiscovery、BrowserReadiness 和 ApplyCodePatches，Program.Run 含相应调用；选择检查中 ResourceNeutralizer 未匹配，Program 中没有 DeferredPatchStart。嵌入计划与磁盘 dist/patch-plan.json 解析结果一致，readinessWindowClass 为 LOCKDOWNCHROME。该检查不加载或执行目标程序集。

本次执行 `python -m unittest discover -s tests -p 'test_*.py' -v`，11 项全部通过：5 项自建宿主集成测试、6 项候选路径选择/诊断测试。它们证明已有基础机制可运行，但不等于正式浏览器验收：

- [build.py:78](D:/Code/FuckLockDown/rewrite/build.py:78) 的 fixture 计划没有 readinessWindowClass，所以走 immediate 分支，不覆盖新正式版的窗口等待、挂起和恢复。
- [test_target_discovery.py:54](D:/Code/FuckLockDown/rewrite/tests/test_target_discovery.py:54) 直接测试 ResolveFromCandidates，候选来自模拟文件；它不测试宿主注册表枚举。本次真实默认校验另外证明了本机旧版目录的发现结果。
- [test_launcher.py:19](D:/Code/FuckLockDown/rewrite/tests/test_launcher.py:19) 的构建一致性只核对主源文件和 fixture 源文件，未覆盖全部新增源码及计划。

本次测试新增的 run-0d9d317f53ee4f6087430fe2f27c1f9f 属于本次自建宿主测试，不能误认为此前已有的正式浏览器验收。审查开始时最新的旧 run-* 目录仍为 11 月 16 日 16:56。

## 文档需要同步

[README.md:5](D:/Code/FuckLockDown/rewrite/README.md:5) 及后文仍描述恢复原版前补丁的旧行为；[第 65 行](D:/Code/FuckLockDown/rewrite/README.md:65) 起仍围绕旧 VM 阻断及 delayed 实验展开；[第 72 行](D:/Code/FuckLockDown/rewrite/README.md:72) 将这些实验推导成核心功能已实现。它们不能作为当前正式版已通过验收的说明。

最低限度还缺：使用上述正式 EXE 和受支持原版，在同一服务器配置及触发程序下，执行与新正对照相同的选择步骤，记录目标提示消失、相关程序存活，以及浏览器继续正常启动。若产品还声称覆盖后续反复扫描或考试会话，则这些声明也需各自对应的验证；不能用短时停留在配置界面推导。

## 审查边界与证据

本次未修改源码、计划、正式 EXE 或旧报告，未安装/升级原版、注册协议、启动 LockDown Browser、运行 VM 或操作驱动。执行了只读校验器和无害自建宿主测试，新增本报告、测试输出及证据目录。

完整静态 CIL 记录见 [rea-evidence.json](D:/Code/FuckLockDown/rewrite/review-followup-artifacts-2026-11-17/rea-evidence.json)：正式版成员 Evidence 为 `ev_3b6e3917d0203197e73c7f4588ee6a9de5cf3d8f06706ba21533a4dd6873f00d`，校验器成员 Evidence 为 `ev_3efdb3db5e2aca6888cef7e45ffb1c0f751537b1fc609b7eaf5cdc1fcbdff51a`。token 只在各自哈希及 MVID 下有效。

文件哈希、时间、测试结果及原版正例摘要见 [review-observations.json](D:/Code/FuckLockDown/rewrite/review-followup-artifacts-2026-11-17/review-observations.json)。浏览器行为结论来自保存的历史回执；本次没有重新执行浏览器，保存记录的有限采样也不能排除采样间的其他事件。
