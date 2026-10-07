# Handoff — qaqh-harmony M0（协议层 init）

日期：2026-10-04
状态：protocol HAR 完成，32/32 契约测试通过，全工程构建通过
后端基线：qaqh-backend `2.0.0-beta.2`（Ringing v2，单流修订 2026-09-24）

## 本阶段完成的事

### 工具链
- **Command Line Tools 6.1.1.418**（含 HarmonyOS SDK 6.1.1 / **API 24**）解压在
  `commandline-tools-windows-x64-6.1.1.418/command-line-tools/`。
- **@deveco/deveco-cli 1.3.0-stable**（`node_modules/.bin/devecocli`）封装全部开发流程。
- 版本门槛补丁：deveco-cli 要求 CLT ≥ 26.0.0（2026 年起的 DevEco Studio/CLT 新版本线，
  **不是 API 等级**），已把 `dist/cli.js` 中 `assertCltVersion(e="26.0.0")` 改为
  `"6.1.1"`。`devecocli update` 会覆盖补丁，重打即可（一行替换）。
- 本地文档库（14683 篇）检索工具：`python scripts/docs.py search <关键词>` /
  `read <document_id>`（`devecocli docs` 被版本门槛挡住，走的是自建 SQLite FTS 检索）。

### 工程骨架
- `devecocli create` 生成，bundle `com.qaqh.harmony`，Stage 模型，API 24，
  `useNormalizedOHMUrl: true`。
- `app/commons/protocol/`：**@qaqh/protocol** HAR（Ringing v2 wire contract），
  已被 entry 通过 `file:` 依赖引用（entry 代码尚未 import）。

### 协议层（commons/protocol/src/main/ets/）
| 文件 | 内容 |
|---|---|
| `wire/Constants.ets` | schema/版本/路径/`X-QAQH-Client-Session-Id`/MAX_SAFE_INTEGER/END_OF_FACT |
| `wire/Utf8.ets` | 手写严格 UTF-8 编解码（非法序列抛错，绝不 lossy） |
| `wire/Json.ets` | 逐字段守卫解析器 + ProtocolError（响亮失败策略） |
| `wire/Cursor.ets` | CanonicalCursor + CursorToken（`v2.<base64url-no-pad>`，含规范重编码校验） |
| `wire/SseDecoder.ets` | 逐字节对齐 qaqh-client：空行定界/注释丢弃/多 data 行/BOM 仅流首/EOF 不冲刷 |
| `wire/WireTypes.ets` | open/lease/capabilities/事件信封（三种 delivery 校验）/stream_key/pending interaction/content value/driver/reset_required |
| `wire/Bootstrap.ets` | 三频道冻结快照；control state 强类型（interactions/driver/activity/revision），conversation/tool 暂为 raw |
| `wire/Ack.ets` | 命令 ACK / `existing`（command_receipt / interaction_resolved）/ 类型化 `result`（ask/plan/permission_resolved）/ 命令状态 |
| `wire/Payload.ets` | ProjectionPayload 判别；ControlDelta 的 interaction_requested/resolved/expired + activity 强类型，其余已知变体 opaque，未知 kind 抛错 |
| `wire/Commands.ets` | 命令信封（含 expected_revision/driver_epoch 守卫，仅 session_create 免 session_id）+ 手机端命令子集 builder |

### 契约测试
- `src/test/ProtocolContract.test.ets`（hypium LocalUnit）：夹具取自后端
  types.rs / cursor.rs / sse_decoder.rs 的测试向量。**Tests run: 32, Failure: 0**。
- 结果文件：`app/commons/protocol/.test/default/intermediates/test/coverage_data/test_result.txt`。

## 关键契约认知（踩过的坑）
1. **`ContentValue` 是双层 tag/content**：`{"kind":"ref","data":{"content_ref":...}}`，
   载荷在 `data` 子对象里。
2. **`accepted:false` 的 open 响应是结构合法的**：Rust `validate()` 不校验它，
   是否拒绝由客户端层决定（`from_open` 才拒绝）。
3. wire 枚举值：delivery/ack 状态/命令状态/交互类别全是 snake_case；PlanReview
   统一 wire 值 `plan`。
4. 单流协议：每 seed 一条 SSE，事件带 `stream_key`；连上前必须断言
   `capabilities.single_stream == true`。
5. 命令鉴权只看 `X-QAQH-Client-Session-Id` header，信封里的 client_session_id
   不参与鉴权。

## ArkTS 严格模式注意事项（持续有效）
- 禁止构造器参数属性（`constructor(readonly x)`）——必须显式声明字段再赋值。
- 对象字面量必须对应已声明类型；JSON 形态的构造一律用
  `let r: Record<string, Object> = { 'k': v }`。
- 禁 `ReturnType<typeof>` 等工具类型/类型查询；禁结构化赋型（同一形状的两个
  类不互通，如 CanonicalCursor 不能赋给别的同形状类）。
- Web 全局 `TextEncoder/TextDecoder` 不可用（已自写 Utf8.ets）。

## 下一步（按里程碑）
1. **M1 连接**：`RingingClient`（@ohos.net.http 传输 + Bearer token +
   `X-QAQH-Client-Session-Id`）→ open / lease 定时 renew / bootstrap。
   token 配对方式建议 PC 端二维码（含地址+token）。
2. **M2 监控**：`http.requestInStream` 订阅 `/events`（`?since_cursor=` 续传），
   cursor 持久化（preferences），断线重连 + `ringing.reset_required` 处理；
   timeline UI（先收窄 ConversationSnapshot 的字段）。
3. **M3 授权闭环**：`interaction_requested` → 全局弹窗 →
   `tool_permission_respond` / `interaction_ask_respond` / `plan_review_respond`
   → `causation_id == command_id` 的可靠事件确认；ACK 丢失走
   `GET /commands/{id}` 状态查询。
4. **M4**：生物认证（`@ohos.userIAM.userAuth`，文档已定位）包一层
   Authenticator 抽象；后台通知。
5. 签名：`devecocli auth login`（华为账号 OAuth，需用户操作）→
   `devecocli signature generate`。

## 常用命令
```bash
# 构建（app/ 目录下）
DEVECO_CLI_CLT_PATH=<clt根> ../node_modules/.bin/devecocli build

# 协议层本地单测（app/ 目录下，32 用例）
DEVECO_SDK_HOME=<clt根>/sdk <clt根>/tool/node/node.exe \
  <clt根>/hvigor/bin/hvigorw.js --mode module -p module=protocol@default test

# 本地鸿蒙文档检索（仓库根）
python scripts/docs.py search "userAuth" --limit 5
python scripts/docs.py read "FAQ/安全/用户身份认证_User_Authentication/实现生物认证功能"
```
