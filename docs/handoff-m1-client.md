# Handoff — qaqh-harmony M1（连接层 RingingClient）

日期：2026-10-05
状态：`@qaqh/client` HAR 完成，14/14 client 契约测试 + 32/32 protocol 测试通过，全工程构建通过
后端基线：qaqh-backend `2.0.0-beta.2`（本机 `E:\qaqh-backend`，可直接对拍源码）
前置：见 `docs/handoff-m0-protocol.md`（M0 协议层 / 工具链 / ArkTS 注意事项仍然有效）

## 本阶段完成的事

### 新模块 `app/commons/client/`（@qaqh/client HAR）
依赖 `@qaqh/protocol`（file:），已被 entry 通过 file: 依赖引用（entry 代码尚未 import）。

| 文件 | 内容 |
|---|---|
| `src/main/ets/RingingClient.ets` | 连接层核心：状态机 idle→open→closed；open（断言 `accepted` 且 `capabilities.single_stream`）/ lease 定时 renew / bootstrap / sendCommand（ACK id 核对）/ commandStatus / close |
| `src/main/ets/transport/Transport.ets` | `Transport` / `LeaseTimer` 接口 + TransportRequest/Response + TransportError（status=-1 网络级，>=400 服务端） |
| `src/main/ets/transport/HttpTransport.ets` | `@ohos.net.http` 实现（NetworkKit）。每请求独立 createHttp/destroy；非 2xx 不在这里抛，交 client 层按端点语义处理 |
| `src/main/ets/transport/SystemLeaseTimer.ets` | 真机 setTimeout 单发定时器（fire 后由 client 重排） |
| `src/test/ClientContract.test.ets` | 14 用例：假 transport（脚本化响应）+ 假 timer（手动 fire/查间隔） |

### 与后端源码对拍确认的契约（不再靠猜）
1. **renew 是无请求体的 POST**：`qaqh-client/src/v2.rs renew_lease_v2` 只带
   Bearer + `X-QAQH-Client-Session-Id`；`axum_impl/v2.rs handle_renew_v2` 只取
   HeaderMap。租约过期/未知会话返回 **HTTP 401 `lease_expired`**（不是 200+ok:false，
   但 `ok:false` 形态按契约保留处理）。
2. **续期策略对齐 `session.rs run_renewal`**：节拍 = `max(1000, renew_interval_ms/2)`
   （窗口内留一次重试）；**连续失败 >= MAX_RENEW_FAILURES(=2)** 判定租约已死 →
   close + `onLeaseLost('renewal_failures_exceeded')`。自动重新 open（重新协商）
   属于会话循环，留给 M2 上层接线——client 只上报。
3. 所有 v2 端点鉴权 = Bearer token + lease header（`is_authorized` +
   `require_v2_lease`）；命令 POST `/commands/{channel}` 的信封 wire 形态、
   ACK `command_id` 核对与 `qaqh-client send_command_v2_typed` 逐条一致。
4. 本 daemon open 恒返回 `single_stream:true`、全 capabilities true（handler 硬编码）。
5. entry 的 `module.json5` 已加 `ohos.permission.INTERNET`。

## 测试 / 构建
```bash
# client 单测（14/14，app/ 目录下）
DEVECO_SDK_HOME=<clt>/sdk <clt>/tool/node/node.exe <clt>/hvigor/bin/hvigorw.js \
  --mode module -p module=client@default test
# 结果：app/commons/client/.test/default/intermediates/test/coverage_data/test_result.txt

# 全工程构建
DEVECO_CLI_CLT_PATH=<clt> ../node_modules/.bin/devecocli build
```
新模块踩坑：HAR 模块必须有模块级 `hvigorfile.ts`（harTasks 模板，从 protocol 复制），
否则 hvigor 报 00303148；新增模块后需 `ohpm install`。

## ArkTS 严格模式新增注意（M1 踩过）
- 测试里 `expect(...).assertEqual` 可在普通 helper 函数中使用；异步错误断言要
  自写 `try/await/catch` helper（hypium 无 assertRejects）。
- 定时器 fire 回调不 await renew promise：测试用 `settle()`（多次
  `await Promise.resolve()`）冲刷微任务后断言。

## 下一步（按里程碑）
1. **M2 监控**：`http.requestInStream` 订阅 `/events?since_cursor=`（参考
   `qaqh-client subscribe_v2`：Accept: text/event-stream，单流 per-seed）；
   cursor 持久化（preferences）；断线重连 + **重新协商循环**（把本阶段的
   `onLeaseLost` 接到重新 open + 重新 bootstrap）；timeline UI。
2. **M3 授权闭环**：`interaction_requested` → 弹窗 →
   `tool_permission_respond` / `interaction_ask_respond` / `plan_review_respond`
   → `causation_id == command_id` 确认；ACK 丢失走 `commandStatus()`。
3. **M4**：生物认证 Authenticator 抽象；后台通知。
4. 签名：`devecocli auth login` → `devecocli signature generate`（需用户操作）。
5. token 配对（PC 端二维码，含地址+token）可在 M2 接 UI 时一起做。

## 常用命令
```bash
# 本地鸿蒙文档检索（仓库根）
python scripts/docs.py search "@ohos.net.http" --limit 5
```
