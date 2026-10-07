/**
 * `POST /ringing/v2/service/session.list` 条目（镜像 qaqh-types SessionListEntry）。
 *
 * 术语：后端已统一 sessionId（旧称 seed 已弃用）；wire 路径里的
 * `/sessions/{id}/...` 占位符语义不变。
 */

import { requiredString, requiredNumber, optionalString, optionalNumber,
  optionalBoolean, ProtocolError } from './Json';

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
  }

  /**
   * 会话展示标题——镜像后端 `SessionMeta::display_title`（前端契约 G2 口径）：
   * `title` → `cwd` 尾段 → `session_id`。`last_summary` 不参与：它是「最后一条
   * assistant 回复首行」的预览，当标题会让标题随对话漂移（TUI 踩过的坑）。
   * 末档展示时截短 id（手机上全 ULID 没有可读性）。
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

  static parseArray(text: string): RingingSessionListEntry[] {
    let value: Object = JSON.parse(text) as Object;
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

/** 会话发现选择器：running 优先，其次 updated_at 最新（对齐安卓侧）。 */
export function pickPreferredSession(entries: RingingSessionListEntry[]): string {
  let best: RingingSessionListEntry | undefined = undefined;
  for (const entry of entries) {
    if (entry.running) {
      return entry.sessionId;
    }
    if (best === undefined || entry.updatedAt > best.updatedAt) {
      best = entry;
    }
  }
  return best !== undefined ? best.sessionId : '';
}
