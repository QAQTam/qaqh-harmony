/**
 * SSE 单流事件 payload：ProjectionPayload（`kind`/`data` 双层判别式）。
 *
 * 授权闭环所需的 ControlDelta 变体（interaction_requested / resolved /
 * expired、activity）强类型解析；其余变体保持不透明 raw（后续迭代逐个收紧），
 * 与 daemon「未知类别响亮失败」的策略一致——kind 未知直接抛错，已知但本端
 * 暂不消费的变体才允许 opaque 透传。
 */

import { requiredString, requiredNumber, optionalString, optionalNumber, optionalObject,
  requiredObject, ProtocolError } from './Json';
import { isSafeInteger } from './Constants';
import { RingingV2ContentValue, parseContentValue } from './WireTypes';

/** ProjectionPayload 顶层 kind（snake_case wire 值）。 */
export class PayloadKind {
  static readonly CONVERSATION_DELTA: string = 'conversation_delta';
  static readonly TIMELINE_DELTA: string = 'timeline_delta';
  static readonly CONTROL_DELTA: string = 'control_delta';
  static readonly RESOURCE_DELTA: string = 'resource_delta';
  static readonly META_DELTA: string = 'meta_delta';
  static readonly MAILBOX_DELTA: string = 'mailbox_delta';
  static readonly TEAM_DELTA: string = 'team_delta';
  static readonly AUDIT_REF: string = 'audit_ref';
  static readonly UNKNOWN: string = 'unknown';
}

/** ControlDelta 变体 kind。 */
export class ControlDeltaKind {
  static readonly SESSION_CREATED: string = 'session_created';
  static readonly ROUND: string = 'round';
  static readonly ACTIVITY: string = 'activity';
  static readonly TOOL_INTENT: string = 'tool_intent';
  static readonly TOOL_FINISHED: string = 'tool_finished';
  static readonly INTERACTION_REQUESTED: string = 'interaction_requested';
  static readonly INTERACTION_RESOLVED: string = 'interaction_resolved';
  static readonly INTERACTION_EXPIRED: string = 'interaction_expired';
  static readonly DRIVER_CHANGED: string = 'driver_changed';
  static readonly SESSION_RECOVERED: string = 'session_recovered';
  static readonly SUBAGENT_SPAWNED: string = 'subagent_spawned';
  static readonly SUBAGENT_FINISHED: string = 'subagent_finished';

  /** 后端 ControlDelta 当前全集（projection_event.rs:695-783）。漂移检测用。 */
  static isKnown(value: string): boolean {
    return value === ControlDeltaKind.SESSION_CREATED ||
      value === ControlDeltaKind.ROUND || value === ControlDeltaKind.ACTIVITY ||
      value === ControlDeltaKind.TOOL_INTENT || value === ControlDeltaKind.TOOL_FINISHED ||
      value === ControlDeltaKind.INTERACTION_REQUESTED ||
      value === ControlDeltaKind.INTERACTION_RESOLVED ||
      value === ControlDeltaKind.INTERACTION_EXPIRED ||
      value === ControlDeltaKind.DRIVER_CHANGED ||
      value === ControlDeltaKind.SESSION_RECOVERED ||
      value === ControlDeltaKind.SUBAGENT_SPAWNED ||
      value === ControlDeltaKind.SUBAGENT_FINISHED;
  }
}

/**
 * TimelineDelta 变体 kind（镜像 qaqh-session session_fact_v2/projection_event.rs
 * TimelineDelta 的 serde tag，snake_case wire 值）。M2 timeline UI 的数据源。
 */
export class TimelineDeltaKind {
  static readonly INPUT: string = 'input';
  static readonly BLOCK: string = 'block';
  static readonly TOOL_CALL: string = 'tool_call';
  static readonly TOOL_RESULT: string = 'tool_result';
  static readonly TURN_FINISHED: string = 'turn_finished';
  static readonly TURN_INTERRUPTED: string = 'turn_interrupted';
  static readonly COMPACTION: string = 'compaction';

  /** 后端 TimelineDelta 当前全集（projection_event.rs:650-690）。漂移检测用。 */
  static isKnown(value: string): boolean {
    return value === TimelineDeltaKind.INPUT || value === TimelineDeltaKind.BLOCK ||
      value === TimelineDeltaKind.TOOL_CALL || value === TimelineDeltaKind.TOOL_RESULT ||
      value === TimelineDeltaKind.TURN_FINISHED ||
      value === TimelineDeltaKind.TURN_INTERRUPTED ||
      value === TimelineDeltaKind.COMPACTION;
  }
}

/** assistant 块类别（snake_case）。 */
export class AssistantBlockKind {
  static readonly REASONING: string = 'reasoning';
  static readonly ANSWER: string = 'answer';
  static readonly TOOL_CALL: string = 'tool_call';
}

/** 工具终态（snake_case）。 */
export class ToolTerminalStatus {
  static readonly SUCCEEDED: string = 'succeeded';
  static readonly FAILED: string = 'failed';
  static readonly PARTIAL: string = 'partial';
  static readonly CANCELLED: string = 'cancelled';
  static readonly TIMED_OUT: string = 'timed_out';
  static readonly BACKGROUNDED: string = 'backgrounded';
  static readonly INDETERMINATE: string = 'indeterminate';
  static readonly DENIED: string = 'denied';
}

/** turn 终态（snake_case）。 */
export class TurnTerminal {
  static readonly COMPLETED: string = 'completed';
  static readonly FAILED: string = 'failed';
  static readonly CANCELLED: string = 'cancelled';
}

/** turn 中断原因（snake_case）。 */
export class InterruptReason {
  static readonly CRASH: string = 'crash';
  static readonly RESTART: string = 'restart';
  static readonly CANCEL_BEFORE_SEAL: string = 'cancel_before_seal';
  static readonly UNKNOWN_FACT: string = 'unknown_fact';
}

function requireEnumValue(holder: object, field: string, allowed: string[]): string {
  const value: string = requiredString(holder, field);
  if (!allowed.includes(value)) {
    throw new ProtocolError('invalid_enum_value', `${field}: ${value}`);
  }
  return value;
}

/** 交互请求（授权闭环的起点）。 */
export class InteractionRequestedDelta {
  readonly revision: number;
  readonly interactionId: string;
  readonly callId: string | undefined;
  readonly kind: string;
  readonly request: RingingV2ContentValue;
  readonly expiresAtMs: number | undefined;

  constructor(holder: object) {
    this.revision = requiredNumber(holder, 'revision');
    this.interactionId = requiredString(holder, 'interaction_id');
    this.callId = optionalString(holder, 'call_id');
    this.kind = requiredString(holder, 'kind');
    if (this.kind !== 'ask' && this.kind !== 'plan' && this.kind !== 'permission') {
      throw new ProtocolError('invalid_interaction_kind', this.kind);
    }
    this.request = parseContentValue(requiredObject(holder, 'request'));
    this.expiresAtMs = optionalNumber(holder, 'expires_at_ms');
  }
}

/** 交互裁决（first-answer-wins 的胜者视角）。 */
export class InteractionResolvedDelta {
  readonly revision: number;
  readonly interactionId: string;
  readonly decision: RingingV2ContentValue;
  readonly resolvedBy: object;
  readonly resolutionSeq: number;
  readonly raw: object;

  constructor(holder: object) {
    this.raw = holder;
    this.revision = requiredNumber(holder, 'revision');
    this.interactionId = requiredString(holder, 'interaction_id');
    this.decision = parseContentValue(requiredObject(holder, 'decision'));
    this.resolvedBy = requiredObject(holder, 'resolved_by');
    this.resolutionSeq = requiredNumber(holder, 'resolution_seq');
  }
}

/** 交互过期。 */
export class InteractionExpiredDelta {
  readonly revision: number;
  readonly interactionId: string;
  readonly raw: object;

  constructor(holder: object) {
    this.raw = holder;
    this.revision = requiredNumber(holder, 'revision');
    this.interactionId = requiredString(holder, 'interaction_id');
  }
}

/** 活动状态（idle / running / interrupted）。 */
export class ActivityDelta {
  readonly revision: number;
  readonly turnId: string | undefined;
  readonly callId: string | undefined;
  readonly state: string;

  constructor(holder: object) {
    this.revision = requiredNumber(holder, 'revision');
    this.turnId = optionalString(holder, 'turn_id');
    this.callId = optionalString(holder, 'call_id');
    this.state = requiredString(holder, 'state');
    if (this.state !== 'idle' && this.state !== 'running' && this.state !== 'interrupted') {
      throw new ProtocolError('invalid_activity_state', this.state);
    }
  }
}

/**
 * 驱动席变更（`projection_event.rs` ControlDelta::DriverChanged）：
 * holder 缺省 = 已释放。手机的输入闭环靠它判断席位归谁——桌面端持席时
 * conversation 命令会被 `not_driver` 拒，本端据此提示而不是盲重试。
 */
export class DriverChangedDelta {
  readonly revision: number;
  /** 持席端标识；缺省/空串 = 无人持席。 */
  readonly holder: string | undefined;
  readonly driverEpoch: number;

  constructor(holder: object) {
    this.revision = requiredNumber(holder, 'revision');
    this.holder = optionalString(holder, 'holder');
    this.driverEpoch = requiredNumber(holder, 'driver_epoch');
    if (!isSafeInteger(this.driverEpoch) || this.driverEpoch < 0) {
      throw new ProtocolError('invalid_driver_epoch', '');
    }
  }

  holderValue(): string {
    return this.holder !== undefined ? this.holder : '';
  }

  released(): boolean {
    return this.holderValue().length === 0;
  }
}

/**
 * 本端不逐字段消费的 ControlDelta 变体——**包括后端将来新增的未知 kind**。
 *
 * 展示面对未知 kind 容忍（保留 raw 供 UI 降级），与 M3 InteractionBody 同策略：
 * 后端在快速加变体（driver_changed 就是当晚把手机监视流整条打死的），
 * 而未知控制事件的正确姿态是「这条我不显示」，不是「整个连接作废」。
 * 结构畸形（缺 kind/data、类型不对）仍然响亮失败。
 */
export class OpaqueControlDelta {
  readonly kind: string;
  readonly revision: number | undefined;
  readonly raw: object;

  constructor(kind: string, holder: object) {
    this.kind = kind;
    this.revision = optionalNumber(holder, 'revision');
    this.raw = holder;
  }
}

/** timeline_delta 变体的公共形状（每变体都携带 revision）。 */
export abstract class TimelineDeltaPayload {
  abstract kind(): string;
  readonly revision: number;

  constructor(revision: number) {
    this.revision = revision;
  }
}

export class TimelineInput extends TimelineDeltaPayload {
  readonly inputId: string;
  readonly content: RingingV2ContentValue;

  constructor(holder: object) {
    super(requiredNumber(holder, 'revision'));
    this.inputId = requiredString(holder, 'input_id');
    this.content = parseContentValue(requiredObject(holder, 'content'));
  }

  kind(): string {
    return TimelineDeltaKind.INPUT;
  }
}

export class TimelineDeltaBlock extends TimelineDeltaPayload {
  readonly blockId: string;
  readonly blockKind: string;
  readonly content: RingingV2ContentValue;

  constructor(holder: object) {
    super(requiredNumber(holder, 'revision'));
    this.blockId = requiredString(holder, 'block_id');
    this.blockKind = requireEnumValue(holder, 'block_kind',
      [AssistantBlockKind.REASONING, AssistantBlockKind.ANSWER,
        AssistantBlockKind.TOOL_CALL]);
    this.content = parseContentValue(requiredObject(holder, 'content'));
  }

  kind(): string {
    return TimelineDeltaKind.BLOCK;
  }
}

export class TimelineToolCall extends TimelineDeltaPayload {
  readonly callId: string;
  readonly toolName: string;
  readonly args: RingingV2ContentValue;

  constructor(holder: object) {
    super(requiredNumber(holder, 'revision'));
    this.callId = requiredString(holder, 'call_id');
    this.toolName = requiredString(holder, 'tool_name');
    this.args = parseContentValue(requiredObject(holder, 'args'));
  }

  kind(): string {
    return TimelineDeltaKind.TOOL_CALL;
  }
}

export class TimelineToolResult extends TimelineDeltaPayload {
  readonly callId: string;
  readonly terminalStatus: string;
  readonly output: RingingV2ContentValue | undefined;
  readonly error: object | undefined;

  constructor(holder: object) {
    super(requiredNumber(holder, 'revision'));
    this.callId = requiredString(holder, 'call_id');
    this.terminalStatus = requireEnumValue(holder, 'terminal_status',
      [ToolTerminalStatus.SUCCEEDED, ToolTerminalStatus.FAILED,
        ToolTerminalStatus.PARTIAL, ToolTerminalStatus.CANCELLED,
        ToolTerminalStatus.TIMED_OUT, ToolTerminalStatus.BACKGROUNDED,
        ToolTerminalStatus.INDETERMINATE, ToolTerminalStatus.DENIED]);
    this.output = parseOptionalContentValue(holder, 'output');
    this.error = optionalObject(holder, 'error');
  }

  kind(): string {
    return TimelineDeltaKind.TOOL_RESULT;
  }
}

export class TimelineTurnFinished extends TimelineDeltaPayload {
  readonly turnId: string;
  readonly terminal: string;

  constructor(holder: object) {
    super(requiredNumber(holder, 'revision'));
    this.turnId = requiredString(holder, 'turn_id');
    this.terminal = requireEnumValue(holder, 'terminal',
      [TurnTerminal.COMPLETED, TurnTerminal.FAILED, TurnTerminal.CANCELLED]);
  }

  kind(): string {
    return TimelineDeltaKind.TURN_FINISHED;
  }
}

export class TimelineTurnInterrupted extends TimelineDeltaPayload {
  readonly turnId: string;
  readonly reason: string;

  constructor(holder: object) {
    super(requiredNumber(holder, 'revision'));
    this.turnId = requiredString(holder, 'turn_id');
    this.reason = requireEnumValue(holder, 'reason',
      [InterruptReason.CRASH, InterruptReason.RESTART,
        InterruptReason.CANCEL_BEFORE_SEAL, InterruptReason.UNKNOWN_FACT]);
  }

  kind(): string {
    return TimelineDeltaKind.TURN_INTERRUPTED;
  }
}

export class TimelineCompaction extends TimelineDeltaPayload {
  readonly checkpointId: string;
  readonly summary: RingingV2ContentValue;

  constructor(holder: object) {
    super(requiredNumber(holder, 'revision'));
    this.checkpointId = requiredString(holder, 'checkpoint_id');
    this.summary = parseContentValue(requiredObject(holder, 'summary'));
  }

  kind(): string {
    return TimelineDeltaKind.COMPACTION;
  }
}

export class TimelineUnmodeled extends TimelineDeltaPayload {
  private readonly wireKind: string;
  readonly raw: object;

  constructor(kind: string, holder: object) {
    super(optionalNumber(holder, 'revision') ?? 0);
    this.wireKind = kind;
    this.raw = holder;
  }

  kind(): string {
    return this.wireKind;
  }
}

function parseOptionalContentValue(holder: object,
  field: string): RingingV2ContentValue | undefined {
  const valueObject: object | undefined = optionalObject(holder, field);
  return valueObject !== undefined ? parseContentValue(valueObject) : undefined;
}

export function parseTimelineDelta(data: object): TimelineDeltaPayload {
  const deltaKind: string = requiredString(data, 'kind');
  const deltaData: object = requiredObject(data, 'data');
  if (deltaKind === TimelineDeltaKind.INPUT) {
    return new TimelineInput(deltaData);
  }
  if (deltaKind === TimelineDeltaKind.BLOCK) {
    return new TimelineDeltaBlock(deltaData);
  }
  if (deltaKind === TimelineDeltaKind.TOOL_CALL) {
    return new TimelineToolCall(deltaData);
  }
  if (deltaKind === TimelineDeltaKind.TOOL_RESULT) {
    return new TimelineToolResult(deltaData);
  }
  if (deltaKind === TimelineDeltaKind.TURN_FINISHED) {
    return new TimelineTurnFinished(deltaData);
  }
  if (deltaKind === TimelineDeltaKind.TURN_INTERRUPTED) {
    return new TimelineTurnInterrupted(deltaData);
  }
  if (deltaKind === TimelineDeltaKind.COMPACTION) {
    return new TimelineCompaction(deltaData);
  }
  // 与 ControlDelta 同策略：后端新增 timeline 变体不该让手机的事件流作废。
  return new TimelineUnmodeled(deltaKind, deltaData);
}

/** 顶层 payload：kind + 已解析的 data。 */
export class ProjectionPayload {
  readonly kind: string;
  interactionRequested: InteractionRequestedDelta | undefined;
  interactionResolved: InteractionResolvedDelta | undefined;
  interactionExpired: InteractionExpiredDelta | undefined;
  activity: ActivityDelta | undefined;
  driverChanged: DriverChangedDelta | undefined;
  opaqueControl: OpaqueControlDelta | undefined;
  /** 后端新增/我们未列入全集的 control delta kind（漂移可见化用，空串 = 无）。 */
  unrecognizedControlKind: string = '';
  /** 同上，timeline 变体的漂移可见化。 */
  unrecognizedTimelineKind: string = '';
  timeline: TimelineDeltaPayload | undefined;
  readonly raw: object;

  private constructor(kind: string, holder: object) {
    this.kind = kind;
    this.raw = holder;
    this.interactionRequested = undefined;
    this.interactionResolved = undefined;
    this.interactionExpired = undefined;
    this.activity = undefined;
    this.driverChanged = undefined;
    this.opaqueControl = undefined;
    this.timeline = undefined;
  }

  static parse(holder: object): ProjectionPayload {
    const kind: string = requiredString(holder, 'kind');
    if (kind === PayloadKind.CONTROL_DELTA) {
      return ProjectionPayload.parseControlDelta(requiredObject(holder, 'data'));
    }
    if (kind === PayloadKind.TIMELINE_DELTA) {
      const payload: ProjectionPayload = new ProjectionPayload(kind, holder);
      payload.timeline = parseTimelineDelta(requiredObject(holder, 'data'));
      if (!TimelineDeltaKind.isKnown(payload.timeline.kind())) {
        payload.unrecognizedTimelineKind = payload.timeline.kind();
      }
      return payload;
    }
    if (kind === PayloadKind.CONVERSATION_DELTA ||
      kind === PayloadKind.RESOURCE_DELTA || kind === PayloadKind.META_DELTA ||
      kind === PayloadKind.MAILBOX_DELTA || kind === PayloadKind.TEAM_DELTA ||
      kind === PayloadKind.AUDIT_REF || kind === PayloadKind.UNKNOWN) {
      return new ProjectionPayload(kind, holder);
    }
    throw new ProtocolError('invalid_payload_kind', kind);
  }

  private static parseControlDelta(data: object): ProjectionPayload {
    const deltaKind: string = requiredString(data, 'kind');
    const deltaData: object = requiredObject(data, 'data');
    const payload: ProjectionPayload = new ProjectionPayload(PayloadKind.CONTROL_DELTA, data);
    if (deltaKind === ControlDeltaKind.INTERACTION_REQUESTED) {
      payload.interactionRequested = new InteractionRequestedDelta(deltaData);
    } else if (deltaKind === ControlDeltaKind.INTERACTION_RESOLVED) {
      payload.interactionResolved = new InteractionResolvedDelta(deltaData);
    } else if (deltaKind === ControlDeltaKind.INTERACTION_EXPIRED) {
      payload.interactionExpired = new InteractionExpiredDelta(deltaData);
    } else if (deltaKind === ControlDeltaKind.ACTIVITY) {
      payload.activity = new ActivityDelta(deltaData);
    } else if (deltaKind === ControlDeltaKind.DRIVER_CHANGED) {
      payload.driverChanged = new DriverChangedDelta(deltaData);
    } else {
      // 已知但未建模（session_created/round/tool_intent/tool_finished/
      // session_recovered/subagent_*）与后端新增变体同路：收下、不显示、不断流。
      payload.opaqueControl = new OpaqueControlDelta(deltaKind, deltaData);
      if (!ControlDeltaKind.isKnown(deltaKind)) {
        payload.unrecognizedControlKind = deltaKind;
      }
    }
    return payload;
  }
}
