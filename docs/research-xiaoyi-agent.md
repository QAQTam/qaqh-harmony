# Research — 接入鸿蒙 AI 智能体生态（小艺 / Intents Kit / HMAF）

日期：2026-10-06
状态：调研完成，给出分阶段接入建议；代码未动。
结论先行：**三条路线不是二选一，建议按 "意图(应用内) → MCP 插件(云端) → Skill/智能体" 分三步走**，
第一步的代码量最小、和现有 AppModel 的方法一一对应。

## 一、生态全景（HDC 2025/2026 后的格局）

三方应用接入小艺调度体系有四种方式（开放程度递增、工程量也递增）：

| 路线 | 载体 | 用户看到什么 | 适合我们做什么 |
|---|---|---|---|
| **Intents Kit 意图框架** | app 内声明意图 | 小艺对话/小艺搜索/小艺建议 里直达应用功能 | "看看有几个待审批""批准最近一条""会话状态" |
| **MCP 插件**（小艺开放平台） | 云端注册 MCP 服务 | 小艺直接调我们的工具查数据 | 把 daemon 的服务面方法暴露成小艺工具 |
| **Skill（SKILL.md）** | 小艺开放平台 | 完整多轮对话技能 | "帮我处理电脑上的待办审批" 全流程对话 |
| **A2A / 智能体** | 小艺智能体广场 | 独立智能体 | 远期：QAQ 驾驶舱智能体 |

另有 **HMAF（Harmony Agent Framework，HarmonyOS 6 / API 23）**：端侧智能体编排
框架（悬浮导航、沉浸光感等新 API + OS 共享端侧模型），文档目前公开度低，先观察。

## 二、路线 1：Intents Kit（推荐先做）

官方文档（2026-09 更新版）：意图框架概述 / 使用装饰器开发意图（API 20+，推荐）。

### 形态

在 app 里用装饰器把现有功能声明成意图，`insight_intent.json` 的
`insightIntentsSrcEntry` 登记执行文件即可参与编译：

```json
{
  "insightIntentsSrcEntry": [
    { "srcEntry": "./ets/insightintents/PendingApprovalsImpl.ets" }
  ]
}
```

```typescript
@InsightIntentEntry({
  intentName: 'ViewPendingApprovals',
  domain: 'qaqhDomain',
  intentVersion: '1.0.1',
  displayName: '查看待审批',
  displayDescription: '查看电脑端待处理的授权请求',
  llmDescription: '查询 qaqh 电脑端当前待批准的工具权限/计划/提问数量与摘要',
  keywords: ['待审批', '授权', 'qaqh'],
  abilityName: 'EntryAbility',
  executeMode: [insightIntent.ExecuteMode.UI_ABILITY_BACKGROUND],  // 免开界面直接回话
  parameters: { /* JSON Schema */ }
})
export default class PendingApprovalsImpl extends InsightIntentEntryExecutor {
  onExecute(): Promise<insightIntent.IntentResult> {
    // 直接复用 AppModel：连着 daemon 就拉实时数据，没连就回缓存的卡片数
  }
}
```

可用装饰器与我们的映射：

| 装饰器 | 语义 | qaqh 映射 |
|---|---|---|
| `@InsightIntentEntry` | 绑定 UIAbility 的意图执行（前台/后台两种模式） | 查待审批数、批准/拒绝最近一条（**后台模式 + 生物认证守门**）、发消息到当前会话 |
| `@InsightIntentPage` | 页面路由转意图 | "打开会话列表""打开设置" |
| `@InsightIntentLink` | uri 转意图 | 我们已有深链（focus interaction），直接包成意图 |
| `@InsightIntentFunctionMethod` | 静态方法转意图（Call 调用） | 轻量查询 |
| `@InsightIntentForm` | 意图卡片 | 和 Form Kit 互动卡片方案合流 |
| `@InsightIntentEntity` | 意图实体；**API 26.0.0 起支持可查询实体**（`AppIntentEntity` + `onQueryEntity`） | **会话列表做成可查询实体**：小艺可按名称/状态筛我们的 session.list，"我电脑上哪个会话在跑" 就是标准查询 |

### 硬约束（决定能不能玩，先确认）

1. **仅企业开发者**：个人开发者无法申请/注册意图能力 → 用户说"有配套设施"，
   需要确认是企业开发者账号（AGC）。
2. 仅中国大陆（不含港澳台）；Phone / Tablet / PC(2in1)。
3. **模拟器不支持**——调试必须真机（HarmonyOS 5.0+）。
4. 意图执行结果由系统入口转成自然语言播报；写操作（批准）建议
   `UI_ABILITY_BACKGROUND` 拉起 + 应用内先过 IAM 生物认证，再执行。

### 工程落点（鸿蒙仓）

- 新增 `app/entry/src/main/ets/insightintents/`（意图执行器 4-5 个）。
- `entry/src/main/resources/base/profile/insight_intent.json` 登记。
- AppModel 补一个"无 UI 上下文执行"门面：现在 `AppModel.instance()` 依赖
  EntryAbility `init()` 注入 context，意图后台执行时要容忍"未初始化/未连接"
  状态（回缓存或明确报错文案给小艺播报）。
- 批准类意图复用 `AppModel.respond()`（内含生物认证门禁），天然合规。

## 三、路线 2：小艺开放平台 MCP 插件（后端主线）

小艺开放平台支持把 **MCP 服务**注册为插件（标准注册 / 外部导入 / 基于意图框架
创建云插件 → 创建工具 → 测试 → 发布），小艺即可调用。对 qaqh 的独特优势：

- 后端 `qaqh-runtime` 的服务面（`config.load / session.list / stats.token_usage /
  git.* / todo.*` …）已经是**工具化的单一事实源**，包一层 MCP server 就是现成的
  小艺工具集（`qaqh-mcp` 现在只是 MCP 客户端，需补 server 能力，或用
  `rmcp` 官方 crate 起一个面向小艺的 MCP 端点）。
- 用户身份：小艺侧走华为账号绑定（平台配置 clientId + 服务器 API 地址，
  授权卡引导绑定）；daemon 需要一个"华为账号 ↔ 设备/租户"的映射层
  （daemon 现在是 LAN 直连，云端化是这步的前置）。

**依赖链**：daemon 得有一个公网可达的入口 + 账号体系，工程量主要在后端，
适合作为 beta 后的云端化专项。

## 四、路线 3：Skill / 智能体（SKILL.md，体验最完整）

小艺开放平台控制台创建：技能管理 → 新建自定义技能 → 配触发（关键词 /
LLM 意图描述）→ 多轮交互（开场白/参数收集/确认）→ 执行（引插件/MCP 工具）→
输出（文本/卡片）→ 调试 → 测试版 → 正式版。SKILL.md 是能力声明文件
（配合华为账号绑定文档；VibeCoding 对话式开发 Skills 是 HDC2026 新动向）。

对 qaqh：做一个"电脑管家"Skill——"电脑上有什么要我批的吗？" → 列卡片 →
"批准第一条" → 生物认证 → 回执。依赖路线 2 的 MCP 工具先就位。

## 五、建议的落地顺序

1. **本周可做**：Intents Kit 意图 4 个（待审批查询 / 批准最近一条 / 会话状态 /
   打开会话），装饰器方案 + API 26 可查询实体（会话列表）。前提：确认企业
   开发者账号 + 一台 HarmonyOS 5.0+ 真机（模拟器不行）。
2. **下一专项**：后端 MCP server 端点 + 小艺开放平台注册 MCP 插件（云端化前
   先在局域网桥接形态验证，配对即授权账号映射）。
3. **之后**：电脑管家 Skill（多轮对话 + 卡片），再评估 HMAF / A2A。
4. 与既有规划的关系：Form Kit 互动卡片与 `@InsightIntentForm` 合流成一件事做；
   长时任务（Background Task Kit）是意图后台执行的地基，建议同期做。

## 六、参考

- 意图框架概述 / Intents Kit 简介（developer.huawei.com，harmonyos-guides
  `insight-intent-overview` / `intents-introduction`，2026-08/09 更新）
- 使用装饰器开发意图（`insight-intent-decorator-development`，含
  `@InsightIntentEntry/Link/Page/FunctionMethod/Form/Entity` 全例）
- 小艺开放平台（developer.huawei.com/consumer/cn/celia/）：Skill 接入华为账号、
  A2A 协议接入方案、界面（资源库）
- 离线文档镜像：github.com/liasica/harmonyos-skills（可装成 Claude Code skill，
  对本仓的 LLM 辅助开发也有用）
- 约束原文：意图能力"仅面向企业开发者""仅中国境内""模拟器不支持"
