# Design — 11.5 寸平板「耐看」方案（M14 设计文档）

日期：2026-10-07
状态：Phase 1 已实现（见 §四）；Phase 2/3 待真机走查后逐轮推进。
目标设备：11.5 寸平板（竖屏 885×1346vp / 横屏 1346×885vp，density ≈ 2.08）。
约束：不做企业级能力（IntentsKit/小艺意图挂起）；遵守 M9.1 用户拍板
（无右侧信息栏、授权中心弹窗、计划活渲染在消息流）。

## 一、诊断：现在「不耐看」在哪

1. **语义色深色模式破功**：QaqhTone 的三档底色（#FFF7E6 等）是固定浅色
   hex，深色模式下工具卡在暗页面上发亮刺眼——这是走查深色模式前必须修的
   硬伤（Phase 1 已修：同色 8% alpha 叠加，两种模式自动成立）。
2. **顶栏是调试工具不是产品**：详情页顶栏显示 session id 前 8 位。
   M13 已有 G2 口径 displayTitle（title → cwd 尾段 → 短 id），列表页在用，
   顶栏没用（Phase 1 已修）。
3. **层级靠阴影堆**：卡片/浮岛/浮标全部带 shadow，阴影失去「浮起」的
   语义，页面显得躁。耐看的层级应该是：canvas（sub_background）→
   surface（background）→ elevated（card_bg）三层底色 + 发丝线，阴影只留
   给真正悬浮的东西（composer 浮岛、胶囊、弹窗、浮标）。
4. **信息密度浪费**：横屏 1346vp 宽，正文列 860vp 两侧大量留白没有承担
   功能；列表列 320-420vp 里卡片信息排布偏「列表」，不像「驾驶舱」。
5. **无悬停/键盘反馈**：平板接鼠标/键盘是常态，交互元素没有 hover
   形态、没有快捷键，触屏时代的界面在桌化场景下显得「钝」。

## 二、设计语言（定死的规矩，写进 UiKit 前先写在这）

- **三层底色**：页面画布 `sub_background`；内容卡 `background`；
  浮起面（composer/胶囊/弹窗）`card_bg` 或 background + 阴影。同一层内
  不再嵌套同层底色（卡片里套卡片改用发丝线分区）。
- **阴影白名单**：只有 4 处允许 shadow——composer 浮岛、悬浮胶囊、
  ApprovalDialog、「N 项待授权」浮标。其余一律发丝线
  （`ohos_id_color_list_separator` 1px）或纯底色差。
- **等宽点缀**：id、模型名、路径、字节数、revision 号用 CascadiaMono
  （MONO_FAMILY），中文回落系统字体自动成立。原则：**凡是机器产生的
  字符串用等宽，人话用系统字**。
- **字号节奏**：正文 15fp/24 行高（Markdown 已是）；标题 16fp Medium；
  顶栏 15fp Medium；徽标/元数据 11-12fp；副行 13fp。不再出现 14/15
  之外的自造值混排。
- **动效克制**：结构变化 springMotion（已有），hover 只做底色渐变
  （120ms），不做位移/缩放；新内容进场 OPACITY+translate 180ms（已有）。
- **语义色只表达状态**：running/ok/bad 三色只出现在徽标、边线、
  进度位；正文永远 text_primary。8% alpha 底色 + 同色前景是标准组合
  （QaqhTheme.toneBackground/toneColor 已收口）。

## 三、版式（11.5 寸两向）

### 横屏 1346×885（主工作形态）

```
┌─────────┬──────────────────────────────────────────┐
│ 列表列   │ 顶栏：〔返回〕〔折叠〕 标题······· [模型] 状态 │
│ 340vp   ├──────────────────────────────────────────┤
│         │      ┌─ 正文列 860vp 居中 ─┐               │
│ 搜索/    │      │ 消息流（阅读宽度）  │   两侧留白区：  │
│ 筛选    │      │  用户气泡          │   - 滚动时悬停   │
│         │      │  思考折叠          │     顶栏毛玻璃   │
│ 会话卡   │      │  工具卡（分组）     │   - Phase 2 可  │
│ (标题/   │      │  回合分隔线        │     放浮动回合   │
│  模型/  │      └────────────────────┘     导航(挂账)  │
│  摘要)  │ ┌─ composer 浮岛 860vp 居中 ─┐              │
│         │ └────────────────────────────┘              │
│         │        ◉ 悬浮胶囊（三 tab）                  │
└─────────┴──────────────────────────────────────────┘
```

- 列表列 340vp（navBarWidthRange 320-420 现值保留）。
- 正文列 860vp 保持——markdown 代码块需要宽度，加了居中与两侧
  呼吸后不再显「一条直线」。
- 顶栏升级为**贴边毛玻璃**（Phase 2）：正文从顶栏下滑过时
  `backdropBlur(24)` + 60% 底色，滚动到顶恢复纯透明。这是「耐看」
  观感提升最大的一单项。

### 竖屏 885×1346（手持形态）

- 单栏 Stack（M9.2 的宽高比判定不变），正文列 860 → 全宽减 32 边距。
- composer 浮岛全宽 - 24；胶囊居中。
- 竖屏下列表卡改为「标题 + 首行摘要 + 右上运行徽标」三行密排，
  滑动浏览优先。

## 四、Phase 1（本轮已实现，等真机验收）| 项 | 文件 | 内容 |
|---|---|---|
| 深色安全语义底色 | theme/QaqhTheme.ets | 三档 BG 改同色 8% alpha（#14xxxxxx），深浅两模式自动成立 |
| 顶栏标题化 | model/QaqhState.ets, model/AppModel.ets | 新增 ACTIVE_TITLE/ACTIVE_MODEL 键，enterSession 灌入（G2 口径复用 sessionLabelOf），teardownMonitor 清空 |
| 顶栏布局 | view/SessionDetailView.ets | id 徽标退役 → 标题（15fp Medium 权重占位 + ellipsis）+ 模型等宽小徽标（≤220vp）+ 状态右置 |
| 验证 | — | 构建 + 签名通过；待装机走查浅/深两模式 |

**真机验收点**：① 横屏进会话看顶栏（标题截断、模型徽标、多会话切换
标题跟随）；② 深色模式工具卡三态底色不发亮；③ 浅色模式语义底色与
改前观感对比（应基本无感）。

## 五、Phase 2（下一轮，按收益排序）

1. **顶栏贴边毛玻璃**：正文滚动下穿 + backdropBlur（上文 §三）。
2. **阴影白名单收口**：Card 基元去 shadow 改发丝线；只留 §二 四处。
   动 UiKit 会全页面生效，单独一轮做并真机走查。
3. **代码块复制按钮**：pasteboard + 「已复制」轻反馈（HDS SnackBar 或
   自绘 toast，UI 挂账 M8 一并清）。
4. **列表卡信息升级**：标题为主（M13 已接），模型 + 更新时间次行，
   running 徽标右上角标化；「40 个空会话霸列表」折叠分组
   （M8.1 挂账）——按日期分组或空会话收进「已归档」。
5. **悬停形态**：鼠标 hover 底色渐变（列表卡/按钮/工具卡），keyboard
   focus 边线（InputKit inputDevice 探测键盘接入时才启用提示）。

## 六、Phase 3（平板化能力，配合挂账一起排期）

1. **物理键盘快捷键**（InputKit inputConsumer）：Enter 发送 /
   Esc 停止回合或返回 / Ctrl+K 聚焦 composer。检测到键盘时 composer
   placeholder 显示快捷键提示。
2. **BackgroundTasksKit 长时任务**：退后台保租约/监听审批（dataTransfer
   类型），配合 AbilityKit onForeground/onBackground 做全速/降级两档——
   这是 M5 起挂账的「后台失联」正解，无需企业资质。
3. **深色模式全量走查**：Phase 1 修完语义底色后，把 OverviewTab/
   SettingsTab/ApprovalDialog 逐屏过一遍（自定义色只剩 QaqhTone 三色，
   风险面已收窄）。
4. **HDS 组件选装**（本机 SDK @kit.UIDesignKit 实存）：HdsTabs 浮动
   mini bar、SnackBar、hdsMaterial 可逐步替换自绘形态；先在 Phase 2 的
   复制反馈上试水一个 SnackBar，观感对味再扩大。

## 七、明确不做

- IntentsKit/小艺意图、MCP 插件（企业资质，用户拍板暂缓）；
- HdsNavigation 全壳替换（自绘胶囊已是卖点，重构风险大于收益）；
- 右侧信息栏回归（M9.1 拍板）；
- 字号/圆角自造新值（全部走 §二 节奏与 sys token）。

## 八、Phase 2 落地记录（2026-10-07 真机验收）

1. **顶栏贴边毛玻璃**：SessionDetailView 重构为双层 Stack——正文列从悬浮顶栏
   下滚动穿过；顶栏材质与底部胶囊同配方（`bottom_tab_bg_blur` +
   `backdropBlur(36)` + 底缘 0.75px 发丝线）；内容列 padding top =
   safeTop + 56。真机 t9.jpeg 验收：标题/模型徽标/状态入栏，布局无破损。
2. **代码块复制**：lv-markdown-in 3.4.7 的 `setCodeBlockActionAreaVisible(true)`
   + `setCodeCopyListener`（QaqhTheme 收口）→ pasteboard 写入 + 全局
   promptAction toast「代码已复制」。**待验**：冒烟根无模型输出，代码块要等
   真实会话（真机无代码块可截）。
3. **开屏扫码鉴权（用户拍板落地）**：无已配对凭证时整壳换成 Onboarding 首屏
   （QaqhState.ONBOARD 门，Index 二分）——首选扫码配对，兜底地址+Admin
   token 手动配对，「跳过」可先进主壳；配对成功 `finishOnboarding()` =
   收引导 + 直接 connect()。清凭证（unpair）回到引导态。真机全链路已走通：
   清凭证 → 引导屏（620vp 居中）→ 手动配对 → 自动连接进会话列表。
   设备凭证仍走 Asset Store Kit（本轮已修 update ALIAS bug）。
