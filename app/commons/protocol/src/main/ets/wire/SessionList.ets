/**
 * `POST /ringing/v2/service/session.list` 条目（镜像 qaqh-types SessionListEntry）。
 *
 * 术语：后端已统一 sessionId（旧称 seed 已弃用）；wire 路径里的
 * `/sessions/{id}/...` 占位符语义不变。
 *
 * 形状权威源：`E:\qaqh-backend\crates\qaqh-types\src\session.rs` 的
 * `SessionListEntry` = `flatten(SessionMeta)` + `running` + `workspace_id`，
 * 键集由后端手工锁表 `session_list_entry_wire_keys_are_locked` 把守。本文件的
 * SESSION_LIST_WIRE_KEYS 是那份表的镜像——两侧各自「显式过一次评审」，
 * 后端加法式演进（AGENTS I14：只许加 `#[serde(default)]` 字段）时这里跟着动。
 *
 * 解析只建模 UI 用得上的键，其余已知键收下不建模；**表外**的键记进
 * `unmodeledKeys` 当漂移可见化（同 Payload.ets 的 unrecognizedControlKind 策略：
 * 收下、不断流、留痕）。
 */

import { requiredString, requiredNumber, optionalString, optionalNumber,
  optionalBoolean, ProtocolError } from './Json';

/** 后端 session.list 条目的 wire 键全集（镜像 session.rs 手工锁表，27 键）。 */
export const SESSION_LIST_WIRE_KEYS: string[] = [
  // ── SessionMeta 持久化字段 ──
  'archived', 'cache_reported_requests', 'compact_covered_through_msg_id',
  'compact_skip', 'context_stats', 'created_at', 'custom_tools', 'cwd',
  'effort', 'ephemeral', 'frozen_annotation', 'last_summary', 'last_usage',
  'message_count', 'mode', 'model', 'profile', 'session_id', 'skills',
  'title', 'tool_mode', 'turn_count', 'updated_at', 'usage_requests',
  'usage_totals',
  // ── daemon 运行期附加字段 ──
  'running', 'workspace_id'
];

/**
 * 后端 `#[serde(skip)]` 的运行期字段：永不上线。回包里出现即形状漂移，
 * 且绝不许当成有效字段解析（镜像 session.rs:371-377 的同一条断言）。
 */
export const SESSION_LIST_NEVER_ON_WIRE_KEYS: string[] = [
  'resume_session', 'tokens', 'from_resume'
];

/** 本类建模解析的键（与 SESSION_LIST_WIRE_KEYS 的一致性由契约测试把守）。 */
export const SESSION_LIST_MODELED_KEYS: string[] = [
  'session_id', 'created_at', 'updated_at', 'model', 'message_count',
  'turn_count', 'last_summary', 'running', 'workspace_id', 'title', 'cwd',
  'archived', 'ephemeral'
];

export class RingingSessionListEntry {
  readonly sessionId: string;
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly model: string | undefined;
  readonly messageCount: number;
  readonly turnCount: number;
  readonly lastSummary: string | undefined;
  readonly running: boolean;
  readonly workspaceId: string | undefined;
  /** LLM 生成的会话标题（首轮后生成一次即冻结；可能缺省/为空）。 */
  readonly title: string | undefined;
  /** 会话创建时的工作目录（displayTitle 的第二档回退）。 */
  readonly cwd: string | undefined;
  /** 归档标记（标签 × 归档后置 true）：停止运行、只该进归档组。 */
  readonly archived: boolean;
  /** 临时会话（子代理）标记：正常不入索引，入了一次也不能露出。 */
  readonly ephemeral: boolean;
  /** 键表之外的键——后端未经评审的形状变更在这里现形（空数组 = 无漂移）。 */
  readonly unmodeledKeys: string[];

  constructor(holder: object) {
    this.sessionId = requiredString(holder, 'session_id');
    this.createdAt = optionalNumber(holder, 'created_at') ?? 0;
    this.updatedAt = optionalNumber(holder, 'updated_at') ?? 0;
    this.model = optionalString(holder, 'model');
    this.messageCount = optionalNumber(holder, 'message_count') ?? 0;
    this.turnCount = optionalNumber(holder, 'turn_count') ?? 0;
    this.lastSummary = optionalString(holder, 'last_summary');
    this.running = optionalBoolean(holder, 'running') ?? false;
    this.workspaceId = optionalString(holder, 'workspace_id');
    this.title = optionalString(holder, 'title');
    this.cwd = optionalString(holder, 'cwd');
    this.archived = optionalBoolean(holder, 'archived') ?? false;
    this.ephemeral = optionalBoolean(holder, 'ephemeral') ?? false;
    this.unmodeledKeys = collectUnknownKeys(holder);
  }

  /**
   * 会话展示标题——镜像后端 `SessionMeta::display_title`（前端契约 G2 口径）：
   * `title` → `cwd` 尾段 → `session_id`。`last_summary` 不参与：它是「最后一条
   * assistant 回复首行」的预览，当标题会让标题随对话漂移（TUI 踩过的坑）。
   * 末档展示时截短 id（手机上全 ULID 没有可读性）——这一档是**已声明的端侧偏离**，
   * 后端返回的是完整 session_id。
   */
  displayTitle(): string {
    if (this.title !== undefined && this.title.trim().length > 0) {
      return this.title;
    }
    if (this.cwd !== undefined && this.cwd.trim().length > 0) {
      const trimmed: string = this.cwd.replace(/[\\/]+$/, '');
      const cut: number = Math.max(trimmed.lastIndexOf('/'), trimmed.lastIndexOf('\\'));
      const tail: string = cut >= 0 ? trimmed.substring(cut + 1) : trimmed;
      if (tail.length > 0) {
        return tail;
      }
    }
    return this.sessionId.length > 8 ? this.sessionId.substring(0, 8) : this.sessionId;
  }

  /**
   * 是否进「活跃会话」面（列表、计数、自动发现、审批扇出）。
   *
   * 后端 `session.list` 不做过滤（service.rs `list_sessions` 原样吐索引），归档
   * 会话照发——且 `set_archived` 会把 `updated_at` 刷成当下（manager.rs:689），
   * 刚归档的那条因此恒占「最新」位。不过滤就等于让归档会话冒充最近活动。
   */
  isListable(): boolean {
    return !this.archived && !this.ephemeral;
  }

  static parseArray(text: string): RingingSessionListEntry[] {
    // 顶层是数组，parseJson（只收对象）不适用；但畸形 JSON 仍要按响亮失败策略
    // 归一到 ProtocolError，别把 SyntaxError 漏给上层。
    let value: Object;
    try {
      value = JSON.parse(text) as Object;
    } catch (error) {
      throw new ProtocolError('bad_json', `invalid JSON: ${(error as Error).message}`);
    }
    if (!Array.isArray(value)) {
      throw new ProtocolError('bad_json', 'session.list response must be an array');
    }
    const out: RingingSessionListEntry[] = [];
    for (const item of value as Object[]) {
      if (typeof item !== 'object' || item === null) {
        throw new ProtocolError('bad_field', 'session.list entries must be objects');
      }
      out.push(new RingingSessionListEntry(item as object));
    }
    return out;
  }
}

/** 活跃会话子集：列表/计数/扇出的唯一口径（后端不过滤，端侧必须滤）。 */
export function visibleSessions(entries: RingingSessionListEntry[]): RingingSessionListEntry[] {
  const out: RingingSessionListEntry[] = [];
  for (const entry of entries) {
    if (entry.isListable()) {
      out.push(entry);
    }
  }
  return out;
}

/**
 * 会话发现选择器：在可展示会话里 running 优先，其次 updated_at 最新。
 *
 * 口径对齐桌面端 `qaqh-desktop-app/src/tabs/store.ts` 的
 * `find(!archived && running) ?? find(!archived)`；后端列表本就按
 * updated_at 倒序，故同键先到者胜（与桌面端 `find` 一致）。
 * 归档/临时会话整条跳过——否则刚归档的那条会抢下「最新」位。
 */
export function pickPreferredSession(entries: RingingSessionListEntry[]): string {
  let best: RingingSessionListEntry | undefined = undefined;
  for (const entry of entries) {
    if (!entry.isListable()) {
      continue;
    }
    if (entry.running) {
      return entry.sessionId;
    }
    if (best === undefined || entry.updatedAt > best.updatedAt) {
      best = entry;
    }
  }
  return best !== undefined ? best.sessionId : '';
}

/** 收下表外键（去重，保序）。 */
function collectUnknownKeys(holder: object): string[] {
  const out: string[] = [];
  for (const key of Object.keys(holder as Record<string, Object>)) {
    if (!SESSION_LIST_WIRE_KEYS.includes(key) && !out.includes(key)) {
      out.push(key);
    }
  }
  return out;
}
