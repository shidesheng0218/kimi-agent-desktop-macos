# Implementation Status

更新日期：2026-09-07

## 2026-09-07 Claude Code 桌面版 UX 全量对齐迭代（Phase 0–4）

全部改动只在 `macos/Sources`，未动 `vendor/engine`；能力来源分两类——**纯 UI/本地落地**（不依赖引擎新协议）与**引擎既有协议复用**（把引擎已支持的能力上浮到 UI）。

### Phase 0 · 呈现层

- 深色模式（纯 UI）：KimiDesign 双态自适应色板，设置「外观」三档（跟随系统/浅色/深色），`UserDefaults kimi.appearance` 持久化。
- Markdown 分块渲染 + 自研语法高亮（纯 UI，KimiMarkdownView.swift）：代码块带语言标签与复制按钮，流式未闭合 fence 安全降级。
- 消息 hover 复制/重新生成按钮（UI + 复用 prompt 链路）。
- 快捷键体系（纯 UI）：⌘B 侧栏、⌘⇧T/⌃` 终端、⌘⇧D diff、Esc 停止、⌘/ 帮助浮层、视图级 CommandMenu。
- 自研 KimiResizeDivider 可缩放三栏布局（纯 UI），侧栏/终端折叠与宽度持久化。
- 会话头部用量指示（UI + UsageLedger）：UsageLedger entry 增加 `sessionID` 字段，会话级 token + 成本聚合展示。
- 侧栏搜索 + 状态过滤（纯 UI）：全部/运行中/待审批/已完成；首页 recentSessions 死代码渲染为「最近会话」。

### Phase 1 · 输入与上下文

- 附件（引擎协议复用）：composer 图片粘贴（⌘V）/拖拽 + 附件条，走 `prompt_async` 原生 file part（图片 data URL、文本 file:// 注入）。
- @提及文件模糊搜索浮层（纯 UI，KimiFileMentionIndex），选中后注入文件路径。
- 权限模式三档（引擎协议复用）：composer 选择器切换手动确认/自动接受编辑/计划模式——plan 走 `prompt_async` 的 agent 字段，自动接受编辑走 `PATCH /session/:id` permission；ClaudeParityCatalog `planMode` 标记为已实现。
- 文件路径可点击 + 统一右键菜单（纯 UI，KimiFilePathSupport.swift）：文件面板打开/编辑器打开/Finder 显示/复制路径/附加为上下文。
- 系统通知（纯 UI，KimiNotificationCenter）：忙→闲完成与新待审批通知，点击跳转会话，设置可关。
- 视图模式三档（纯 UI）：标准/详细/精简，⌃O 循环。

### Phase 2 · 评审闭环

- Diff 面板重构（纯 UI）：左文件列表 + 右详情（KimiResizeDivider），逐行点击评论 + ⌘Enter 批量提交（走 steer/prompt 通道），过期评论标注，「AI 评审」按钮。
- Files 面板可编辑（纯 UI）：保存写回、mtime + 内容双因子磁盘冲突检测、64KB/二进制只读降级。
- 权限卡内嵌 diff 预览（引擎协议复用）：`permission.asked` metadata 自带 filepath + unified diff，`DiffEngine.parseUnifiedDiff` 渲染。
- PR/CI 状态条（本地 gh CLI，KimiPullRequestMonitor）：gh 检测 → 分支 PR 查询 → `statusCheckRollup` 30s 轮询，CI 结束发系统通知；未装 gh 静默降级。

### Phase 3 · 编排与隔离

- Worktree 隔离（纯 Swift，不调引擎端点）：`git worktree` 于 `<repo>/.kimi/worktrees/<id>`，分支 `kimi/session-<id>`，写入 `.git/info/exclude`；设置「会话」分类开关默认开；侧栏分支徽标；删除会话可选清理（有未提交改动先警告）；非 git 项目/创建失败回退项目根。ClaudeParityCatalog `worktreeIsolation` 标记为已实现。
- 后台任务面板（引擎协议复用，KimiTasksPane）：活动聚合、耗时、状态；无单任务停止（引擎无此通道）。
- Side Chat ⌘;（引擎协议复用）：引擎 fork 会话，关闭即删，不进侧栏（KimiSideChatPane）；顺带修复 `show(.conversation)` 被事件流冲掉的 bug。
- 双槽面板系统（纯 UI）：KimiPanelSlot 主/次槽 + KimiAuxPaneHost 解耦，方向可调、尺寸持久化。
- 双会话分屏（kernel 扩展 + UI）：⌘点击侧栏会话开启（KimiSplitSessionPane），kernel 新增 `.sessionEvent` 直通事件与 `sessionHistory`/`promptSession`/`abortSession`，⌘\ 关闭焦点侧，分屏时面板区隐藏。

### Phase 4 · 预览浏览器

- KimiBrowserPane 升级为常驻 WKWebView 交互浏览器（纯 UI）：地址栏/前进后退刷新/外部打开，「预览/验证截图」分段。
- 本地 HTML/PDF/图片/视频在浏览器面板打开（`loadFileURL` 限制在 workingPath 内）；http(s) 链接右键「在浏览器面板打开」。
- dev server 最小版（纯本地）：package.json dev/start 脚本检测 + lockfile 推断包管理器 + 输出提取 localhost 地址自动导航 + 尾部 50 行排障 + 停止/重启；退出时随引擎 SIGTERM。
- ⌘⇧B 切换浏览器面板；与引擎验证沙箱物理隔离。

### 遗留限制

- `swift test` 基线仍为空目录（Swift 测试目标无用例），回归断言集中在 `KimiAgentCoreChecks`。
- 双会话分屏的次列只发文本（不支持附件/权限模式切换等完整 composer 能力）。
- Side Chat 的 token 用量未计入 UsageLedger 会话账本。
- PR/CI 状态条依赖本机安装并登录 `gh` CLI，未安装时静默降级（无任何提示位）。
- `githubAutomation` 仍标未实现：有只读 PR/CI 状态条，但无 auto-fix/auto-merge 与完整 PR 创建流。
- 后台任务面板无法停止单个任务（引擎无对应通道）。

## 2026-09-07 成本可观测与潜伏风险关闭

最小改造，默认行为不变：未设置任何新环境变量时，除"多记一份账本"外用户可感知行为零变化。

- **A · token 用量捕获 → UsageLedger 入账**：SSE decoder 在 assistant `message.updated` 帧里提取 `info.tokens`/`info.cost` 进入事件 payload（kind 不变，user 消息过滤不受影响）；KimiAppKernel 按会话累积最近一次 usage，在 turn 结算（sessionIdle/sessionStatus 的既有 recordedAssistantTurns 去重点）同步 append 一条 `UsageLedgerEntry`——entry.id 由 turnID 确定性派生，重放/重复结算不会重复计费。成本优先走 `ModelPriceCatalog.cost(...)`（价格未配置时保持 `.unconfigured`，不伪装成 0）；引擎自带 `info.cost` 仅作 `.estimated` 兜底。账本经 `UsageLedger(fileURL:)` 持久化到 `Application Support/harness/usage-ledger.json`，组装点注入 kernel。
- **B · 预算闸（opt-in）**：仅当 `KIMI_AGENT_BUDGET_USD` 解析为正 Decimal 且 kernel 持有 ledger 时启用；`CostBudgetGate` 判 `.exceeded` 时 prompt 被拒（中文错误含已花费与上限），复用既有失败回滚路径移除用户气泡并上屏；`.warning` 放行。未设置 env 时完全不拦截。
- **C · small_model 低成本路由可配置**：`KIMI_SMALL_MODEL` trim 后非空且与主模型不同时，factory 把 `small_model` 设为 `\(provider)/\(smallModelID)` 并登记进 provider models 表（避免引擎校验失败）；TS 侧 `createKimiEngineConfig` 同步支持可选 `smallModelID`。未设置时 `small_model` 仍等于主模型。
- **D · AnthropicDirectEngineProvider 安全门（fail-closed）**：`executeTool` 接入既有 `PermissionPolicy`——read/write 出工作区拒绝、危险 bash 拒绝；凡 decision 为 `.ask` 的一律拒绝（该 provider 无审批应答能力），错误文案说明 fail-closed 原因；bash 执行路径改用 `TerminalCommandRunner` 的 sandbox 重载（当前策略下 `.allow` 不可达，属纵深防御）。该 provider 生产不可达，本轮消除其潜伏风险。

相关环境变量：`KIMI_AGENT_BUDGET_USD`（新增，预算闸）、`KIMI_SMALL_MODEL`（新增，轻量任务低成本模型）、既有 `KIMI_AGENT_PRICE_*`（价格目录，配置后账本成本转为 `.calculated`）。

回归断言（KimiAgentCoreChecks 新增）：decoder 提取 tokens/cost、kernel 单 turn 恰好入账一次且重放不重复计费、`UsageLedger(fileURL:)` 持久化往返、预算超限拒绝且错误上屏/未超限与未设置时放行、factory 的 KIMI_SMALL_MODEL 覆盖与默认行为、provider 工作区外 write 被拒且文件未创建/危险 bash 被拒/工作区内 write 仍成功。`engineFusion.test.ts` 新增 smallModelID 三条用例。

遗留（下一步）：模型分级路由 `ModelRouter`/`ModelRouteResolver` 仍未接入主 prompt 链路，分层调度属下一轮；`TaskBudget` 的 token/时长维度尚未接入预算闸（本轮只做成本维度）。

## 2026-09-06 可靠性与信任修复（核心任务链路优先）

本轮不重写架构、不新增功能，只修复审计中确认的"坏了但看起来正常"类缺陷：

- **发送失败不再静默**：`.prompt` / `.steer` / `.followUp` 失败时抛出并写入 `lastError`，移除"看似已送达"的用户气泡；视图层恢复输入框文本，打字内容不再丢失。
- **异步失败上屏**：Kernel 订阅 Harness 事件流，`operationStateChanged(.failed)`（Driver 超时、SSE 中途断流等）映射为 `lastError` + 错误事件；此前失败只落在 Harness 日志里，用户看到的是一个永远不回话的 turn。
- **retry 从 no-op 变为真重试**：`retry(OperationID)` 取失败 operation 的原始 prompt 经正常 prompt 链路重发；新增 `retryLastFailure()` 供错误横幅的"重试"按钮使用，视图层不再需要追踪 operationID。
- **restartRuntime 诚实化**：无 supervisor（引擎未打包）时标记 `.failed` 并给出错误，不再谎报 ready；重启失败同样上屏。
- **Diff 错误态与空态分离**：新增 `loadDiffOutcome()`（`.noActiveProject / .snapshot / .failed`），git 失败（非仓库、git 缺失）不再被渲染成"工作区没有改动"。
- **审批卡透明化**："总是允许"按钮下注明其按 pattern 永久放行的作用范围。
- **状态文案三态化**：侧栏运行状态区分 已连接 / 正在连接 / 引擎故障 / 未就绪 / 已停止，不再把 failed 显示为"正在连接"；首页新增全局错误横幅（带重试）。
- **安全**：`run-app-with-config.sh` 移除已提交的硬编码 API Key 与 Key 前缀回显，改为从环境变量读取。

回归断言（KimiAgentCoreChecks 新增）：断流失败上屏、retry 重发原 prompt、无失败时 retry 为 no-op、无 supervisor 时 restartRuntime 报 failed、prompt 同步失败抛错且不留气泡。

已知未接线状态更新：UsageLedger / CostBudgetGate 已于 2026-09-07 接入（token 用量捕获 + 可选预算闸），`small_model` 低成本路由已可通过 `KIMI_SMALL_MODEL` 配置，AnthropicDirectEngineProvider 工具执行已接 PermissionPolicy fail-closed 门；仍未接线的只剩模型分级路由 ModelRouter / ModelRouteResolver（主 prompt 链路不分层，属下一步）。

## 2026-08-19 断链补全（Claude Code 交互对齐）

本期把已实现但未接线的链路全部接通，并把引擎已支持的能力上浮到 UI。架构决策：内置引擎（opencode 派生）是唯一执行链；Swift 侧 Supervisor/DAG 编排（AgentKernel/AgentGraphSupervisor/AgentRunScheduler 等）保持仅测试接线，不再追求生产化。

### 真实环境验收（2026-08-19，本机 + 真实 Kimi API）

以发布包内真实引擎二进制（生产配置镜像）+ 真实 API Key 完成两级验收：

1. **引擎级（curl 驱动）**：会话创建/目录路由、模型目录、edit/bash 权限 ask→once/always、流式 delta、agentic 全循环（写文件→跑测试→测试通过）、steer 插队被运行中 turn 拾起、abort、revert/unrevert 文件回滚与还原。
2. **内核级（生产 KimiAppKernel + URLSessionRuntimeClient 驱动真实引擎，27 项断言全过）**：建会话→忙态→审批卡（patterns 保留）→always 应答→turn 完成→单气泡合并→无用户消息回显→Harness 回执→steer→历史重建→abort→revert→模型目录/todo/command/mcp 端点。

验收中发现并修复的四个存量深层缺陷（全部有回归断言）：

- **SSE 帧解析失效**：`URLSession.bytes.lines` 不上送空白分隔行，原实现等空行成帧导致事件流实际从未产出任何事件（长 turn 后 UI 与引擎脱节）。改为单行 JSON 完整即解码。
- **SSE 请求 60 秒默认超时**：`URLRequest` 默认 timeoutInterval 会在长权限等待后掐断流。显式放宽并按心跳维持活性；断流重连后新增 `GET /session/status` 状态对账。
- **`"replied"` 不含子串 `"reply"`**：`mapKind` 用 `contains("reply")` 判定 `permission.replied`，永远落空导致 replied 被误判为 permissionAsked——审批完成后引擎的结算事件变成第二张不可应答的僵尸审批卡。改判 `replied`/`resolved`，审批卡按引擎 requestID 去重，`permission.replied`/`question.replied` 到达即按 requestID 结算移除。
- **用户消息回显**：用户消息的 text part 快照/delta 被当作助手文本（出现"自己的消息变成助手气泡"）。解码器新增 messageID→role 注册表，用户消息的 part 一律过滤。

对话闭环修复：

- 修复 directory 误放 POST body 的缺陷（引擎只认 query 参数；此前所有会话都跑在引擎进程 cwd）；全部端点统一 query 路由并用 URLComponents 正确转义。
- 流式回复按 partID 合并为单条气泡（delta 追加 / snapshot 替换 / idle 封口），不再裂成碎片；reasoning 内容隔离为可折叠“思考过程”卡片。
- session.status/session.idle 驱动运行态；执行中显示停止按钮（引擎 abort + Harness abort 一致）。
- 权限审批迁移到 `/permission/{id}/reply`：拒绝 / 允许一次 / 总是允许三按钮，展示引擎下发的 patterns；审批失败可见不静默；重启后过期审批卡自动清理。
- SSE 断流指数退避重连（上限 12 次）；引擎意外重启后 supervisor 重新等待就绪并通知内核重新订阅全部会话。
- Driver 超时放宽到 30 分钟且超时后主动 abort 引擎会话保持两侧一致；审计 turn 记录真实所选模型；补记 assistantMessage 让首页模型统计有数据。

会话与项目：

- 新建会话强制 NSOpenPanel 选择项目目录；会话与项目绑定，最近项目持久化；隐式建会话用最近项目，无项目时明确报错引导。
- 切换会话/重启后从 `GET /session/{id}/message` 重建消息与工具活动；Todo 从 `/todo` 恢复。
- 模型切换真生效：`prompt_async` 携带 per-prompt ModelRef（免重启）；启动时 `GET /provider` 拉取目录；目录变更时带原 endpoint 就地 reconfigure（端口/token 保持稳定）。

Claude Code 交互：

- Steer：Driver 轮询 Harness steering 队列并转发运行中的引擎会话（引擎 busy 时自动在循环边界拾起）。
- Follow-up：忙时可排队，本轮结束自动开新轮（Harness 队列语义）。
- Todo 清单（todo.updated → 会话顶部清单）、结构化问答卡（question.asked → 选项/自定义回答 → reply/reject）、消息级 revert/unrevert、Slash 命令（`/` 补全 → `/session/{id}/command`）、compact（summarize 端点）。

面板实体化（原五个占位面板全部落地）：

- Diff：项目工作区真实 git diff（DiffEngine 解析，文件/hunk 渲染）；
- Files：项目目录树 + 文本预览；
- Browser：截图产物与浏览器活动展示（活动卡内联图片）；
- 验证：Harness Intent/Receipt 审计视图；
- 集成：引擎 MCP 状态与 Skills 列表。

文档对齐：README 执行闭环/能力地图/权限表/会话语义改写为引擎原生架构的真实描述；ClaudeParityCatalog 更新为真实实现状态（worktreeIsolation、planMode、hooks、githubAutomation、gitlabIntegration、memory 标记为未实现）。

验收：KimiAgentCoreChecks 新增约 40 条断言（directory query 转义、流式合并、reasoning 分类、忙态映射、always 应答、steer 泵送、超时一致性、历史解析/重建、模型目录、工厂 reconfigure 保端点、todo/question 解码、revert/command/summarize/todo/command 端点、MCP/Skills 解析、验证回执聚合、图片产物提取），全部通过；`swift build` 两个产品全绿。

## 当前产品线

项目现在只保留 **原生 macOS SwiftUI 版本**。

已移除并停止维护：

- Electron 独立桌面版；
- VS Code / Code - OSS 扩展版；
- WebView Dashboard 壳层；
- VSIX 打包链路；
- Electron 打包链路；
- 旧 Electron 发布产物；
- 额外优化路线文档。

## macOS 原生版能力

已保留：

- SwiftUI 原生三栏工作台、工具栏、快捷键和系统文件夹选择器；
- Plan / Edit / Agent 三种模式；
- Kimi Code 登录模式与 Moonshot / Kimi API Key 模式；
- Keychain 凭据保存；
- 本地任务、事件、项目状态持久化；
- Native Agent Host 与 CLI 回退链路；
- Worktree 隔离、Diff Review、验证、人工合并；
- Web Search / Fetch；
- Skills / Hooks / MCP；
- Agent Run 编排图、项目规则发现和 Plugin / 自定义 Agent 注册表；
- 会话级 Workspace Layout 持久化和 Agent 阶段状态回流；
- GitHub / GitLab 管理入口；
- WKWebView 浏览器验证；
- 内置 Kimi Runtime 与 macOS Node Runtime；
- arm64 原生发布路径（GitHub Releases 直接分发，ad-hoc 签名、不公证）。

## 当前维护原则

- 只维护 macOS 原生应用；
- 不再新增或优化 Electron / VS Code / WebView 兼容版本；
- 不再把旧壳层作为产品目标；
- 后续改动只服务于 macOS 原生版的稳定性和可用性。

## 2026-08-10 真实闭环更新

- 新增 SessionKernel：追加式 Session Event Store、MessagePart 和 Projector 回放；桌面新任务开始写入 `session-events.jsonl`。
- 新增 ChildSessionCoordinator 和 ToolRegistry，作为后续真实独立 Kimi Child Runtime 与统一工具执行层的接口。
- 新任务不再只有旧的 `WorkItem` 列表，同时生成独立 `AgentRun` 图并写入任务状态。
- 旧任务启动时会迁移到默认 Agent 图；运行中的节点在应用重启后标记为 `interrupted`，可从会话继续。
- `AGENTS.md`、`.kimi-agent/rules.md` 和 `.kimi/rules.md` 会被发现，并作为项目规则注入每次 Runtime Prompt。
- `.kimi-agent/plugins` / `.kimi/plugins` 下的 `plugin.json` 会被发现；插件内 `skills/` 目录会进入统一 Skill Registry。
- 扩展 Inspector 现在包含 Plugins 区块，任务主区域显示 Agent 阶段活动和状态。
- 权限层新增 `CapabilityGrant`，用于按 Agent / 资源 / 操作范围记录最小授权；现有审批策略继续作为执行门禁。

## 2026-08-14 Harness 可靠性更新

- 新增 JSON 原生 ToolCallEnvelope 与严格 Schema 校验；无效参数会在 Hook、权限审批、Intent 和执行器之前被拒绝。
- Tool Intent 增加输入摘要，Receipt 增加输出摘要、Artifact ID、重试语义；成功 Tool Result 会回传真实 effectID，供 Child Agent 和最终答案核验。
- Kimi SSE 增加持久化 ProviderTraceRecorder 与离线 ProviderReplayRunner：可回放 name-only、index-only、空参数、碎片化参数和中断流，不记录 API Key。
- Native Kimi Provider 与主会话/Child Session 都写入本地 harness-v3/provider-traces.jsonl。
- 公网只读 Web Research 在策略层不再被标记为预审批操作；实际执行仍由公网/私网、协议、URL 和域名策略二次约束。
- 同一 Worktree 的 Implement / Debug 等写入阶段由 DAG Scheduler 串行调度，避免并行 Child Agent 改写同一隔离工作区。
- 记忆增加语义键、作用域优先级和冲突审计；同键 Task/Project 记忆覆盖 User 记忆，自动推导记忆不提升权限。
- Context Projector 现在可注入规则、已验证结果和未解决问题；Final Answer Gate 可要求专用工具具有成功 Receipt。
- 用量账本区分“已计算成本”和“价格未配置”，不再把未知价格的 0 伪装为真实成本；可通过 KIMI_AGENT_PRICE_* 环境变量配置每百万 Token 价格，并在 80%/100% 预算处预警/阻断。

## 2026-08-14 Supervisor 闭环更新

- 新增 Core-owned `AgentGraphSupervisor`：DAG 节点选择、依赖释放、Child Session 创建、结果回流和快照事件均由 Core actor 负责；SwiftUI 只投影 `AgentGraphSupervisorEvent`。
- 移除桌面层 120ms `scheduleReady()` 轮询和手写 Child Agent 成功/失败回填；图驱动现在只有一个 Supervisor execution authority。
- `AgentRunScheduler` 支持 `childSessionID` 关联、调度/结算快照、单节点 retry 和明确的 Worktree 冲突串行规则。
- `ChildSessionCoordinator` 为每次执行创建可取消 Task；暂停/取消会传播到正在运行的 Provider/Tool executor，不再只修改 UI 状态。
- 应用启动会从持久化 `AgentRun` 重建 Supervisor；未结算节点转为 `interrupted`，只有用户明确继续后才进入下一次执行。
- 重启恢复会先通过 `AgentGraphRecoveryPolicy` 校验任务意图；迁移产生的普通聊天 AgentRun 不会误恢复成 Explore/Plan 图。
- Graph 的事件投影保持最新单链：阶段结果、Child Session ID 和最终汇总都从 Core snapshot 回流，不由 UI 猜测完成状态。
- MCP Harness executor 现接入 Worker health：成功调用记录 `healthy`；失败记录 `reconnecting` / `unavailable` 并尝试重连 Worker，但绝不自动重放当前 MCP tool call，避免未知的外部副作用被重复执行。

## 尚需真实环境验收

已通过的真实验收（本机，含证据产物）：

- Browser 真实闭环：`BrowserSmokeCheck` 通过本地 loopback HTTP + 生产 `BrowserVerificationController`（离屏 WKWebView）完成 open → inspect h1 → screenshot → collectConsole，截图产物真实落盘且可读（`BROWSER_SMOKE_OK`，截图 91KB）。
- Computer Use 真实闭环：`ComputerUseSmokeCheck` 驱动生产 `ComputerUseController.executeHarnessRequest` 完成 inspect、真实屏幕捕获（303KB PNG，目视确认）、参数校验、辅助功能/屏幕录制权限门与结构化错误路径（`COMPUTER_USE_SMOKE_OK screenGranted=true accessibilityGranted=true`）。
- MCP 真实第三方 Server：`MCPSmokeCheck` 驱动生产 `MCPStdioClient` 连接 `@modelcontextprotocol/server-everything@2.0.0`，完成 initialize 握手、tools/list（12 个工具）、echo 真实回环、resources/list + read、prompts/list + get，以及 `kill -9` 崩溃注入后结构化 `notConnected`（无挂起、无崩溃）和 close 后守卫（`MCP_SMOKE_OK`）。
- 重启恢复进程级闭环：`RestartRecoveryCheck` 以两个独立进程共享同一状态目录模拟应用被杀后重启。已结算 op 保持 completed 且成功 Receipt 保留（零重放）；中途被杀的 op 恢复为 suspended，未结算写入 Intent 保留但绝不伪造 Receipt，未应答 tool call 写入合成中断结果；restore 实测 0.001s（预算 2s）；会话列表、活跃会话和消息历史经生产 `KimiAppKernel` 恢复（`RESTART_RECOVERY_OK`）。

仍需真实环境验收：

- 真实 Kimi API 端到端对话、真实 MCP OAuth/远程 Transport 和 100 仓库对标基准必须在已配置凭据与用户授权的 macOS 环境中执行。
- 这些外部验收在通过前不应标记为“超过 Claude Code”；本地 CoreChecks、构建和打包只证明可回放的本地闭环。
