# Handoff — qaqh-harmony M2（单流订阅 + timeline 监视）+ M3（授权闭环）+ 真机联调 … M6

日期：2026-10-06
状态：M2/M3/M5/M5.1 代码完成——三态 UI（连接→会话列表→会话监视）+ 工具卡片 +
审批闭环 + 手机输入/输出闭环（发消息/停止/驱动席认领）;实况窗模块已编译通过。
**M6（见文末）：后端合并后重对拍修三处静默失效 + LAN HTTPS + 设备配对与归属。
M7：正文换成 Timeline 通道（真机定性——`/events` 里根本没有逐字正文）；
协议 50/50、client 62/62、wire-smoke 46/46，构建+签名通过，已装机。**
后端基线：qaqh-backend `2.0.0-beta.2` `main@a125400`（本机 `E:\qaqh-backend`，
其中 `tls.rs`/`server.rs` 的证书 SAN 改动是本轮加的，**未提交**）
前置：`docs/handoff-m0-protocol.md`、`docs/handoff-m1-client.md`、`docs/smoke-ohos-napi-toolchain.md`
架构决策（2026-10-05）：**暂不引入 Rust core/NAPI**，鸿蒙侧纯 ArkTS 自实现，等
qaqh 新协议 + client SDK 立项再评估（团队研判，见对话记录）；为此 UI 层与
连接层按 webui TransportBackend 契约收口，保证将来换 core 时 UI 不动。

## M3 增量（2026-10-05 下午）

### 协议层
- `wire/InteractionBody.ets`：交互正文解析（`application/vnd.qaqh.interaction-request+json`，
  镜像 qaqh-domain interaction_body.rs 单一来源格式）。ask（mode + questions[id/
  question/options/allow_custom]）/ plan（plan_content + review_type）/ permission
  （tool_name/paths/category/level/risk/consequence）。**展示面容忍策略**：未知
  kind 不抛错（保留 raw 供 UI 降级），只有畸形 JSON 才响亮失败。
- 测试 34（+1 交互正文）。

### 连接层
- `InteractionCenter.ets`：授权闭环核心。
  - pending 集合：bootstrap 快照 + interaction_requested/resolved/expired 三种
    delta（first-answer-wins：任何来源的 resolved——含桌面端——都移除 pending）。
  - 三类应答：`tool_permission_respond`（tool 频道，tool_call_id = call_id）、
    `interaction_ask_respond`/`interaction_ask_dismiss`、`plan_review_respond`。
  - 可靠确认：ACK accepted 后登记 command_id，等 `causation_id == command_id`
    的事件才判终态；**ACK 传输丢失回退 `GET /commands/{id}`**（succeeded → 已生效；
    accepted/running → 继续等事件；rejected/failed → 上报）。
  - rejected + existing 回执（command_receipt / interaction_resolved）直接按
    typed result 收敛（首答即终的输方不重试）。
- 测试 37（+10 交互闭环）。

### UI（entry）
- `pages/Index.ets` 增加审批面板：待处理授权卡片（权限/计划/提问三类），
  正文经 ref 拉取 + InteractionBody 解析渲染；permission 允许/拒绝、plan 批准/
  拒绝、ask 选项按钮 + 自定义回答 + 不作答关闭。守门点：requestPermissions
  已含 INTERNET。

## M3 关键契约认知（对拍后端）
1. 交互正文在 content store（media type `vnd.qaqh.interaction-request+json`），
   canonical ref 逐字节敏感——客户端只消费不改写。
2. `tool_permission_respond` 用 **tool_call_id**（= 交互的 call_id），不是
   interaction_id；ask/plan 用 interaction_id。
3. permission 正文字段：tool_name/action_summary?/reason/paths/category/
   level/risk/consequence；risk ∈ low|medium|high，category ∈ read|write|exec|net。
4. 归因：`InteractionResolved.resolved_by` 目前后端硬编码 "user"，设备归因
   挂靠 plan-permission-extraction-v2 Step 4（鸿蒙侧无需改动，等 wire 契约）。
5. 测试基建：脚本化 ACK 需**回显请求里的 command_id**（center 动态生成 id，
   `assertAckMatches` 会核对），用 %CMDID% 占位模板。

## 本阶段完成的事

### 协议层（@qaqh/protocol）
- `Payload.ets` 新增 **TimelineDelta 强类型解析**（7 变体：input/block/tool_call/
  tool_result/turn_finished/turn_interrupted/compaction），枚举值全部校验
  （block_kind/terminal_status/terminal/reason，非法值 `invalid_enum_value` 响亮失败）。
  夹具含后端 `projection_event_contract.rs` 的 tool_result 黄金向量。
- 测试 32 → 34。

### 连接层（@qaqh/client，14 → 27 用例）
| 文件 | 内容 |
|---|---|
| `transport/StreamConnection.ets` | `StreamConnection`/`StreamListener` 接口 + `StreamEndpoint`（baseUrl+headers，path/query 由 EventStream 组装） |
| `transport/HttpStreamConnection.ets` | `requestInStream` 实现：dataReceive→Uint8Array 上抛；dataEnd/非 2xx → onEnded(status)；reject → onFailed |
| `EventStream.ets` | SSE 单流：`ringing.event` 信封派发 + `ringing.reset_required`（单次后断流）；`?since_cursor=` 续传；退避重连 1s→15s（收到事件复位）；**4xx/5xx 不自动重试**，上报 monitor 决策；坏帧 ProtocolError 响亮停止 |
| `SessionMonitor.ets` | 自愈监视循环：open → bootstrap → 订阅（快照基线；持久化 cursor 同 log_id 时优先续传）；401/403 断流或 bootstrap 失败 → 重新协商（re-open + re-bootstrap）；`reset_required` → 上报 UI + 重建；每个 reliable 事件落 cursor store |
| `RingingClient` 增强 | `open()` 允许 closed 状态进入（重新协商）；`fetchContent()`（content 端点，ContentFetch{mediaType,body}）；TransportResponse 携带响应头 |

### UI 层（entry）
- `pages/Index.ets`：连接配置（地址/token/seed）→ 监视页。状态条 + timeline 流
  （用户输入/assistant 块/工具调用与终态/turn 标记），ref 内容经
  `fetchContent` 异步回填。
- `timeline/TimelineReducer.ets`：ProjectionPayload → 渲染条目的显示 reducer
  （UI 层私有，换 core 不动）。
- `cursor/PreferencesCursorStore.ets`：preferences 持久化 CursorStore 实现
  （prime() 预热，load/save/clear 同步）。
- entry module.json5 已有 INTERNET 权限（M1 加的）。

## 关键 wire 认知（M2 新增，均已对拍后端源码）
1. SSE 事件名：`ringing.event`（id=`v2:{epoch}:{event_id}`）与
   `ringing.reset_required`（**只发一次随后服务端断流**）；keepalive 注释 15s。
2. `TimelineDelta` wire 形态 `{"kind":"timeline_delta","data":{"kind":"<variant>","data":{...}}}`
   ——三层嵌套，`data.data` 才是载荷。
3. tool_result 的 `output:null` 合法（ContentValue 缺省）。
4. timeline 正文大量走 content ref（`sha256:<hex>`），需 GET
   `/content/{id}` 拉取，鉴权 = token + session header。
5. 重新协商时 `client_instance_id` 不变、`client_session_id` 会换——流请求的
   header 必须每次从 client 现取（EventStream 的 endpointFactory 模式）。

## ArkTS 严格模式新增坑（M2）
- struct 不能被普通类当类型引用：监听器用 LambdaListener（闭包注入）模式。
- 测试里手写 `bytesOf`（charCodeAt&0xff）不是 UTF-8：中文会截断成单字节
  （'好'→0x7D='}'）。必须用协议层 `encodeUtf8`。
- `import('@pkg').Type` 类型查询别名被禁，老老实实展开导入。
- interface 的方法不能用对象字面量实现，必须显式 class。

## 测试 / 构建
```bash
# 全部单测（app/ 目录下）
DEVECO_SDK_HOME=<clt>/sdk <clt>/tool/node/node.exe <clt>/hvigor/bin/hvigorw.js \
  --mode module -p module=protocol@default test -p module=client@default test
# 全工程构建
DEVECO_CLI_CLT_PATH=<clt> ../node_modules/.bin/devecocli build
```

## M4 增量（2026-10-05 晚，API 24 侧）+ 24/26 策略

### 24/26 双端策略（与用户对齐）
- **代码基线钉在 API 24；`targetSdkVersion` 已升 26、`compatibleSdkVersion` 保持
  `6.1.1(24)`**（一个 HAP 双端跑；已验证 26 工具链构建 + 全部测试通过）。
- **26 工具链已就位（2026-10-05）**：`E:\qaqh-harmony\command-line-tools\`
  = CLT **26.0.0.851**（SDK: HarmonyOS 26.0.0 Release / API 26, hvigor 6.26.8）。
  deveco-cli 门槛已从 "6.1.1" 改回 "26.0.0"（`dist/cli.js assertCltVersion`）。
  **注意：本机现在有两套 CLT——26 在根目录 `command-line-tools/`（主用），
  24 在 `commandline-tools-windows-x64-6.1.1.418/`（留存备查）**。
- **版本串格式变化（26 线踩坑）**：`targetSdkVersion` 从 `x.y.z(api)` 双段式
  改为纯平台版本 `"26.0.0"`；带括号格式会报 "api version parameter is illegal"。
  `compatibleSdkVersion` 的 `6.1.1(24)` 旧格式仍被接受。
- 26 增量 = 实况窗（`@kit.LiveViewKit` 已在 26 SDK kits 中）；实现时用
  **动态 import + canIUse/syscap 运行时守卫**（静态 import 在 24 设备上会崩），
  24 设备降级常规通知。

### API 24 通知能力边界（本机 SDK d.ts 逐项核实，勿被 26.0.0 文档误导）
- **实况通知三路皆不可用**：`@kit.LiveViewKit` 不存在于 API 24 SDK（26.0.0 线新增）；
  `ContentType.NOTIFICATION_CONTENT_LIVE_VIEW` 与 `SlotType.LIVE_VIEW` 虽在枚举里
  （since 11/12）但注释明确 **"Only system applications are supported"**；胶囊
  （`NotificationCapsule`）挂在 `NotificationSystemLiveViewContent` 下，同样系统
  代理专属。三方最强提醒形态 = 常规通知 + actionButtons。
- 常规通知可用面：`notificationManager.publish/cancel`、
  `SlotType.SERVICE_INFORMATION`（横幅/锁屏/铃声全开）、
  `ContentType.NOTIFICATION_CONTENT_LONG_TEXT`（since 9）、
  `NotificationRequest.notificationSlotType`（since 11 新字段；旧 `slotType` 已弃用
  且类型是老模块枚举，别用）、`actionButtons[{title,wantAgent}]`、`wantAgent`。

### 本阶段代码（entry，全部 API 24）
- `auth/Authenticator.ets`：`Authenticator` 接口 + `NoopAuthenticator`（初期直通）
  + `UserIamAuthenticator`（`getUserAuthInstance` 系统弹窗控件，ATL1；
  FACE/FINGERPRINT 经 `getAvailableStatus` 探测，**平板无生物硬件回退
  `UserAuthType.PIN`**——覆盖"平板没有可信安全代理"场景）。权限
  `ohos.permission.ACCESS_BIOMETRIC` 已加 module.json5。
- `notify/ApprovalNotifier.ets`：`interaction_requested` → SERVICE_INFORMATION
  通知（LONG_TEXT 摘要 + 「允许/拒绝」actionButtons + wantAgent 深链），id 由
  interactionId 稳定派生（重发即更新），resolved 时撤下。
  **通知按钮只是深链**：intent 带 `qaqh_action` 预选，真正应答在 app 内过
  Authenticator 门禁。
- `EntryAbility`：onCreate/onNewWant 把 want 参数广播到 AppStorage
  （qaqhFocusInteraction/qaqhFocusAction），供页面深链聚焦。
- 页面 `respond()`：**批准类动作过门禁**（authenticate().then(doRespond)），
  拒绝不设门禁。通知正文等 InteractionBody 就绪后才发（避免先发占位文案）。

### 踩坑
- `IAuthCallback.onResult(result: UserAuthResult)`——result 是对象（`.result`
  才是数字码），不是裸 number。
- `NotificationRequest.autoCancelled` 字段不存在（API 24 是 `autoDeletedTime`）；
  `slotType` 是弃用的旧枚举字段，用 `notificationSlotType`。

### 联调增量（2026-10-05 夜,对齐安卓 E:\qaqh-android）
- **术语**:后端已统一 sessionId(旧称 seed 弃用);wire 路径占位符语义不变。
- **会话自动发现**（免手填,对齐安卓 ConnectionService"单活跃流+轮询"）:
  - 协议层 `wire/SessionList.ets`:session.list 条目解析 + `pickPreferredSession`
    (running 优先 → updated_at 最新 → 空串);
  - `RingingClient.sessionList()`:POST `/ringing/v2/service/session.list`
    (空 body `{}`,session header,响应直接是数组);
  - `SessionMonitor.start()` **无参 = 自动发现模式**:轮询 15s,会话切换时
    重建流;带 sessionId 仍为固定模式。需第二个 LeaseTimer(discoveryTimer)。
  - UI 去掉 sessionId 输入框,token + 地址即可连接。
- 测试:协议 36 / client 38(协议计数曾因 hvigor 缓存结果文件显示不涨,
  clean test 才准)。

### 真机联调（2026-10-05 深夜）：环境 + 两个关键发现
**环境**(全部就绪):
- CLT 26.0.0.851(`E:\qaqh-harmony\command-line-tools\`,SDK API 26,hvigor 6.26.8);
  24 旧 CLT 留存在 `commandline-tools-windows-x64-6.1.1.418/`。
- 签名已生成(`devecocli signature generate`,写入 build-profile)。
- devecocli 读登录态需 `HOME=/c/Users/tsy3m USERPROFILE='C:\Users\tsy3m'`
  (ZCode 会话的 HOME 被重定向,用户在其自己终端 `auth login` 的凭据在真实
  用户目录)。
- 手机(26)经无线调试连接:`hdc tconn 60.0.0.99:45939`(手机上需点允许)。
- daemon:`E:\qaqh-backend\target\debug\qaqh-daemon.exe server --bind 60.0.0.65
  --port 64413 --token 11`(dev 固定 token="11";**非回环 bind 是明文 HTTP,
  仅限 LAN 开发**)。注意 daemon 的数据根跟随启动者的 HOME。

**发现 1——命令 wire 契约 bug(M0 埋雷,真机首日暴露)**:
后端 `RingingCommand` 是 `#[serde(tag="channel")]` 内部 tag 枚举,信封的
`command` 对象必须**内部携带 channel**:
```json
"command": {"channel": "control", "type": "session_create", "close_current": false}
```
与信封顶层 `channel` **并存**(RingingV2CommandEnvelope 也有 channel 字段)。
M0 的 `Commands.ets toWire()` 只写了顶层,`command` 里漏了 channel——假件
契约测试自洽所以 M0/M1/M2/M3 全绿,真机一发命令就 400 `invalid_body: missing
field 'channel'`。已修 `toWire()`(向 command 对象注入 channel)并更新全部
wire 断言。curl 实测 `session_create` ACK = accepted。
**教训:命令路径从未被真 daemon 打过;凡 wire 写入方,联调前先 curl 单发验证。**

**发现 2——`session.list` 只列 daemon 会话管理器已注册的会话**
(`service.rs list_sessions` = `self.sessions.list()`,不是磁盘扫描)。新起的
daemon 注册表为空,手机端自动发现会一直"发现会话中"。解法:先经命令通道
`session_create` 建会话(或桌面端开过会话)。实测创建后列表即时返回条目。

**当前状态**:修正版 app 已装到手机(60.0.0.99)并启动;daemon 在线且有
1 个会话(01a10b39-a5cb-…)。待用户点「连接」验证:自动发现 → bootstrap →
事件流 → timeline 渲染 → 审批闭环。
- session.list 条目字段比安卓模型多(effort/skills/usage_totals/…),鸿蒙侧
  解析器只取已知字段,天然前向兼容。

### M5 增量（2026-10-05，后端旧协议清理改造期；UI 三态重构）
背景：后端 `main` 在做旧协议清理（P0+P1.1 已合入），不触碰 ringing v2 wire 面；
其间鸿蒙侧推进纯客户端改进 + 会话列表/详情 UI（后端工作区有未提交的
pending_store/interaction_ledger 改动，**在它落地前勿再叠加 interaction wire 新假设**）。

- **三态编排**（`pages/Index.ets` 重写）：`config`（连接配置）→ `list`
  （会话列表轮询 + 创建会话）→ `session`（固定会话监视 + 审批面板 + timeline）。
- **双 client 架构**：列表轮询与会话流各持一个 RingingClient（各自 open/lease）。
  关键约束：`SessionMonitor.stop()` 会 close 自己的 client + clear cursor store，
  **不能**与列表轮询共用一个 client；退列表 = monitor.stop() 后列表轮询继续。
  cursor store 按会话分 key（`PreferencesCursorStore(context, sessionId)`）。
- **新视图组件**（entry/view/，展示面）：`SessionListView`（列表卡片：模型/
  running 徽标/摘要/计数/更新时间，兼容秒/毫秒量纲）、`TimelineView`
  （工具卡片：工具名 + 终态徽标 + 参数/输出/错误分区，自动滚底）、
  `ApprovalPanel`（审批卡片 + 深链聚焦）。
- **TimelineReducer 结构化**：tool 条目拆 toolName/argsText/outputText/
  errorText/callId 独立字段（`toolStatusTone()` 配色）；乱序 result 独立成卡；
  `resolveRef` 按 kind 回填。Index 侧 ref 拉取加了 `fetchedRefs` 去重。
- **深链聚焦**：ApprovalPanel 收 `focusInteraction`（@StorageLink 链
  AppStorage），scrollToIndex + 高亮 + 「通知入口预选」横幅；focus 即消费
  （回写清空防重复触发），高亮本地保留到卡片消失。**不做自动应答**——
  批准类仍过 Authenticator 门禁。
- **创建会话入口**：列表页「创建会话」= control 频道 `session_create`
  （`RingingV2CommandEnvelope.create`，唯一允许 sessionId 为空的命令；
  instanceId 复用列表 client 的）。ACK accepted 后 800ms 刷新列表。
- **实况窗模块**（`notify/LiveViewNotifier.ets`，API 26 增量）：
  `@kit.LiveViewKit` **动态 import + `canIUse('SystemCapability.LiveView.LiveViewService')'**
  运行时守卫，kit 类型零静态引用（本地结构接口 + `as` 对齐 liveViewManager
  最小调用面）；scenario 用 `PROGRESS`，sequence 逐次递增；pending 数变化即
  start/update，归零即 stop；任何失败静默降级（常规通知链路不受影响）。
  26 SDK 实测可编译（compile：LiveView{id,event,liveViewData{primary,capsule}}）。
- 测试协议 36 / client 38 全绿，全工程构建 + 签名通过。
- 待真机验证：列表轮询与流切换、创建会话、深链聚焦滚动、实况窗在 26 手机
  实际挂载（PROGRESS 场景资质未申请，可能被拒——拒绝即静默降级，无副作用）。

### M5.1 增量（2026-10-05 晚）：手机输入/输出闭环（免 TUI）
目标：手机端直接给会话发消息、看流式输出、中途停止——不再需要开桌面 TUI。
对拍后端 `driver_gated`（axum_impl/v2.rs:802）后落地：

- **conversation 频道是 driver-gated**，但**无人持席时完全放行**（门禁只在有
  活跃 holder 且非本端时拒绝 `not_driver`）；permission/ask/plan 应答**故意
  不设门禁**（v2.rs:800 注释），与 M3 行为一致。
- **协议层**：`driverClaimPath/driverReleasePath`（专用端点
  `/ringing/v2/sessions/{id}/driver/{claim,release}`）+ `RingingV2DriverClaimResponse`
  解析（already_holder / driver_busy / claim_requested 三种 reason）。
- **client 层**：`RingingClient.driverClaim/driverRelease`；**sendCommand 的
  assertAckMatches 收窄为仅 accepted 核对**——后端 not_driver 拒绝 ACK 的
  command_id 是空串，`requiredString` 会先炸成 missing_field（Ack.ets 已改
  optionalString 宽容解析）。
- **UI**：会话页底部输入框 + 发送/停止（停止 = `conversation_cancel`，
  turnActive 由 reducer 跟踪：输入置位、turn 终态复位、running 工具兜底）。
  提交流（`submitConversation`）：accepted 即成功；`not_driver` → 调 claim →
  重试（≤3 轮，claim_requested 后席位生效有短窗口）；`driver_busy` 如实上报
  不抢席。v1 不带 `driver_epoch`（门禁校验仅在显式携带时进行）。
- 测试：协议 37 / client 41 全绿；新装机验证通过（17:55 安装启动成功）。
- 坑：`-p module=a@default clean -p module=b@default clean` 只清一个模块——
  clean 必须逐模块单跑，否则 protocol 的 test_result.txt 不更新（本阶段被坑）。

### M6 增量（2026-10-06）：后端合并后重对拍 + HTTPS/配对/归属（设备身份）

触发点：后端 `main@82b3755` 并入 **Ringing v2 因果链修复**（`b44f84a`）与
**移动端 M0 设备鉴权**（`97be310`），交接文档「下一步 5」要求的重对拍到期。

**两处静默失效（已修，均有测试）**
1. `ringing.stream_terminated`（`axum_impl/v2.rs:596`，租约撤销/过期时逐事件复查后
   下发，随后服务端断流）。原 `EventStream.feedChunk` 对未知 eventType 一律抛
   `invalid_sse_event_type` 并**响亮硬停**——正常失效场景被当坏帧。现按单帧终止处理
   （listener 新增 `onStreamTerminated`，夹具无 schema/version，故
   `RingingV2StreamTerminated` 只校验 code/session_id）。
2. **命令 id 形态**：`causation_for_command`（`canonical/identity.rs:219` +
   `validation.rs:950 is_ulid_text`）只把 **26 位大写 Crockford** 的 id 原样送进因果链，
   其它形态（我们原来发的 `cmd-<base36>`）被 `ulid_from_text` = SHA-256 派生成**另一个**
   ULID，客户端原始 id 永不上线 → M3 的「等 `causation_id == command_id` 事件确认应答
   生效」永不命中。现协议层 `newCommandId()` 产 ULID 形态（时间戳 10 位 + 随机 16 位），
   三处调用点（InteractionCenter、Index 的 session_create 与 conversation 提交）统一走它。
   实测：真 daemon ACK 原样回显该 id。

顺带接线：`SessionMonitor` 构造时注册 `client.onLeaseLost → 重新协商`（M1 只上报、
上层从未接）；`scheduleRenegotiation` 现在也能被 `stream_terminated` 复用。

**wire 冒烟脚本（下一步 4 落地）：`scripts/wire-smoke.sh`**
对**真 daemon** 打鸿蒙用到的全部上行面并断言状态码/字段，38 项。已实测确认：
`/pair` 免 Bearer 且一次性（重放 403 `pairing_used`、伪造 403 `pairing_invalid`）；
设备身份未 `session_attach` 时 bootstrap 与 events 一律 **403 `forbidden_not_owner`**，
attach 后 200 且会话在 `session.list` 可见；吊销设备 → renew/reopen 401 且**在途 SSE
收到 `ringing.stream_terminated{code:"revoked"}`**；`--cacert <数据根>/tls/cert.pem`
对 `https://60.0.0.65:64413` 标准主机名校验通过。
跑法（隔离数据根，不污染本机 `~/.qaqh`）：
```bash
cd E:/qaqh-backend && USERPROFILE='C:\Users\tsy3m\AppData\Local\Temp\qaqh-wire' \
  HOME=/tmp/qaqh-wire ./target/debug/qaqh-daemon.exe server \
  --bind 60.0.0.65 --port 64413 --token 11            # 非回环=HTTPS，无明文开关
cd E:/qaqh-harmony && HOME=/tmp/qaqh-wire bash scripts/wire-smoke.sh
```
注意 daemon 数据根由 **USERPROFILE**（Windows canonical home）决定，`QAQH_DATA_DIR`
只能指向 `<home>/.qaqh`。

**传输与身份（下一步「QR/设备鉴权」的实现，PC 侧 QR 仍未实现）**
- 后端 `tls.rs`/`server.rs`（**未提交，需 review**）：自签证书 SAN 从固定两个 DNS 名改为
  `qaqh-daemon`+`localhost`+**bind IP**+**advertise IP**（`sans.txt` 记集合，变化即重签=
  全部设备重配对）。没有 IP SAN 时原生端只能关校验；有了它就能走标准信任链。
  单元测：`server_subject_alt_names_*`。
- `client/transport/TlsTrust.ets`：`caCertPem`→`http.HttpRequestOptions.caData`（API 20+）、
  `skipVerify`→`remoteValidation:'skip'`（API 18+，仅调试，UI 标红）。`HttpTransport`
  与 `HttpStreamConnection` 构造函数收 `trust?`（缺省 = 旧行为）。
- `protocol/wire/Pairing.ets`：配对四面（pairingTokensPath/pairPath + 请求/响应解析 +
  `WireErrorBody` 容忍非 JSON 错误体）。`client/PairingClient.ets`：
  `issuePairingToken` / `pair` / `pairWithAdminToken`，失败抛 `PairingError{code,status}`。
- **归属**：`RingingClientConfig.attachesSessions`（设备身份=true）；
  `RingingClient.attachSession()`；`SessionMonitor.bootstrapAndSubscribe` 在 bootstrap 前
  attach。归属按 `client_session_id` 记（`lease_store.rs:103 owns_session` 要求活跃），
  **每次重新协商都要重新 attach**——所以这一步必须在 monitor 里，不能只在 UI 点一次。
- entry：`config/DaemonAccessStore.ets`（设备凭证 + 证书信任持久化，preferences
  `qaqh_access`）；配置页加 证书 PEM/跳过校验/配对/清凭证；默认地址改 `https://`；
  有配对凭证时优先用它且 `attachesSessions=true`，否则退回手填 token（Admin 豁免归属）。
  列表页在设备身份下加「填 session_id 归属」入口（设备看不到未归属会话，空列表不再是
  「等桌面端开会话」）。
- **配对由设备自己完成**（PC 侧 QR 未实现）：配置页手填一次 Admin token →
  `PairingClient.pairWithAdminToken` 内部串 `POST /pairing/tokens` + `POST /pair`
  （令牌 TTL 120s，同进程串起来没有窗口问题）→ 存 device_token 并**立刻清空页面上的
  Admin 明文**。证书 PEM 需人工从 `<数据根>/tls/cert.pem` 贴进来（daemon 没有发证书的
  端点，pairing 只回指纹），存进 `qaqh_access` 后每次连接都用它走标准校验；
  `skipVerify` 默认 false，仅作调试兜底。

**测试**：协议 37→41、client 41→50 全绿；全工程构建 + 签名通过。

**后端遗留（本轮实测发现，别当已解决）**
1. `handle_renew_v2`（`v2.rs:129`）只做 `is_active_session`，**没过
   `caller_lease_bound_to_identity`**：A 设备的 token 配 B 的 `client_session_id` 仍能续
   B 的租约。冒烟脚本按现状断言 200 并标 `KNOWN-GAP`，补身份绑定后把期望改回 401。
2. 回执收敛缺口（影响「等因果事件」的设计）：折叠面只有
   `ToolFinished/InteractionResolved/InteractionExpired/DriverChanged/CompactionApplied`
   （`pending_store.rs:315-370`）；`TurnFinished` 有臂无生产者；纯文本
   `conversation_send_message` 无因果事件；`session_create` 等由 daemon 同步
   `mark_terminal(Succeeded)`，**永不出事件**——这类命令只能靠 `GET /commands/{id}`。
   `RECEIPT_TTL` 仍在（`pending_store.rs:552`，300s），`b44f84a` 提交标题里的「TTL 摘除」
   是错的（后端 `legacy-protocol-post-merge-2026-10-06.md` §四 已自我更正）。
3. `resolved_by` 不再是硬编码 "user"：设备应答归因为 `ActorRef{kind:"api",id:<device_id>,
   display_name}`；`/approvals` 对设备身份返回 `{challenges:[{challenge_id,...}]}` 不透明
   id（走 `approvals/respond`，与我们的命令应答路径并存，未接）。
4. InteractionKind wire 值已统一 `plan`（`types.rs:340`），鸿蒙侧本就按 `plan` 解析，无改动。

**下一步**
1. 手机重连（`hdc tconn <phone-ip>:<port>`，需手机端点允许）→ 装 HAP →
   配置页贴 `<数据根>/tls/cert.pem` 内容 → 配对 → 走三态全链路（这是 `caData`+IP SAN
   在 ArkTS 栈上的第一次真机验证，`skipVerify` 是兜底）。
2. 实况窗（LiveView）在 26 手机挂载验证；长时任务保 lease（continuous task）。
3. PC 侧 QR：`spec-daemon-auth-devices.md` §11 的二维码载荷仍只在文档里，daemon 无端点、
   CLI/webui 无调用者——要么补 PC 侧，要么继续用「Admin token 自举配对」。
4. `E:\qaqh-backend` 的证书改动待 review/提交；review 前别再改 `tls.rs` 的 SAN 集合
   （每次变化都会让已配对设备重新扫码）。

**真机首轮（2026-10-06 上午）：HTTPS + 配对 + 归属全部走通，另发现第三处漂移**
手机（60.0.0.99）经 `hdc tconn` 授权后装机：贴证书 PEM → 填 Admin token → 配对 →
连接 → 进会话，**`caData` + IP SAN 在 ArkTS 栈上标准校验通过**（没关校验、没 pin
指纹也连通了）。进会话后报 `invalid_control_delta_kind:driver_changed`：后端
`ControlDelta` 已有 **12 个变体**（`projection_event.rs:695-783`：
session_created/round/activity/tool_intent/tool_finished/interaction_{requested,
resolved,expired}/**driver_changed**/session_recovered/subagent_spawned/
subagent_finished），我们只认 7 个，其余**整条监视流被响亮硬停**——这正是 M0/M5.1
那类「假件全绿、真机炸」的第三次复发，而且 `driver_claim` 之后必现（冒烟脚本抓到的
那条 `stream_key: control:driver` 就是它）。

修法不是逐个补枚举（打地鼠），而是把**展示面策略**统一到 M3 对 InteractionBody
已定的那条：未知 kind 收下不显示、不断流，只有结构畸形才响亮失败；同时把漂移
**显式化**——`ControlDeltaKind.isKnown()` 全集外的一律填
`ProjectionPayload.unrecognizedControlKind`，UI 状态栏显示「未识别的控制事件：xxx
（已忽略，流未断）」，下一棒就不会再靠真机才发现后端加了变体。
`driver_changed` 本身做了强类型（`DriverChangedDelta{revision,holder?,driver_epoch}`，
holder 缺省=释放），会话页底部输入框上方显示席位归属（桌面端持席时手机发消息会
被 `not_driver` 拒，先说明比静默重试友好）。
测试：协议 41→43（driver_changed 夹具 + 未知 kind 容忍 + 已知未建模不误报漂移）。
`scripts/wire-smoke.sh` 增加 `sse_driver_changed_shape`：从真流里断言
`"kind":"driver_changed"` 确实出网。

### M7 增量（2026-10-06 中午）：正文换成 Timeline 通道（真机定性，推翻 M2 的数据源）

**症状**：手机进会话后「后端早就输出完了，移动端一片空白」；发新消息只停在
「已发送，等待回合开始…」。

**定性手段**：同一次发送，在同一个会话上**同时**挂两个订阅对照——

| 通道 | 实测内容 |
|---|---|
| `/events`（手机端原来唯一吃的） | 26 帧：`control_delta/tool_intent`、`conversation_delta/{input_accepted,tool_finished}`、`timeline_delta/{input,tool_result}`，**0 帧 text_delta** |
| `/timeline/events`（webui 吃的） | 534–816 帧：`turn_opened`、`block_opened`、**`text_delta` 数百条**、`block_checkpoint`、`block_sealed`、`round_sealed`、`turn_sealed` |

结论：**投影单流只带「整块终态」，逐字正文只在 Timeline 通道**。M2 那套
`TimelineDelta` 解析是照 Rust 类型定义写的，格式没错，但数据源拿错了；而且
`/events` 不回放下史（不带 cursor 订阅只收到 1 帧 replaceable 频道状态），所以
「进会话看不到历史」也是必然。webui 从不读 bootstrap 的 `conversation.state`
（`store.ts:347` 只用 `control.state.activity`），历史同样来自 timeline 快照——
所以我们 bootstrap 里 `conversation` 只存 raw **不是缺口**，缺的是整条 timeline 通道。

**新增代码**
- 协议层 `wire/Timeline.ets`：`timelinePath(limit,before_index)` /
  `timelineEventsPath(last_event_id)`（游标含冒号，**必须 URL 编码**）、
  `encodeTimelineCursor`/`parseTimelineCursor`（`{epoch}:timeline:{seq}`）、
  `TimelineTurn/Round/Block/Tool/Entry/Event/TimelineSnapshotResponse`。
  帧的 `version` 必须是 2：后端 `sse.rs` 注释里记着实测——写死 1 会让每帧被判
  协议违例、1s 重连死循环、正文永远渲不出来。
- 连接层 `TimelineStream.ets`：按 `timeline_seq` 水位去重；**发现空洞立即停手并
  重取快照**（中间帧不会补发，先渲就是缺口）；epoch 变更同等处置；陌生帧名不断流
  （M6 策略）；认 `ringing.stream_terminated`。`RingingClient.timelineSnapshot()`。
- 连接层 `TranscriptModel.ets`：快照 seed + 增量就地改（`text_delta` 追加、
  `block_checkpoint` 的 `arg` 是增量 / `text` 是整体覆盖、`tool_updated` 整块替换、
  `tool_progress` 追加进度），产出 `TranscriptItem`。**正文不再解 content ref**
  （服务端已摊平成字符串），所以 entry 的 `TimelineReducer.ets` 与那条 ref 回填
  路径一起删掉了。
- entry：`bootstrap → timelineSnapshot(50) seed → 从 watermark 订增量`；
  **每次重新协商都要重建正文流**——只 `prime` 水位会让它挂在已作废的旧租约上
  静默冻住（收不到帧也不报错，我第一版就写成 prime 了）；`加载更早的回合` 深翻页。
- 测试：协议 43→50、client 50→62 全绿；构建+签名通过；已装机。

**归属门禁的两处修正（推翻 M6 的笼统说法）**
- `/timeline` 未 attach 返回 **401 `lease_required`**（`attach the session before
  reading timeline`），而 bootstrap/events 是 403 `forbidden_not_owner`——码不同，别混。
- **timeline 两个端点都不豁免 admin**：`handle_timeline_snapshot`/
  `handle_timeline_events` 只看 `X-QAQH-Client-Session-Id` 的归属，不读 Identity。
  M6 里「admin 豁免归属」那句只对 `owns_session` 那条路径成立。

**后端两处已知问题（别当已解决）**
1. `handle_timeline_snapshot` 回填 `turn_index` 之后要过 `rehydrate_timeline_page`，
   已 offload 的回合被 sidecar 全文**整体替换** → 游标变 null（真会话实测 4 个回合
   全 null），深翻页断链。客户端按 `total_turns - 页长` 兜底（`oldestIndex()`），
   真修应在 daemon 侧 rehydrate 后重新回填。
2. 席位交接（`DriverChanged`）由会话 actor 异步落地，同一脚本两次跑出过「有」和
   「一次都没有」——所以 `wire-smoke.sh` 里它只报告不判红，线形由协议层单测
   （`driver_changed_delta_parses`）钉住。

**`scripts/wire-smoke.sh` 扩到 46 项**（本轮 46/46）：两条通道同拍对照
（`timeline_events_stream_delivers` / `timeline_cursor_shape` /
`events_channel_has_no_body`）、`timeline_before_attach` 401、租约保活循环
（TTL 只有 30s，订阅窗口不续期会让后面所有探测撞 `lease_required`——第一版就栽在这）。

**待真机确认**：手机上历史/流式是否如预期渲出；`truncated_before` 提示是否出现在
长会话；深翻页在含 offload 回合的会话上的实际表现；正文流与审批流两条 SSE 并存的
功耗（后续做 continuous task 保活时一起测）。

### M8 增量（2026-10-06 下午）：TUI 语义移植 + 横屏平板双栏 + 流式 O1 + Markdown

对齐用户指令：学 `E:\qaqh-tui-app` 做工具调用过滤与思考链折叠，横屏平板重设计
ask/permission/todo 面板，流式输出 O1 优化，markdown+高亮选型。**未动连接层/
协议线格式**（wire 面零改动，故未跑 wire-smoke；条目引用只读既有 TimelineTool 字段）。

**1）TranscriptModel 重写（client，纯逻辑可测）**
- 输出从「每次全表重算的 items()」改为**稳定行表**：`rowsRef()/structuralVersion()/
  drainDirty()/toggleExpanded()`。行实例跨重建复用（rowPool，rowId=turn:block），
  text_delta/tool_progress 只改对应行字符串并标脏——结构版本不动。
- 移植 TUI 语义：`isLookupTool` 连续同工具全成功 → **分组摘要卡**
  （「读取了 N 个文件（点击展开）」，展开即拆组，成员 soloExpanded 不许回组）；
  `isTodoTool`（todo_write/update/list 统一判定）→ write 解析 `{items:[{id,title,status,…}]}`
  成清单卡（任一条畸形整体作废回退普通工具卡），update 是 `{id,status,evidence?}` 单条
  delta 折叠进面板；面板 `todoPanelItems()` 全历史重放（write 替换、update 折叠），
  `orderTodoItems` 进行中→待办→已完成。
- 思考链：live 渲**尾部 3 行滚动窗口**（`tailLines`），sealed 折成「已思考 · N 行」单行
  （点击展开全文）；**空正文 sealed reasoning 不进历史**（TUI adapter 规则）。
- 工具正文：折叠预览 3 行——进行态取尾（滚动窗口）、终态取头（结局在开头），
  `hiddenLines` 如实供「… +N 行（点击展开）」。
- 进度缓冲对齐 TUI 纪律：MAX_PROGRESS_LEN 8192/保尾 6144，`tool_progress` 不再逐 chunk
  重建 TimelineTool（BlockView 自有 progress 字段）。
- `turnActiveValue` 改增量计数（runningTurns），不再每帧扫全表。
- 测试：client 62→**70 全绿**（分组/拆组/失败断组/思考窗口/空 reasoning/todo 面板/
  增量不 bump 结构/进度有界/行实例复用 prepend 共 8 新用例）。

**2）渲染侧 O1（entry）**
- `view/TranscriptVm.ets`：`@Observed RowVm` + `RowsDataSource implements IDataSource`——
  结构变化才 notifyDataReload；脏行按 revision 抄进复用的 RowVm，@ObjectLink 子卡自刷新。
- `TimelineView` 改 **LazyForEach**（key=rowId，cachedCount 8）；`Index` 侧
  `FLUSH_MS=150` 合并节拍（scheduleFlush/flushNow，tick++ 驱动视图 sync）；
  **贴底才自动滚**（onScrollIndex 记 atBottom，不被流式抢阅读位）。
- 展开/折叠（toggleRow）绕过节拍立即生效。

**3）横屏平板双栏（entry/pages/Index.ets + view/）**
- 会话页：顶栏 + Row{左正文列(layoutWeight 1) | 右 400vp 侧栏} + 底部 composer；
  `onAreaChange` 宽度 <720vp 自动退回竖排（分屏/手机友好）。
- `ApprovalPanel` 重写为**结构化三形态卡**（不再拍平字符串）：
  permission=风险/类别徽标+执行/原因/后果+**路径全列表可滚**（TUI 教训：截断路径误导影响面）；
  ask=多题分页（‹1/n›）+整行单选（折行不截断）+自定义输入+**全部答完一次提交**
  （first-answer-wins 下逐题提交会丢其它答案）+不作答；plan=Markdown 正文滚动+批准/拒绝。
  深链聚焦/高亮/Authenticator 门禁语义不变。
- `TodoPanel` 侧栏 sticky：done/total 头 + in_progress 置顶（黄底行）+ 预览 6 条
  「还有 N 项（点击展开）」+ **全完成即隐藏**（TUI compose_todo_panel 语义）。
- 工具卡视觉：语义色边框/底、类别字形（❯≡✎⌕❒☁☑◆）、动词+目标标题、状态徽标、
  错误/正文/展开分区（对齐 TUI 卡片头 `{标记} {动词} {正文} {徽标}` 形状）。

**4）Markdown/代码高亮（选型已定）**
- 调研结论（2026-10-06）：ohpm 上成熟可装的只有 **`@luvi/lv-markdown-in` 3.4.7**
  （纯 ArkUI、解析在 Worker、流式追加、代码高亮、MarkdownController 主题）；
  Ant 的 FluidMarkdown（API 15+，打字机模式最贴场景）尚无确认的 ohpm 包名，观望；
  `@ohos/markdown` 查无此包。兜底方案 markdown-it+highlight.js→StyledString 未启用。
- 已接入：assistant 正文（`AssistantText`）与 plan 审核正文用 `Markdown({ text })`；
  工具输出/思考保持等宽纯文本（终端输出按 markdown 渲是噪音）。
- 代价实测：HAP 从 ~8MB → **34.9MB**（@cangjie-tpc/prism_hybrid + formula_hybrid 的
  native .so）。若嫌重，后续可评估裁剪 LaTeX 依赖或改兜底方案。
- 依赖装在 `app/oh_modules`（`oh-package.json5` 已更新），真机构建/装机通过。

**真机首轮（部分）**：已装 60.0.0.99 并启动，配置页截屏渲染正常
（`smoke/screen-m8.jpeg`）。**待用户点「连接」走完：进会话看历史分组卡/思考折叠/
流式打字机（150ms 节拍是否顺滑）/侧栏三形态卡与 todo 面板/markdown 正文。**

**下一步（M8 后）**
1. 真机全链路目验（上表），重点：364 帧级 text_delta 下发热/掉帧；`@luvi` Worker
   解析在低端平板的 CPU 占用。
2. markdown 深水区：`MarkdownController` 定主题字号/代码块配色与 TONE 色板统一；
   代码块复制按钮接 pasteboard。
3. todo 面板若后端 dashboard 端点开放再切换数据源（现从正文流 todo 工具重放推导，
   长会话 tool_updated 时 O(blocks) 重放——可增量化，暂不急）。
4. M7 遗留照旧：keepalive 看门狗、深翻页游标、PC 侧 QR、continuous task。
5. LiveView/实况窗与两条 SSE 并存功耗仍未真机测（M5/M7 挂账）。

### M8.1 增量（2026-10-06 下午晚些）：鸿蒙设计原语迁移 + 动效打磨

触发点：用户真机截图验收后评价「毛坯房」。按 HarmonyOS Design 做了一轮系统性打磨。

**设计原语第一手资料（比文档站快且准）**
- 本机 SDK 就是权威：`command-line-tools/sdk/default/openharmony/toolchains/id_defined.json`
  （1059 色 / 1623 float / **4042 symbol** / 72 pattern / 250 media），
  或 `ets/build-tools/ets-loader/sysResource.js`（node require 直接查表）。
  **凡用 `sys.*` token 先在这里核对存在性**——`ohos_id_color_text_fourth`、
  `ohos_id_motion_duration_*` 这类「文档里见过」的名字实际不存在，踩过。
- `sys.color.ohos_id_*` **自动适配深色模式**（别手动引 `_dark` 变体）；
  float 关键值：圆角 default_xs4/s12/m18/l24/xl36、button20、text_field20；
  字号 body1=16/body2=14/body3=12fp。
- API 26 新增 `sys.pattern.*` 与 `@ohos.arkui.theme`（ThemeControl 运行时换肤），本轮未用。
- 官方组件库在 SDK 里：`@ohos.arkui.advanced.*`（ComposeListItem/Chip/SegmentButton/
  Dialog/SwipeRefresher/SplitLayout…全 token 驱动），要现成形态先翻它。

**落地（entry）**
- 新 `theme/QaqhTheme.ets`：色板单源。系统 token 为主；业务语义色（运行黄/成功绿/失败红）
  自定义集中放（系统没有 success 档）；**共享 MarkdownController**（`qaqhMarkdown()`）：
  行内代码去红、低饱和 CodeHighlight（One Light 系）、`setLazyRender` +
  代码块 >12 行自动折叠（流式长会话的 CPU 护栏）。注意：**个别 setter 返回 void，
  链式调用编译炸**（setTitleColor 在链上就是第一个受害者），逐条调用。
- 全部视图（TimelineView/ApprovalPanel/TodoPanel/SessionListView/Index 三态）
  迁移到 sys token + SymbolGlyph 图标（emoji 清零：工具类别 play_fill/doc_text/
  square_and_pencil/magnifyingglass/line_3_horizontal/cloud/list_checkmask；
  头部 exclamationmark_triangle_fill/questionmark_circle/list_bullet_square/
  lightbulb_1；按钮 paperplane_fill/pause_circle/chevron_left）。
- 动效（对齐鸿蒙运动规范，全部 API≤18 基线安全）：LazyForEach 条目进场
  `TransitionEffect.OPACITY+translate`（EaseOut 180ms）；展开/折叠 springMotion；
  列表 `EdgeEffect.Spring`；卡片 `clickEffect(LIGHT)`（系统按压反馈，比自绘 ripple 便宜）；
  ask 分页/选项切换 animateTo + spring；思考中/运行中 LoadingProgress 呼吸。
  曲线命名坑：没有 `curvesSmooth` 常量，用 `Curves.smooth()` / `curves.springMotion()`。
- 双栏折叠线按官方标准 **600vp**（md 断点），onAreaChange 驱动（原 720 改掉）。
- 真机修三处：顶栏状态文本改 layoutWeight+Ellipsis（原来被屏幕右缘裁字）；
  「运行中」徽标 `ohos_id_color_activated` 是**实心蓝**、叠 `text_primary_activated`
  （也是蓝）= 蓝字蓝底糊成一坨 → 改浅蓝底 `#1A3861FF`+蓝字（ask 选中项同步改）；
  todo 族工具卡不再 dump args JSON（模型侧 `fillBlockRow` 抑制 + todo_update
  头部给「T1 → 已完成」人话），回合标记本地化「— 回合 完成 —」。
- 验证：client 70/70；构建+签名；装机后 **hdc 驱动真机全流程截图核对**
  （`hdc shell uitest uiInput click <x> <y>` + `snapshot_display -f /data/local/tmp/x.jpeg`
  + `file recv`；坐标是 px=vp×density，这台 2800x1840 屏约 ×2.08；
  **Git Bash 会把 /data 路径转成本地路径，务必 MSYS_NO_PATHCONV=1 或整串引号**）——
  配置卡片→连接→列表→进会话 4 张截屏确认（smoke/n1-n4.jpeg）。
- 待办（下轮）：深色模式真机走查（token 自动适配，但自定义 tone 色未验深色对比度）；
  40 个空会话霸列表——daemon 侧 session 堆积，客户端可考虑折叠分组；
  行内代码红字在正文已修（`CodeHighlight.tag` 会被行内代码复用，别设红）；
  表格单元格内行内代码未穷尽验证。

### M9 增量（2026-10-06 傍晚）：从「监视器」到移动端前端——三 tab + Navigation 路由 + 悬浮胶囊 tabBar

触发点：用户拍板——定位不再是监视器，按移动端前端标准重做外壳；tabBar 对齐
华为应用市场形态（用户真机截图为参照），选型确认「会话/总览/设置」+ 悬浮胶囊。

**架构**
- `model/AppModel.ets`：业务逻辑全部出视图（连接/配对/轮询/监视/正文流/审批/
  flush 节拍），单例 `AppModel.instance()`；视图态经 **AppStorage 广播**
  （键名单源 `QaqhState`，写方只有 AppModel）。行数据不进 AppStorage——
  TranscriptModel/RowsDataSource 仍是引用注入，tick 键只当节拍信号（M8 O1 契约不变）。
- 有配对凭证时**启动即静默自连**（init 里 prime→loadDevice→connect），
  设置页降级为改配置的地方，不再是开机第一屏。
- `pages/Index.ets`：Stack{ Tabs(barHeight 0，纯内容滑动面) + 自绘悬浮胶囊 }。
  胶囊=居中圆角条 + `$r('sys.color.ohos_id_color_bottom_tab_bg_blur')` +
  `backdropBlur(36)` + SymbolGlyph 双态（选中 filled：ellipsis_message_fill/
  square_grid_2x2/gearshape_fill）+ 会话 tab 红点角标（cards.length）+
  BounceSymbolEffect 选中弹跳 + springMotion 切页；悬浮于安全区上方 20vp。
  通栏 bar 做不出悬浮形态，所以 barHeight 收 0 自绘；各页底部按
  `CAPSULE_BAR_SPACE(92vp)` 留位。
- `view/ConversationTab.ets`：**Navigation(Auto) + NavPathStack**——平板 Split
  双栏（左列表右详情）、手机 Stack 单栏 push；`navBarWidthRange([320,420])`；
  详情=NavDestination(hideTitleBar) + `.onHidden → exitSession()`
  （系统返回手势也收监视流，不只认自绘返回）。未连接=引导空态（去设置）。
- `view/SessionDetailView.ets`：M8.1 的双栏会话页原样迁出，全 @StorageLink 驱动。
- `view/OverviewTab.ets`：连接状态卡（wifi symbol/配对标签）+ 三统计卡
  （会话/运行中/待审批）+ 当前会话卡（回到会话）+ 运行中会话列表（点击直进）。
  **待审批只统计当前会话**——daemon 跨会话聚合面（/approvals 设备挑战）未接，
  如实标口径不做假聚合。
- `view/SettingsTab.ets`：连接/设备配对/证书信任三段卡。

**API 坑（本机 SDK 核对）**
- `BounceSymbolEffect(EffectScope.WHOLE, EffectDirection.UP)`——枚举名没有
  Bounce 前缀（BounceEffectScope 不存在）。
- Navigation 没有 `navBarSplitBehavior`；双栏时机交给 `mode(Auto)` + 断点。
- Tabs 的 `barOverlap` 通栏条配不了悬浮胶囊，barHeight(0)+Stack 叠层是正解。

**验证**：构建+装机；hdc 驱动真机走查 4 张（smoke/m9a-m9d.jpeg）——
启动即自动重连进列表、点会话出双栏详情（正文/侧栏/胶囊都在）、
总览统计卡（40 会话/7 运行中）、设置页键盘避让顶起正常。client 70/70 不变。

**下一步（M9 后）**
1. 手机竖屏走查（<600vp：Stack 单栏 + 胶囊收窄 + 详情堆叠布局）——本轮只在
   2800x1840 横屏验过。
2. 深链（通知 actionButtons）落点：现在 EntryAbility 广播 AppStorage，但冷启动
   落在哪个 tab 未编排（应直达会话 tab 并 push 对应会话）——qaqhTab 联动待做。
3. 总览「待审批」升真聚合：等 /approvals 设备面接通（M6 记录：不透明 challenge id）。
4. M7/M8 挂账不变：keepalive 看门狗、深翻页游标、PC QR、continuous task、
   实况窗功耗、深色模式走查、40 空会话列表折叠。

### M9.1 增量（2026-10-06 傍晚续）：右栏退役——授权中心弹窗 + 计划回消息流 + 左栏可折叠

用户拍板三件事，全部落地并真机走查（smoke/m91a-m91h.jpeg，client 71/71）：

1. **右侧信息栏移除**。授权改 **CustomDialog 中心弹窗**（`ApprovalDialog`，
   @CustomDialog + customStyle 自绘卡片 + 遮罩 rgba(0,0,0,.4)）：新 pending 到达
   自动弹出（只在**新请求到达**时弹，「稍后处理」压下去后不骚扰）；关闭留
   「N 项待授权」描边浮标（composer 上方右侧）重开；全部 resolved 自动关。
   数据源 @StorageLink(CARDS) 直连，卡片三形态（permission/ask/plan）沿用 M8 语义。
   深链 focus → 自动开弹窗 + 高亮 + scrollToIndex。
2. **计划不再占栏**：TranscriptModel 新增 `lastTodoRowId`——**最后一条 todo_write
   卡活渲染**（todo_update 折叠进面板后就地更新该卡），其余 todo 卡保持当时快照。
   `TodoPanel.ets` 删除，QaqhState 的 TODO_* 键退役。
3. **左栏 session.list 抽屉折叠**：详情顶栏 `rectangle_lefthalf_inset_filled` 钮，
   AppStorage `qaqhNavVisible` 单源（ConversationTab 与详情共用，避免 props 链失真），
   springMotion 动画。**坑（真机三轮才挖出）**：
   - `hideNavBar(true)` 会触发目的页**重排重挂载**，连带 `onHidden` 误杀在用的
     监视流（正文清空、activeSession 抹掉）→ 折叠改用
     `navBarWidthRange([0,0])+navBarWidth(0)`，hideNavBar 永不用；
   - 监视流清理从 `onHidden` 挪到 `onBackPressed`（return false 照常弹栈）+
     自绘返回按钮双写——onHidden 在 Navigation 任何重排时都会放炮，不可作路由清理点；
   - `TimelineView.aboutToAppear → dataSource.sync()`：@Prop tick 初始化不触发
     @Watch，重挂载不先 sync 会渲成空表（本轮真机两次踩到）。
4. 顺带修：**`ohos_id_color_primary` 是前景黑不是蓝**——用户气泡黑底黑字，
   改 `emphasize` 底 + `emphasize_contrary` 字（系统蓝气泡，深色模式自动反白）。
5. `QaqhState` 拆到独立文件 `model/QaqhState.ets`（视图引键名不再 import AppModel，
   防 ApprovalPanel↔AppModel 循环引用）。

**M9.1 后新增挂账**：uitest 真机点按坐标要用 dumpLayout 现取（顶栏布局一变就漂）；
弹窗内 ask 的键盘避让未验；窄屏（<700vp）composer 与浮标挤压未验。

### M9.2 增量（2026-10-06 傍晚续2）：竖屏单栏化 + 蓝底白字纠偏 + 折叠白屏陷阱封堵

用户竖屏截图报三事：创建会话按钮字色糊、用户气泡糊、竖屏拥挤。诊断+修复：

1. **竖屏拥挤根因**：竖屏平板宽 885vp 落在 Navigation Auto 的 md(600vp) 断点 →
   被判分栏 → 「左列表右一片空白」。修法：**不跟 Auto 的宽度断点走**，
   ConversationTab.onAreaChange 按**宽高比**判定：`w≥840 && w>h×1.15` 才 Split，
   否则强制 Stack（列表满屏、详情全屏 push）。判定结果放
   `QaqhState.SPLIT`，详情顶栏据此**只在分栏时显示折叠钮**。
   真机竖屏验证：s3（列表满宽）/s4（详情全屏、无折叠钮、气泡清晰）。
2. **`ohos_id_color_emphasize_contrary` 在这台设备渲染成蓝**（语义是"emphasize 的
   反向色"而非"白字"）——蓝底按钮/气泡全部糊字。全部改 `Color.White`
   （12 处，蓝底恒定所以白字深浅色模式都对）。教训：**contrary 系 token 慎用，
   真机看效果**；`text_primary_contrary` 才是"底上反色文字"（白）的那个。
3. **折叠白屏陷阱**（用户第一张全白截图）：navVisible=false 持久在 AppStorage，
   叠回无 destination → 列表收起+无处可点。三通道封堵：退回单栏时强制
   navVisible=true；自绘返回/onBackPressed 都恢复抽屉；Stack 下折叠钮不出现。
4. 设备侧备忘：HarmonyOS 没有 `settings put system user_rotation`，远程转屏不可用，
   横屏回归只能用户手转。

**M9.2 后挂账**：横屏 Split 回归（转屏不可远程，等用户验）；深色模式走查。

### M9.3 增量（2026-10-06 15:35）：底部小白条沉浸式

病灶：窗口没开全屏布局，系统导航条区域由框架垫白底——内容再灰也压不住那条白。
修法（EntryAbility.onWindowStageCreate）：`setWindowLayoutFullScreen(true)` +
`getWindowAvoidArea(TYPE_SYSTEM)` 把顶/底安全区（px÷densityPixels 换 vp）回灌
AppStorage（qaqhSafeTop/qaqhSafeBottom/qaqhCapSpace），`on('avoidAreaChange')`
跟转屏实时更新。消费端：Index 根 Stack padding top=safeTop、胶囊
margin bottom=safeBottom+14；四个页面的 `CAPSULE_BAR_SPACE` 常量全部换成
@StorageLink(CAP_SPACE)（默认 88）。真机横屏验证通过（smoke/s6-immersive.jpeg）：
内容铺到导航条下、胶囊浮在指示条上方、顶栏不再被状态栏压。





1. 真机验正文：进会话应立刻看到历史回合（用户问 + 思考 + 回答 + 工具卡），发消息
   应看到逐字流；随后验审批闭环与驱动席文案。
2. 无超时后的静默死亡兜底：timeline/投影两条流都需要 keepalive 看门狗（例如 45s
   没收到任何字节就主动 cancel 重连）——现在只依赖服务端断流与 lease 复查。
3. 深翻页游标：等后端把 `turn_index` 在 rehydrate 后重新回填（或我们改读
   `created_seq`），再把它从「兜底推算」升为断言。
4. PC 侧 QR（`spec-daemon-auth-devices.md` §11）仍未实现；现在设备自己用 Admin token
   走 `/pairing/tokens` + `/pair` 自举。
5. 长会话滚动的渲染开销：现在每个增量都重算整表 `items()`，实测 364 条
   text_delta 下需要观察（必要时按块脏标记局部更新）。


### M6 遗留的 ArkTS 侧踩坑（仍有效）
- `commons/protocol/src/main/ets/Index.ets` 里 **函数具名再导出**（
  `export { requiredString } from './wire/Json'`）会报 `10504006 Re-exporting is not
  allowed when the target is a function`；`export * from` 是允许的（Json 的守卫函数
  因此仍可由 `@qaqh/protocol` 具名导入）。新模块 `wire/Pairing.ets` 照此走 `export *`。
- 脚本化 ACK 必须回显**请求里**的 command_id：`newCommandId()` 现在是每次现生成的
  ULID 形态，测试里写死 id 会撞 `assertAckMatches`（`%CMDID%` 占位模板）。
- 真机踩坑（M7）：`export * from` 的**两个模块导出同名类会直接编译失败**
  （`has already exported a member named 'TimelineBlock'`）——投影 delta 的
  `TimelineBlock` 与新 timeline 通道的 `TimelineBlock` 撞了，按 Rust 真名把前者
  改成 `TimelineDeltaBlock`（Rust 侧本来就是 `TimelineDelta::Block`）。
- 测试里**不允许嵌套函数**（`arkts-no-nested-funcs`）：`describe()` 回调内再定义
  `function helper()` 会挂，夹具工厂必须提到模块作用域。
- 手写转义 JSON 当夹具是陷阱：括号错一处报 `bad_json`，看着像「协议不符」。
  timeline 两套测试改成 `Record<string, Object>` 构造 + `JSON.stringify`；
  注意字面量里**再嵌一层对象**也要先声明成 `const x: Record<string, Object>`
  （`arkts-no-untyped-obj-literals`）。
- daemon 的租约 TTL 只有 30s：任何「订阅 + 等多轮模型往返」的脚本都要显式续期，
  否则后半段全是 `lease_required`，看起来像协议错。
- 冒烟脚本里的 daemon 数据根跟随 **USERPROFILE**（不是 QAQH_DATA_DIR——它被校验成
  必须是 `<home>/.qaqh`）。想隔离测试就临时改 USERPROFILE，否则会动到本机真实数据根，
  并且会**重签那里的自签证书**（SAN 集合变化即重签）。注意：隔离根里没有
  `config.toml`（模型 provider），跑不出真实正文——timeline 那几条断言必须在真实根上跑。









### M12 增量（2026-10-07）：跨会话待审批真聚合 + 防串频

后端基线：qaqh-backend `2.0.0-beta.3`（`main@ee40274`）。路由面与 `21b0a54` 零变化；
服务面新增 `session.set_profile`；`/approvals` 快照与 `/approvals/respond`（challenge
面）早已存在，本轮接入鸿蒙。

**后端 /approvals 契约（axum_impl/v2.rs + challenge.rs，逐行对拍过）**
- `GET /sessions/{id}/approvals` 要求 `require_lease_on_session`：device 身份 = 租约
  **attach 归属该会话**（admin 任意活跃租约即可）。快照**每类至多一条**
  （`find` 不是 `filter`）：`{pending_permission, pending_interaction}`。
- device 快照 = `{challenges:[{challenge_id(64hex), kind, expires_in, details}]}`，
  canonical id 不出 daemon；admin 快照 = canonical 透传（permission 带tool_call_id）。
- `POST .../approvals/respond`：`{challenge_id, decision, payload?}`，challenge
  **与会话绑定 + 一次性消费**（scope 错也消费掉，防跨 seed 重放枚举）；
  decision：permission=approve/reject/trust（device 提交 trust 被服务端降级
  trust_folder=false）、ask=submit{answers}/dismiss、plan=approve/reject。
- **一条租约可 attach 多个会话**（lease_store `session_leases: HashMap<cs, HashSet<seed>>`）
  ——单个聚合 client 覆盖全部运行中会话，不需要每会话一条租约。
- 应答不受 driver 门控（v2.rs:800 语义不变）。

**实现**
- 协议层 `wire/Approvals.ets`：approvalRespondPath + `ApprovalKind`/`ApprovalDecision`
  + `RingingApprovalItem`（device/admin 两形状自动判别归一化）+ respond 请求体。
  details 原样保留（展示面容忍），顶层形状错才响亮失败。测试 +7（64 全绿）。
- client 层：`RingingClient.approvalsList/approvalsRespond`（后者本地先校验 decision）；
  `PendingInteractionView` 扩展 `sessionId/wireId/remote`（live 条目也带上 sessionId）。
  测试 +3（82 全绿）。
- **AppModel 聚合器**：独立聚合 client（`harmony-approve-*`，第三条租约），attach
  全部 running 会话（device 身份），6s 轮询 `/approvals`，串行单飞；租约丢失自动
  重开+重放 attach（循环不死）。`CARDS` = 实时流卡片 + 远程卡片合并。
- **防串频五道防线**：
  1. 服务端 challenge 会话绑定 + 一次性消费（协议层兜底）；
  2. 条目不可变绑定 `(sessionId, wireId)`，应答永远打到条目自带的会话路径，
     绝不经过「当前会话」全局态；本地唯一键 `sessionId#wireId`
     （ForEach/去重/深链全用它）；
  3. 每会话单一数据源：**当前监视会话不进聚合轮询**（审批由 InteractionCenter
     实时维护），enterSession 时同步清该会话的远程卡片与抑制窗口；
  4. 展示绑定：聚合卡片与总览行都带「来自会话 · {模型名/短id}」徽标；
  5. 应答成功后该会话抑制 8s 轮询窗口（challenge 已消费但投影落地有延迟，
     防同一挂起换了张新票闪回）。
- 应答路由：device → challenge 端点；admin（手填 token）→ 命令通道
  （envelope.sessionId = 条目会话，wireId = canonical id）。批准动作照旧过
  Authenticator 门禁。远程条目正文：details 补 `kind` 鉴别键后复用
  `InteractionBody.parse`（ask/plan/permission 三形态渲染不变）。
- UI：OverviewTab「待审批」升真聚合口径 + 待处理授权列表区（点击进对应会话，
  监视流接管后弹窗自动弹）；ApprovalDialog 卡片带会话徽标；LiveView 胶囊
  语义不变（仍只反映监视会话，避免跨会话计数干扰回合窗让位逻辑）。
- `teardownMonitor` 不再无条件清 CARDS（远程卡片跨会话存活）；disconnect 全清。

**验证**：protocol 64/64、client 82/82 全绿；全工程构建 + 签名通过。
**未验证（真机）**：双会话并发出审批的聚合展示、跨会话应答端到端
（challenge 路径第一次真机打）、聚合轮询与双 SSE + 15s 列表轮询的功耗叠加。

**挂账**：wire-smoke 补 approvals 两用例（attach 后 GET 200 + 票错会话 403
`approval_scope_violation`）；`session.set_profile` 尚未进 SDK 契约；后端
`control.rs` 的幽灵 interaction 清理（未提交）落地后，监控流的 pending 撤卡
路径要重对拍（那批清理不发明文 delta，靠重协商收敛）。

### M13 增量（2026-10-07 续）：title 接入 + 大消息防打爆 + 内存探针

**1）会话标题接入（G2 口径）**
- 后端 `SessionMeta.title`（首轮后 LLM 生成一次即冻结）一直在 wire 上，鸿蒙解析器
  此前没取。`wire/SessionList.ets` 新增 `title`/`cwd` 字段 + `displayTitle()`：
  `title → cwd 尾段 → 短 id`，镜像后端 G2 三档回退；`last_summary` 仍只当预览行
  （后端注释明确它不参与标题——TUI 踩过的「标题随对话漂移」坑）。
- 展示点全换：列表卡标题（模型名挪副行）、总览运行中行、审批卡片/通知的会话徽标。
  多会话同模型从此可分辨。测试 64→65（回退链夹具：空 title、Windows 路径、短 id）。

**2）大消息防打爆（数据面 + 渲染面）**
裸奔点定性：`text_delta` 在 `TranscriptModel` 是 `block.text += delta` 无界累积，
三条代价随消息大小线性涨——内存驻留（整会话不释放）、每 flush `countLines` 全文
扫描、Markdown Worker 每 150ms 全量重 parse。修三层：
- **硬上限**：正文/思考块 128K chars 超限**保尾**（流式期看的是生成中的尾部）96K，
  丢弃段头插「……（前文过长已省略，完整正文见桌面端）」（timeline 正文服务端已
  摊平，没有 ref 可回拉，截断是如实语义）。`BlockView.appendText/setText` 收口
  全部 text 变更点。展开态工具正文另有 64K 显示上限（tool.output 服务端可能未截）。
- **行数增量维护**：`BlockView.lineCount` 增量更新（非空文本 = 换行数 + 1，基线
  坑测试抓过），`countLines` 全文扫描退出每 flush 路径（只剩覆盖/截断重置）。
- **流式 Markdown 降级**：live 且 >8192 chars 的 text 行不喂 Markdown Worker，
  渲等宽 Text 尾窗（40 行，对齐思考链窗口语义）+「长文流式预览」标注；sealed 后
  一次性全文 Markdown（有 128K 硬上限兜底 + setLazyRender + 代码块折叠）。
- 测试 +2（截断保尾/有界/继续追加不炸；行数缓存与全文扫描同口径），client 84 全绿。

**3）内存探针（补「有没有做」的欠账）**
- `entry/perf/MemoryProbe.ets`：`@kit.PerformanceAnalysisKit` 的 hidebug 采样
  PSS / native heap allocated / 峰值 PSS，5s 一拍；hilog（domain 0 tag `QaqhMem`）
  落账后接 DevEco Profiler 对时序，AppStorage（qaqhPerfPss/Native/Peak）进
  设置页「内存探针」调试卡。init 即开表；hidebug 抛错（受限环境）静默停表。
  **坑：d.ts 返回 bigint（字节）**，ArkTS 下 `Number(...)/1024` 转 KB。
  `sys.symbol.gauge` 不存在（只有 `gauge_with_dots_needle_33percent` 固定档），
  调试卡标题不带图标。
- 真机回归路径：跑一次 1MB 单条消息场景，探针数字 + DevEco Profiler CPU 曲线
  即可验证三层护栏的实际效果（M8 的「364 条 text_delta 待观察」从此有仪表）。

**验证**：protocol 65/65、client 84/84 全绿；全工程构建 + 签名通过。
**未验证（真机）**：标题上屏、截断提示观感、降级视图切换时序、探针读数合理性。

### M13.1 增量（2026-10-07 续2）：内嵌 Cascadia Mono 等宽字体

- **字体获取**：GitHub 直连与 gh-proxy 均被网络策略挡住；`@fontsource/cascadia-mono`
  只有 woff2（@ohos.font 只吃 ttf/otf），最终走 **`@expo-google-fonts/cascadia-mono`**
  npm 包（expo 系打包 TTF）拿到 `CascadiaMono_400Regular.ttf`（412KB）。
- **许可**：SIL OFL 1.1 允许内嵌；许可文本随包入 `rawfile/fonts/OFL-CascadiaMono.txt`
  （Reserved Font Name 约束 = 不改字体内容、不改名）。
- **注册**：EntryAbility.onWindowStageCreate →
  `getMainWindowSync().getUIContext().getFont().registerFont({familyName:
  'CascadiaMono', familySrc: $rawfile(...)})`（API 18 起模块级 registerFont
  deprecated，UIContext 版 since 12）。失败仅 hilog 记账不阻塞启动。
- **消费**：`QaqhTheme.MONO_FAMILY` 单源，6 处 `fontFamily('monospace')` 全部替换
  （工具输出/错误/长文降级视图、审批路径列表、总览会话 id、设置页探针读数）。
  中文字形不在 Cascadia 覆盖范围，缺字按 glyph 回落系统字体，中英混排无豆腐块；
  本 SDK 的 Text.fontFamily 属性没有多族回退重载，注册失败该点会落默认字体
  （有 hilog 可查）。
- **体积**：HAP 34.9 → 35.9MB（字体 412KB + 签名增量）。可变字体刻意不用
  （ArkUI 对字重轴映射不可靠，选静态 Regular）。
- 验证：全工程构建 + 签名通过，字体确认进 HAP。**未真机验证**：等宽观感、
  混排基线对齐、注册失败回退路径。
