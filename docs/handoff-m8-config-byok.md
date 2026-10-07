# Handoff — M8：跟进后端 BYOK/provider 重构（config/profile 服务面接入）

日期：2026-10-06
状态：**SDK 层（@qaqh/protocol + @qaqh/client）完成并全绿**；entry UI 尚未接
config 面（见文末"未做"）。
后端基线：qaqh-backend `main@21b0a54`（merge: refactor/sdk-gate-and-byok，
即后端 `docs/handoff/sdk-gate-byok-2026-10-06.md` 所述那轮 provider 重构）。

## 一、后端改了什么（与鸿蒙相关的部分）

后端那轮重构的权威交接在后端仓 `docs/handoff/sdk-gate-byok-2026-10-06.md`，
其中 **§五"给仓外消费者的契约变更"** 点名 harmony。要点：

- provider 预设体系整体退役：`providerId`、预设 endpoint id、`providers` 目录
  都不在 wire 上了；`endpoint` 一词现在指 URL 本身 = `baseUrl`。
- 配置面收口 **BYOK 六字段**：`baseUrl` + `wire`（`openai|responses|anthropic`，
  必填）+ `model` + `maxTokens` + `contextLength`（本地压缩唯一分母，替代旧
  `contextLimit`）+ apiKey（永不出 daemon，只有 `"****"`/空串掩码标记）。
- `config.load` 回 `ConfigDto`（camelCase、**不做向前兼容、缺字段即解析失败**）；
  `config.save` 收 `ConfigPatch`（JSON Merge Patch：每字段独立 Option，缺失 =
  不动；**发旧键不报错但被 serde 静默丢掉**——写不动，键名必须逐字对齐）；
  `profile.apply` 切 profile = 切端点。
- 服务面方法表（`qaqh-runtime/ringing/service_methods.rs`）：`config.load`(Read)、
  `config.save`(Write)、`config.set_permission_level`(Write, `{level}` 1..=3)、
  `profile.apply`/`profile.save_current`/`profile.delete`(Write, `{name}`)。
  错误回包 HTTP 4xx `{code,message}`（Read→`query_failed`，Write→`action_failed`）。
- 鸿蒙 SDK **已消费**的 wire 面（bootstrap / timeline / interaction / session.list /
  pairing）在该轮合并中**零变更**（diff 实证：qaqh-ringing / qaqh-types 的
  SessionListEntry / qaqh-domain / runtime ringing 均未被动）；timeline 失败码
  仍是字面量 `model_request_failed`（后端把它结构化为 ErrorKind 是待点头项）。

## 二、SDK 本轮跟进内容

### @qaqh/protocol
- 新增 `wire/Config.ets`：
  - `RingingConfigDto.parse` —— 镜像 `ConfigDto` 序列化形状（camelCase 全字段
    required，`lang`/`theme`/`tokenizerPath` null→undefined；`mcp`/`lsp` 只验存在
    不展开）；`subagent` 段镜像 `SubagentDto`。缺字段抛 `ProtocolError('missing_field')`。
  - `RingingConfigPatch` —— Merge Patch 写模型：未赋值字段不出 wire；
    `validate()` 与后端 `ConfigPatch::validate` 同域（wire 三值、maxTokens/
    contextLength>0、autoCompactThreshold∈[0,1] 且 0=关、effort 五值、
    permissionLevel 1..=3）。
  - `ConfigWire` —— wire 值域常量。
  - `Json.ets` 新增 `requiredStringAllowEmpty`（apiKey 掩码/fontFamily）与
    `requiredStringArray`（`Vec<String>` 严格条目校验）。
- 刻意不建模（留待有消费面再做）：`subagent` 写侧嵌套补丁、`mcp`/`lsp` server 展开。

### @qaqh/client
- `RingingClient` 新增：`configLoad()` / `configSave(patch)`（本地先 validate，
  非法补丁不出端）/ `applyProfile(name)` / `saveCurrentProfile(name)` /
  `deleteProfile(name)` / `setPermissionLevel(level)`。
- 新增 `ServiceRpcError {code, status}`：服务面 4xx 且 body 为 `{code,message}`
  时抛出（UI 可直接展示 message 并按 code 分支）；body 解不出该形状退回
  `TransportError`，与其它端点失败形态一致。

### 测试
- `protocol/src/test/ConfigContract.test.ets`（5 例）：完整 ConfigDto 形状解析
  （夹具与后端 qaqh-config-api 测试逐键一致）、缺字段响亮失败、旧 provider 形状
  必须解析失败、Merge Patch 只序列化已赋值字段、值域校验与后端同域。
- `client/src/test/ConfigRpcContract.test.ets`（6 例）：config.load 空体 POST +
  解析、config.save 只发改动字段、非法补丁本地拦截不出端、4xx `{code,message}`
  → ServiceRpcError、profile.apply 正反两路、permissionLevel 本地校验。
- 本地 `hvigorw test` 全绿：**protocol 56 例 / client 82 例，0 失败**；
  protocol / client assembleHar、entry assembleHap 均通过
  （工具链：command-line-tools@6.1.1.418，test 任务本地可跑、无需设备）。

## 三、UI 侧对接指引（entry 尚未接）

- 读取：`client.configLoad()` → 直接渲染六字段；`apiKey === "****"` 表示已配置。
- 保存：只把用户改过的字段塞进 `RingingConfigPatch`（不要整包回填——后端是
  Merge Patch，发掩码 `"****"` = 保持现值）；`wire` 下拉取 `ConfigWire` 三值；
  错误处理：`ServiceRpcError.message` 可直接展示，`code` 判 `action_failed`/
  `forbidden`。
- 切换端点：`profiles` 数组做下拉 + `applyProfile(name)`。
- 设备令牌即可调用（服务面方法表对已鉴权身份开放，不要求 session attach——
  这些方法 `requires_session: false`）。

## 四、未做 / 欠账（M8 时点）

1. entry 未加 config/端点管理 UI（本交接 §三 是对接指引）。
2. `scripts/wire-smoke.sh` 未加 config.* 上行面用例——建议起真 daemon 后补
   `config.load`（200 + 含 `wire` 键）与 `config.save`（发 `{"wire":"grpc"}` →
   400 `action_failed`）两条，防契约漂移。
3. 后端侧两项待点头（不阻塞本仓）：`TimelineFailure.code` 结构化为
   ErrorKind；届时鸿蒙 `wire/Timeline.ets` 的 failure.code 消费点要跟。
4. 真机/真 daemon 端到端一次 config.load（本轮验证止于契约夹具 + 本地单测）。

---

# Handoff — M10：结构化失败码贯通 + 设置页接 config API（2026-10-06 续）

状态：**完成**。M8 欠账的 #1（设置页）与 #3（结构化失败码）本轮收掉；
#2（wire-smoke 补用例）与 #4（真机端到端）仍欠。

## 一、TimelineFailure.code 结构化（后端 + 鸿蒙两侧）

- **后端**（`E:\qaqh-backend`，`main` 工作树未提交改动）：`engine_turn.rs` 的
  模型请求失败槽从字面量 `"model_request_failed"` 改为 `gate_error.kind.as_str()`
  （mutil-ai ErrorKind 的稳定 snake_case 码）；仅本地构造失败（request_error，
  请求未到 gate）保留历史字面量兜底。工具侧失败槽自有码（`tool_denied`/
  `duplicate_tool_call` 等）不受影响。`cargo test -p qaqh-runtime --lib` 258 全绿；
  clippy 无新告警（qaqh-types/sbx-win 的 3 条是既有基线）。
  **需要后端仓把这一处改动收编提交**（改动只有 engine_turn.rs 一处）。
- **鸿蒙**：`wire/Timeline.ets` 新增 `TimelineFailureCode`（gate kind 全集常量 +
  `isKnownGateKind()`）；展示面容忍策略不变——未知 code 照常收下展示 message，
  按码分支只对已知值做。UI 尚无 failure 消费点，将来渲染失败状态时直接用该表。
  契约测试 `timeline_failure_code_is_structured_error_kind` 收进 TimelineContract。

## 二、设置页接 config API（entry）

- `QaqhState` 新增 `qaqhCfg*` 键 14 个；`AppModel` 新增
  `loadDaemonConfig(force)` / `saveDaemonConfig()` / `applyDaemonProfile()` /
  `saveDaemonProfile(name)`（全部走列表 client 的服务面 RPC，连接成功后自动
  强制读一次；aboutToAppear 幂等补读）。
- `SettingsTab` 新增两张卡片：
  - **模型端点**：model / baseUrl 文本框、wire 与推理力度 Select（值域与后端
    校验同域）、maxTokens / contextLength、apiKey 掩码展示（"已配置（****）"）
    + 新密钥输入（留空 = 保持现值）；保存 = 只把**与快照不同**的字段合成
    Merge Patch（`configSnapshot` 存最近一次 config.load 的权威值），成功后
    自动重读权威值；非法补丁被 client 本地 `validate()` 拦截不出端。
  - **配置档案**：当前档案展示、profiles 下拉、应用所选档案（= 切端点）、
    当前配置存为具名档案。
- 错误展示：`ServiceRpcError.message` 直接进 cfgStatus（后端 validate 文案，
  如 "contextLength 必须大于 0"）。

## 三、验证台账（M10）

- 后端：`cargo test -p qaqh-runtime --lib` 258 通过；clippy 无新告警。
- 鸿蒙：protocol 57 例 / client 82 例本地 hypium 全绿（无失败输出）；
  protocol / client assembleHar、entry assembleHap 编译通过。
- 未验证：真机/真 daemon 端到端（设置页实机读写 + 结构化失败码上屏）、
  wire-smoke 的 config.* 用例。

## 四、UI 打磨（M10 续）：壳层形态收敛

新增 `view/UiKit.ets` 作为壳层界面统一形态基元（此前卡片圆角/内边距/阴影、
按钮尺寸散在各视图手写，形态漂移）：

- **基元**：`Card`（圆角 20 / 内边距 16 / 浅阴影 / 起始对齐，@BuilderParam
  收内容）、`SectionHeader`（卡内区块标题，可选图标）、`PrimaryButton` /
  `GhostButton`（统一高度 40 / 胶囊圆角 999 / 字号 14 / 点按反馈；`weight`
  与 `active` 走 @Prop——**自定义组件不支持外部链通用属性**，`enabled` 还是
  基类保留名，这两个坑踩过一遍）。常量：`CARD_RADIUS=20`、`PILL_RADIUS=999`、
  `INPUT_HEIGHT=44`、`BUTTON_HEIGHT=40`。
- **SettingsTab** 整页重排为四张 Card（连接 / 模型端点 / 配置档案 / 设备配对 +
  证书信任），输入框统一 44 高 + 14 圆角 + `list_card_bg` 底，下拉行统一
  「72 宽标签 + Select」@Builder。
- **OverviewTab**：统计卡图标加强调色 10% 圆片（`#140A59F7`，深浅色皆可读）、
  运行中会话行加分隔线、卡片统一走 UiKit。
- **SessionListView**：修掉卡片宽度不对称（`width('94%') + margin left 12` →
  List 统一 16 边距、卡片满宽）、状态徽标胶囊化 + 运行中改强调色系、
  顶部按钮走基元、空态加内边距。
- **SessionDetailView**：composer 浮岛化（输入/停止/发送收进 26 圆角浮卡，
  输入框胶囊化）、返回钮/会话 chip/加载更早按钮胶囊化。
- **Index 胶囊栏**：选中项加强调色 8% 软底高亮。
- 颜色全部继续用系统 token + 既有 alpha 叠加模式（深浅色自适应不变）；
  **正文字渲染（TimelineView 气泡）刻意未动**——阅读宽度与气泡形态是 M8
  定的契约，且没有实机目视前不宜盲调。
- codelinter 对 UiKit 报 4 条 `avoid-overusing-custom-component` warn：
  Card 需要 @BuilderParam、按钮需要内部 prop，属有意为之，不处理。
- **未验证（同上）**：真机目视回归。有设备后建议跑一遍三 tab + 详情页
  深浅色两套。

---

# Handoff — M11：扫码配对 + 凭证入关键资产（2026-10-06 续二）

对应 M10 UI 打磨后用户拍板的前两项能力（AI 智能体接入调研另见
`docs/research-xiaoyi-agent.md`，暂缓）。

## 一、扫码配对（Scan Kit）

- **桌面端零改动**：webui 设置页的设备配对本来就会签发 120s 一次性配对票并
  渲染二维码（`webui/src-tauri/src/pairing.rs` 的 `pairing_create`，payload =
  spec §11 JSON：`v/kind/base_url/pairing_token/tls_fp/host_name`，逐键核对过）。
- 鸿蒙侧：
  - `wire/Pairing.ets` 新增 `PairQrPayload.parse`——`kind`/`v` 严格校验（扫到
    别的码报 `not_pair_qr`，不误当配对票），`base_url`/`pairing_token` 必填。
  - `PairingClient.pairWithQr(transport, qr, deviceName)`（静态）：直飞 payload
    自带的 baseUrl 走 `/pair`；scope 由桌面端 grant 决定，本端不带 scope_grant。
  - `AppModel.pairViaScan()`：`@kit.ScanKit` 的 `scanBarcode.startScanForResult`
    拉系统扫码 UI（`scanCore.ScanType.QR_CODE`），成功后走既有 saveDevice/
    refreshPairedLabel 流程，并把 BASE_URL 切到 payload 地址。
  - SettingsTab 配对卡改为「扫码配对」主按钮 + 「手动填 Admin token」降级为
    次按钮； CAMERA 权限已加（`ohos.permission.CAMERA` + reason 文案）。
- **TLS 语义如实标注**：QR 里的 `tls_fp` 是证书指纹，但 NetworkKit http 只支持
  `caData`/`skip`，做不了指纹 pinning——扫码配对沿用本机既有信任设置（导入
  PEM = 标准校验；都没有 = 自签端点握手失败，UI 提示先导入 PEM）。UI 文案
  已写明。将来换 RCP 传输层时可以补 pinning。

## 二、deviceToken 入关键资产（Asset Store Kit）

- `DaemonAccessStore` 重构：**device_token 存 `@kit.AssetStoreKit`**（alias
  `qaqh.deviceToken`，`ACCESSIBILITY=DEVICE_FIRST_UNLOCKED`——开机自动重连
  需要的最低等级），系统级加密、不随普通备份导出；deviceId/scope/baseUrl/
  证书 PEM 仍走 preferences。
- **一次性迁移**：`loadDevice()` 发现 preferences 里的旧明文 `device_token`
  键即搬入关键资产并删明文键；关键资产不存在时 `querySync` 报错按"无凭证"
  幂等处理。
- 写路径 add 失败（重配对已存在）走 `updateSync(aliasQuery, attrs)`——注意
  asset 的 `updateSync` 是**双参**（query + 待更新字段），`getSync` 不存在
  （用 `querySync`），SDK d.ts 核对过的两个坑。

## 三、验证台账（M11）

- protocol / client hypium 全绿（新增 2 例：`pair_with_qr_uses_desktop_base_url_and_token`、
  `pair_qr_rejects_foreign_code_and_missing_token`）；entry assembleHap 通过。
- **未验证（真机）**：系统扫码 UI 实机调用、CAMERA 运行时授权弹窗、关键资产
  的写入/读取/重配对 update 路径、老数据迁移——asset 与 scan 都是设备 API，
  本地单测覆盖不到，需真机回归。

---

# Handoff — M11.5：实况窗深化「回合进行中」胶囊（2026-10-06 续三）

即能力清单第 7 项（Live View Kit 深化），把"电脑正在干活"做成系统级存在感。

## 设计与实现

- `LiveViewNotifier` 重构为**双视图管理器**：状态源（pendingCount/turnActive +
  各自 detail）与 kit 调用解耦，统一走 `reconcile()` 对账——两条更新通道
  （`updatePendingCount` / `updateTurnActive`）各自 setState，reconcile 负责
  把 start/update/stop 落对。每个视图独立递增 sequence（满足「更新版本号必须
  更大」），id 分离：审批窗 `0x1D60`、回合窗 `0x1D61`。
- **并存规则**：审批窗在场时回合窗让位（锁屏不挂两个胶囊）——`applyTurn`
  的显示条件是 `turnActive && pendingCount <= 0`。审批处理完（count→0）而
  回合还在跑时，回合窗自动补位出现；`stop()` 语义升级为两条全收。
- `AppModel` 挂点：
  - `flushNow()` 对 `TURN_ACTIVE` 做**边沿检测**（`turnLiveShown` 标记）——
    流式期间 flush 最密 150ms 一次，不能每拍都打 kit；
  - `teardownMonitor()`（含 disconnect/exitSession 路径）复用 `liveView.stop()`
    收两条窗，边沿标记同步复位。
- kit 调用面/降级策略不变（动态 import + syscap 守卫，API 24 设备静默回退；
  PROGRESS 场景无需专项资质）。

## 验证台账（M11.5）

- entry assembleHap 编译通过；protocol/client 测试全绿。
- codelinter 对 LiveViewNotifier 报 2 条 `await import` 误报（非 Thenable）——
  原有代码同款、ArkTS 编译器接受，不处理。
- **未验证（真机）**：锁屏/状态栏胶囊观感、回合开始/结束的窗出现与自动收起、
  审批窗让位/补位时序、API 24 设备降级。
