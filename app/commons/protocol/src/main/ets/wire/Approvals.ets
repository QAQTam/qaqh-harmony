/**
 * 跨会话审批聚合面（M12）：`GET /ringing/v2/sessions/{id}/approvals` +
 * `POST /ringing/v2/sessions/{id}/approvals/respond`。
 *
 * 镜像后端 axum_impl/v2.rs 的 handle_pending_approvals_v2 /
 * handle_approval_respond_v2 与 axum_impl/challenge.rs 的挑战视图：
 * - **device（配对设备）**：canonical id 不出 daemon，快照为
 *   `{challenges:[{challenge_id, kind, expires_in, details}]}`；应答走
 *   respond 端点（challenge 与会话绑定 + 一次性消费，scope 失败也消费——
 *   防「A 会话的票答到 B 会话」与重放枚举，服务端兜底）。
 * - **admin（手填 token）**：canonical 透传，快照为
 *   `{pending_permission, pending_interaction}`（各至多一项，可为 null）；
 *   应答走既有命令通道（respond 端点对 admin 不可用）。
 *
 * 展示面容忍策略（M3 定，M6 复述）：`details` 原样保留给 UI 降级渲染，
 * 只有顶层形状错（challenge_id 缺失 / kind 非法）才响亮失败。
 */

import { approvalsPath } from './Constants';
import { ProtocolError, parseJson, requiredString, optionalString, requiredNumber,
  isObject, isArray } from './Json';

/** `POST /ringing/v2/sessions/{id}/approvals/respond` */
export function approvalRespondPath(sessionId: string): string {
  return `${approvalsPath(sessionId)}/respond`;
}

/** 审批类别（wire 值）。admin 快照的 `pending_permission` 归一化为 tool_permission。 */
export class ApprovalKind {
  static readonly TOOL_PERMISSION: string = 'tool_permission';
  static readonly ASK: string = 'ask';
  static readonly PLAN: string = 'plan';

  static isKnown(value: string): boolean {
    return value === ApprovalKind.TOOL_PERMISSION || value === ApprovalKind.ASK ||
      value === ApprovalKind.PLAN;
  }
}

/** 决策值域（challenge.rs command_for 的固定集合）。 */
export class ApprovalDecision {
  static readonly APPROVE: string = 'approve';
  static readonly REJECT: string = 'reject';
  static readonly TRUST: string = 'trust';
  static readonly SUBMIT: string = 'submit';
  static readonly DISMISS: string = 'dismiss';
}

/**
 * 归一化后的待审批条目。`respondId` 是应答凭据：
 * - device = challenge_id（respond 端点）；
 * - admin = canonical id（permission 为 tool_call_id，ask/plan 为 interaction id，
 *   命令通道）。
 * `details` 原样保留：permission 是白名单字段对象，ask/plan 是 interaction
 * body 形状，交给 InteractionBody / UI 降级解析。
 */
export class RingingApprovalItem {
  readonly kind: string;
  readonly respondId: string;
  readonly expiresIn: number;
  readonly details: object | undefined;

  constructor(kind: string, respondId: string, expiresIn: number,
    details: object | undefined) {
    this.kind = kind;
    this.respondId = respondId;
    this.expiresIn = expiresIn;
    this.details = details;
  }
}

/**
 * 快照解析（device / admin 两种形状自动判别：有 `challenges` 数组即 device）。
 * 空快照合法（两边都可能没有待审批）。
 */
export class RingingApprovalsSnapshot {
  readonly items: RingingApprovalItem[];

  private constructor(items: RingingApprovalItem[]) {
    this.items = items;
  }

  static parse(text: string): RingingApprovalsSnapshot {
    const holder: object = parseJson(text);
    const challenges: Object | undefined = (holder as Record<string, Object>)['challenges'];
    if (challenges !== undefined) {
      if (!isArray(challenges)) {
        throw new ProtocolError('invalid_approvals_snapshot', 'challenges must be an array');
      }
      const items: RingingApprovalItem[] = [];
      const raw: Array<Object> = challenges as Array<Object>;
      for (const entry of raw) {
        if (!isObject(entry)) {
          throw new ProtocolError('invalid_approvals_snapshot', 'challenge must be an object');
        }
        const challenge: object = entry as object;
        const kind: string = requiredString(challenge, 'kind');
        if (!ApprovalKind.isKnown(kind)) {
          throw new ProtocolError('invalid_approvals_snapshot', `unknown kind: ${kind}`);
        }
        const respondId: string = requiredString(challenge, 'challenge_id');
        if (respondId.trim().length === 0) {
          throw new ProtocolError('invalid_approvals_snapshot', 'empty challenge_id');
        }
        const details: Object | undefined = (challenge as Record<string, Object>)['details'];
        items.push(new RingingApprovalItem(kind, respondId,
          requiredNumber(challenge, 'expires_in'),
          isObject(details) ? details as object : undefined));
      }
      return new RingingApprovalsSnapshot(items);
    }
    // admin canonical 形状：两键均可缺失/为 null（至多各一项）。
    const items: RingingApprovalItem[] = [];
    const permission: Object | undefined = (holder as Record<string, Object>)['pending_permission'];
    if (isObject(permission)) {
      const tool: object = permission as object;
      const callId: string = optionalString(tool, 'tool_call_id') ?? '';
      if (callId.length === 0) {
        throw new ProtocolError('invalid_approvals_snapshot', 'missing tool_call_id');
      }
      items.push(new RingingApprovalItem(ApprovalKind.TOOL_PERMISSION, callId, 0, tool));
    }
    const interaction: Object | undefined =
      (holder as Record<string, Object>)['pending_interaction'];
    if (isObject(interaction)) {
      const view: object = interaction as object;
      const id: string = optionalString(view, 'id') ?? '';
      const kind: string = optionalString(view, 'kind') ?? '';
      if (id.length === 0 || (kind !== 'ask' && kind !== 'plan')) {
        throw new ProtocolError('invalid_approvals_snapshot', 'invalid pending_interaction');
      }
      const details: Object | undefined = (view as Record<string, Object>)['details'];
      items.push(new RingingApprovalItem(kind, id, 0,
        isObject(details) ? details as object : undefined));
    }
    return new RingingApprovalsSnapshot(items);
  }
}

/** respond 端点请求体：`{challenge_id, decision, payload?}`。 */
export class RingingApprovalRespondRequest {
  readonly challengeId: string;
  readonly decision: string;
  readonly payload: object | undefined;

  constructor(challengeId: string, decision: string, payload: object | undefined) {
    this.challengeId = challengeId;
    this.decision = decision;
    this.payload = payload;
  }

  toWire(): Record<string, Object> {
    const wire: Record<string, Object> = {
      'challenge_id': this.challengeId,
      'decision': this.decision
    };
    if (this.payload !== undefined) {
      wire['payload'] = this.payload;
    }
    return wire;
  }

  static validateDecision(decision: string): boolean {
    return decision === ApprovalDecision.APPROVE || decision === ApprovalDecision.REJECT ||
      decision === ApprovalDecision.TRUST || decision === ApprovalDecision.SUBMIT ||
      decision === ApprovalDecision.DISMISS;
  }
}
