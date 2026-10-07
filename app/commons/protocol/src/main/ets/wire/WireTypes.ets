/**
 * Ringing v2 wire contract（镜像 qaqh-ringing/src/v2/types.rs）。
 *
 * 解析器逐字段校验并构造强类型对象；校验语义与 Rust 侧 validate() 一致，
 * 字段形态不符一律抛 ProtocolError（响亮失败，不静默降级）。
 */

import {
  RINGING_SCHEMA, RINGING_V2_VERSION, isSafeInteger
} from './Constants';
import { ProtocolError, parseJson, requiredString, optionalString, requiredNumber,
  optionalNumber, requiredBoolean, requiredObject, optionalObject } from './Json';
import { CanonicalCursor, CursorToken } from './Cursor';

/** 频道（snake_case wire 值）。 */
export class Channel {
  static readonly CONTROL: string = 'control';
  static readonly CONVERSATION: string = 'conversation';
  static readonly TOOL: string = 'tool';

  static isChannel(value: string): boolean {
    return value === Channel.CONTROL || value === Channel.CONVERSATION || value === Channel.TOOL;
  }
}

/** 投递语义（snake_case）。 */
export class Delivery {
  static readonly RELIABLE: string = 'reliable';
  static readonly REPLACEABLE: string = 'replaceable';
  static readonly EPHEMERAL: string = 'ephemeral';
}

/** 待授权交互类别（snake_case；PlanReview 的 wire 值统一为 `plan`）。 */
export class InteractionKind {
  static readonly PERMISSION: string = 'permission';
  static readonly ASK: string = 'ask';
  static readonly PLAN: string = 'plan';
}

/** open 请求。 */
export class RingingV2OpenRequest {
  readonly schema: string = RINGING_SCHEMA;
  readonly version: number = RINGING_V2_VERSION;
  readonly clientInstanceId: string;

  constructor(clientInstanceId: string) {
    this.clientInstanceId = clientInstanceId;
  }

  toWire(): object {
    return {
      schema: this.schema,
      version: this.version,
      client_instance_id: this.clientInstanceId
    } as OpenRequestWire;
  }
}

interface OpenRequestWire {
  schema: string;
  version: number;
  client_instance_id: string;
}

/** open 响应里的能力集。`single_stream` 必须为 true 才能假定单流语义。 */
export class RingingV2Capabilities {
  readonly subscribe: boolean;
  readonly interact: boolean;
  readonly drive: boolean;
  readonly timeline: boolean;
  readonly service: boolean;
  readonly content: boolean;
  readonly singleStream: boolean;

  constructor(subscribe: boolean, interact: boolean, drive: boolean, timeline: boolean,
    service: boolean, content: boolean, singleStream: boolean) {
    this.subscribe = subscribe;
    this.interact = interact;
    this.drive = drive;
    this.timeline = timeline;
    this.service = service;
    this.content = content;
    this.singleStream = singleStream;
  }

  static parse(holder: object): RingingV2Capabilities {
    const wire = holder as CapabilitiesWire;
    return new RingingV2Capabilities(
      requiredBoolean(holder, 'subscribe'),
      requiredBoolean(holder, 'interact'),
      requiredBoolean(holder, 'drive'),
      requiredBoolean(holder, 'timeline'),
      requiredBoolean(holder, 'service'),
      requiredBoolean(holder, 'content'),
      optionalBooleanDefaultFalse(holder, 'single_stream')
    );
  }
}

function optionalBooleanDefaultFalse(holder: object, field: string): boolean {
  const raw = (holder as Record<string, Object>)[field];
  if (raw === undefined || raw === null) {
    return false;
  }
  if (typeof raw === 'boolean') {
    return raw;
  }
  throw new ProtocolError('bad_field', `${field} must be a boolean`);
}

interface CapabilitiesWire {
  subscribe: boolean;
  interact: boolean;
  drive: boolean;
  timeline: boolean;
  service: boolean;
  content: boolean;
  single_stream?: boolean;
}

/** `POST /ringing/v2/clients/open` 响应。 */
export class RingingV2OpenResponse {
  readonly schema: string;
  readonly version: number;
  readonly accepted: boolean;
  readonly clientSessionId: string;
  readonly serverEpoch: string;
  readonly leaseTtlMs: number;
  readonly renewIntervalMs: number;
  readonly capabilities: RingingV2Capabilities;

  constructor(schema: string, version: number, accepted: boolean, clientSessionId: string,
    serverEpoch: string, leaseTtlMs: number, renewIntervalMs: number,
    capabilities: RingingV2Capabilities) {
    this.schema = schema;
    this.version = version;
    this.accepted = accepted;
    this.clientSessionId = clientSessionId;
    this.serverEpoch = serverEpoch;
    this.leaseTtlMs = leaseTtlMs;
    this.renewIntervalMs = renewIntervalMs;
    this.capabilities = capabilities;
  }

  static parse(text: string): RingingV2OpenResponse {
    return RingingV2OpenResponse.parseValue(parseJson(text));
  }

  static parseValue(holder: object): RingingV2OpenResponse {
    const response: RingingV2OpenResponse = new RingingV2OpenResponse(
      requiredString(holder, 'schema'),
      requiredNumber(holder, 'version'),
      requiredBoolean(holder, 'accepted'),
      requiredString(holder, 'client_session_id'),
      requiredString(holder, 'server_epoch'),
      requiredNumber(holder, 'lease_ttl_ms'),
      requiredNumber(holder, 'renew_interval_ms'),
      RingingV2Capabilities.parse(requiredObject(holder, 'capabilities'))
    );
    response.validate();
    return response;
  }

  validate(): void {
    if (this.schema !== RINGING_SCHEMA || this.version !== RINGING_V2_VERSION ||
      this.clientSessionId.trim().length === 0 || this.serverEpoch.trim().length === 0 ||
      !isSafeInteger(this.leaseTtlMs) || !isSafeInteger(this.renewIntervalMs)) {
      throw new ProtocolError('invalid_open_response', '');
    }
  }
}

/** `POST /ringing/v2/leases/renew` 响应。 */
export class RingingV2LeaseRenewResponse {
  readonly ok: boolean;
  readonly leaseTtlMs: number;
  readonly renewIntervalMs: number;

  constructor(ok: boolean, leaseTtlMs: number, renewIntervalMs: number) {
    this.ok = ok;
    this.leaseTtlMs = leaseTtlMs;
    this.renewIntervalMs = renewIntervalMs;
  }

  static parse(text: string): RingingV2LeaseRenewResponse {
    const holder: object = parseJson(text);
    const response: RingingV2LeaseRenewResponse = new RingingV2LeaseRenewResponse(
      requiredBoolean(holder, 'ok'),
      requiredNumber(holder, 'lease_ttl_ms'),
      requiredNumber(holder, 'renew_interval_ms')
    );
    return response;
  }
}

/** 单流事件的流键：频道键或资源键。 */
export abstract class RingingV2StreamKey {
  abstract kind(): string;
}

export class StreamKeyChannel extends RingingV2StreamKey {
  readonly channel: string;

  constructor(channel: string) {
    super();
    if (!Channel.isChannel(channel)) {
      throw new ProtocolError('invalid_stream_key', `unknown channel: ${channel}`);
    }
    this.channel = channel;
  }

  kind(): string {
    return 'channel';
  }
}

export class StreamKeyResource extends RingingV2StreamKey {
  readonly resourceKind: string;
  readonly resourceId: string;

  constructor(resourceKind: string, resourceId: string) {
    super();
    this.resourceKind = resourceKind;
    this.resourceId = resourceId;
  }

  kind(): string {
    return 'resource';
  }
}

/** v2 事件信封（payload 保持为原始 object，由 Payload.ets 顶层解析）。 */
export class RingingV2EventEnvelope {
  readonly schema: string;
  readonly version: number;
  readonly serverEpoch: string;
  readonly sessionId: string;
  readonly eventId: string;
  readonly streamKey: RingingV2StreamKey;
  readonly delivery: string;
  readonly cursor: CursorToken | undefined;
  readonly logId: string | undefined;
  readonly factSeq: number | undefined;
  readonly projectionIndex: number | undefined;
  readonly revision: number | undefined;
  readonly causationId: string | undefined;
  readonly correlationId: string | undefined;
  readonly tsMs: number | undefined;
  readonly payload: object;

  private constructor(holder: object) {
    this.schema = requiredString(holder, 'schema');
    this.version = requiredNumber(holder, 'version');
    this.serverEpoch = requiredString(holder, 'server_epoch');
    this.sessionId = requiredString(holder, 'session_id');
    this.eventId = requiredString(holder, 'event_id');
    this.streamKey = parseStreamKey(requiredObject(holder, 'stream_key'));
    this.delivery = requiredString(holder, 'delivery');
    if (this.delivery !== Delivery.RELIABLE && this.delivery !== Delivery.REPLACEABLE &&
      this.delivery !== Delivery.EPHEMERAL) {
      throw new ProtocolError('invalid_v2_envelope', `unknown delivery: ${this.delivery}`);
    }
    this.cursor = optionalString(holder, 'cursor') !== undefined
      ? CursorToken.fromOpaque(optionalString(holder, 'cursor') as string)
      : undefined;
    this.logId = optionalString(holder, 'log_id');
    this.factSeq = optionalNumber(holder, 'fact_seq');
    this.projectionIndex = optionalNumber(holder, 'projection_index');
    this.revision = optionalNumber(holder, 'revision');
    this.causationId = optionalString(holder, 'causation_id');
    this.correlationId = optionalString(holder, 'correlation_id');
    this.tsMs = optionalNumber(holder, 'ts_ms');
    this.payload = requiredObject(holder, 'payload');
  }

  static parse(text: string): RingingV2EventEnvelope {
    return RingingV2EventEnvelope.parseValue(parseJson(text));
  }

  static parseValue(holder: object): RingingV2EventEnvelope {
    const envelope: RingingV2EventEnvelope = new RingingV2EventEnvelope(holder);
    envelope.validate();
    return envelope;
  }

  /** 与 Rust 侧 validate() 逐条对齐。 */
  validate(): void {
    if (this.schema !== RINGING_SCHEMA || this.version !== RINGING_V2_VERSION ||
      this.serverEpoch.trim().length === 0 || this.sessionId.trim().length === 0 ||
      this.eventId.trim().length === 0 ||
      (this.causationId !== undefined && this.causationId.trim().length === 0) ||
      (this.correlationId !== undefined && this.correlationId.trim().length === 0)) {
      throw new ProtocolError('invalid_v2_envelope', '');
    }
    if (this.delivery === Delivery.RELIABLE) {
      if (this.cursor === undefined) {
        throw new ProtocolError('missing_cursor', '');
      }
      const cursor: CanonicalCursor = this.cursor.decodeReliable();
      if (this.logId !== cursor.logId || this.factSeq !== cursor.factSeq ||
        this.projectionIndex !== cursor.projectionIndex || this.revision === undefined) {
        throw new ProtocolError('reliable_cursor_mismatch', '');
      }
    } else if (this.delivery === Delivery.REPLACEABLE) {
      if (this.cursor !== undefined || this.projectionIndex !== undefined ||
        this.revision === undefined) {
        throw new ProtocolError('invalid_replaceable_envelope', '');
      }
    } else {
      if (this.cursor !== undefined || this.logId !== undefined || this.factSeq !== undefined ||
        this.projectionIndex !== undefined || this.revision !== undefined) {
        throw new ProtocolError('invalid_ephemeral_envelope', '');
      }
    }
  }
}

interface EventEnvelopeWire {
  schema: string;
  version: number;
  server_epoch: string;
  session_id: string;
  event_id: string;
  stream_key: Object;
  delivery: string;
  cursor?: string;
  log_id?: string;
  fact_seq?: number;
  projection_index?: number;
  revision?: number;
  causation_id?: string;
  correlation_id?: string;
  ts_ms?: number;
  payload: Object;
}

function parseStreamKey(holder: object): RingingV2StreamKey {
  const kind: string = requiredString(holder, 'kind');
  if (kind === 'channel') {
    return new StreamKeyChannel(requiredString(holder, 'data'));
  }
  if (kind === 'resource') {
    const data: object = requiredObject(holder, 'data');
    return new StreamKeyResource(requiredString(data, 'kind'), requiredString(data, 'id'));
  }
  throw new ProtocolError('invalid_stream_key', `unknown kind: ${kind}`);
}

interface StreamKeyWire {
  kind: string;
  data: Object;
}

/** 待授权交互的正文载荷（`kind`/`data` 判别式）。 */
export abstract class RingingV2ContentValue {
  abstract kind(): string;
}

export class ContentValueInline extends RingingV2ContentValue {
  readonly text: string;

  constructor(text: string) {
    super();
    this.text = text;
  }

  kind(): string {
    return 'inline';
  }
}

export class ContentValueRef extends RingingV2ContentValue {
  readonly contentRef: string;

  constructor(contentRef: string) {
    super();
    this.contentRef = contentRef;
  }

  kind(): string {
    return 'ref';
  }
}

export class ContentValueUnavailable extends RingingV2ContentValue {
  readonly raw: object;

  constructor(raw: object) {
    super();
    this.raw = raw;
  }

  kind(): string {
    return 'unavailable';
  }
}

export function parseContentValue(holder: object): RingingV2ContentValue {
  const kind: string = requiredString(holder, 'kind');
  const data: object = requiredObject(holder, 'data');
  if (kind === 'inline') {
    return new ContentValueInline(requiredString(data, 'text'));
  }
  if (kind === 'ref') {
    return new ContentValueRef(requiredString(data, 'content_ref'));
  }
  if (kind === 'unavailable') {
    return new ContentValueUnavailable(data);
  }
  throw new ProtocolError('invalid_content_value', `unknown kind: ${kind}`);
}

/** bootstrap 面的挂起交互。 */
export class RingingV2PendingInteraction {
  readonly interactionId: string;
  readonly callId: string;
  readonly turnId: string;
  readonly kind: string;
  readonly request: RingingV2ContentValue | undefined;

  constructor(holder: object) {
    this.interactionId = requiredString(holder, 'interaction_id');
    this.callId = requiredString(holder, 'call_id');
    this.turnId = requiredString(holder, 'turn_id');
    this.kind = requiredString(holder, 'kind');
    if (this.kind !== InteractionKind.PERMISSION && this.kind !== InteractionKind.ASK &&
      this.kind !== InteractionKind.PLAN) {
      throw new ProtocolError('invalid_interaction_kind', this.kind);
    }
    const requestObject: object | undefined = optionalObject(holder, 'request');
    this.request = requestObject !== undefined ? parseContentValue(requestObject) : undefined;
  }

  static parseArray(holder: object, field: string): RingingV2PendingInteraction[] {
    const raw = (holder as Record<string, Object>)[field];
    if (!Array.isArray(raw)) {
      throw new ProtocolError('missing_field', `${field} must be an array`);
    }
    const out: RingingV2PendingInteraction[] = [];
    for (const item of raw as Object[]) {
      if (typeof item !== 'object' || item === null) {
        throw new ProtocolError('bad_field', `${field} entries must be objects`);
      }
      out.push(new RingingV2PendingInteraction(item as object));
    }
    return out;
  }
}

interface PendingInteractionWire {
  interaction_id: string;
  call_id: string;
  turn_id: string;
  kind: string;
  request?: Object;
}

/** v2 driver 席位状态。 */
export class RingingV2DriverState {
  readonly holder: string | undefined;
  readonly driverEpoch: number;
  readonly canClaim: boolean;

  constructor(holder: string | undefined, driverEpoch: number, canClaim: boolean) {
    this.holder = holder;
    this.driverEpoch = driverEpoch;
    this.canClaim = canClaim;
  }

  static parse(holder: object): RingingV2DriverState {
    return new RingingV2DriverState(
      optionalString(holder, 'holder'),
      requiredNumber(holder, 'driver_epoch'),
      requiredBoolean(holder, 'can_claim')
    );
  }
}

/**
 * `POST /ringing/v2/sessions/{id}/driver/claim` 响应（RingingV2DriverClaimResponse）。
 * reason：already_holder（本端已持有，epoch 即当前值）/ driver_busy（活跃
 * holder 在位，拒绝）/ claim_requested（认领已转发，新席位经 DriverChanged
 * 事件生效——客户端轮询重认领拿 epoch 或直接重试命令）。
 */
export class RingingV2DriverClaimResponse {
  readonly accepted: boolean;
  readonly holder: string | undefined;
  readonly driverEpoch: number;
  readonly reason: string;

  constructor(accepted: boolean, holder: string | undefined, driverEpoch: number,
    reason: string) {
    this.accepted = accepted;
    this.holder = holder;
    this.driverEpoch = driverEpoch;
    this.reason = reason;
  }

  static parse(text: string): RingingV2DriverClaimResponse {
    const holder: object = JSON.parse(text) as object;
    return new RingingV2DriverClaimResponse(
      requiredBoolean(holder, 'accepted'),
      optionalString(holder, 'holder'),
      optionalNumber(holder, 'driver_epoch') ?? 0,
      optionalString(holder, 'reason') ?? ''
    );
  }
}

/** reset 事件类型（snake_case wire 值）。 */
export class ResetReason {
  static readonly CURSOR_EXPIRED: string = 'cursor_expired';
  static readonly LOG_ID_MISMATCH: string = 'log_id_mismatch';
  static readonly UNKNOWN_FACT: string = 'unknown_fact';
  static readonly UPGRADE_REQUIRED: string = 'upgrade_required';
  static readonly REPLAY_OVERFLOW: string = 'replay_overflow';
  static readonly EPOCH_MISMATCH: string = 'epoch_mismatch';
  static readonly CROSS_SESSION: string = 'cross_session';
  static readonly SNAPSHOT_MISSING: string = 'snapshot_missing';
  static readonly SNAPSHOT_EXPIRED: string = 'snapshot_expired';
  static readonly SNAPSHOT_HASH_MISMATCH: string = 'snapshot_hash_mismatch';
  static readonly STALE_WRITER: string = 'stale_writer';
  static readonly CONTENT_QUOTA_EXCEEDED: string = 'content_quota_exceeded';
  static readonly PER_CONNECTION_OVERFLOW: string = 'per_connection_overflow';
  static readonly PROGRESS_BUFFER_OVERFLOW: string = 'progress_buffer_overflow';
  static readonly ACTOR_MAILBOX_OVERFLOW: string = 'actor_mailbox_overflow';
}

/** SSE 上的 `ringing.reset_required` 事件体。 */
export class RingingV2ResetRequired {
  readonly schema: string;
  readonly version: number;
  readonly serverEpoch: string;
  readonly sessionId: string;
  readonly logId: string | undefined;
  readonly snapshotCursor: CursorToken | undefined;
  readonly reason: string;

  private constructor(holder: object) {
    this.schema = requiredString(holder, 'schema');
    this.version = requiredNumber(holder, 'version');
    this.serverEpoch = requiredString(holder, 'server_epoch');
    this.sessionId = requiredString(holder, 'session_id');
    this.logId = optionalString(holder, 'log_id');
    const cursorString: string | undefined = optionalString(holder, 'snapshot_cursor');
    this.snapshotCursor = cursorString !== undefined
      ? CursorToken.fromOpaque(cursorString)
      : undefined;
    this.reason = requiredString(holder, 'reason');
  }

  static parse(text: string): RingingV2ResetRequired {
    return RingingV2ResetRequired.parseValue(parseJson(text));
  }

  static parseValue(holder: object): RingingV2ResetRequired {
    const reset: RingingV2ResetRequired = new RingingV2ResetRequired(holder);
    reset.validate();
    return reset;
  }

  validate(): void {
    if (this.schema !== RINGING_SCHEMA || this.version !== RINGING_V2_VERSION ||
      this.serverEpoch.trim().length === 0 || this.sessionId.trim().length === 0) {
      throw new ProtocolError('invalid_reset_required', '');
    }
    if (this.snapshotCursor !== undefined) {
      const cursor: CanonicalCursor = this.snapshotCursor.decodeSnapshot();
      if (this.logId !== cursor.logId) {
        throw new ProtocolError('reset_log_mismatch', '');
      }
    }
  }
}

/**
 * SSE 上的 `ringing.stream_terminated` 事件体（租约被撤销/过期时服务端逐事件
 * 复查后下发，随后立即断流）。后端此帧为裸 json! 字面量，**不带** schema/version，
 * 故校验面只认 code/session_id（axum_impl/v2.rs 事件循环内的终止帧）。
 */
export class RingingV2StreamTerminated {
  static readonly CODE_REVOKED: string = 'revoked';

  readonly code: string;
  readonly sessionId: string;
  readonly message: string;

  private constructor(holder: object) {
    this.code = requiredString(holder, 'code');
    this.sessionId = requiredString(holder, 'session_id');
    this.message = optionalString(holder, 'message') ?? '';
  }

  static parse(text: string): RingingV2StreamTerminated {
    const terminated: RingingV2StreamTerminated =
      new RingingV2StreamTerminated(parseJson(text));
    if (terminated.code.trim().length === 0) {
      throw new ProtocolError('invalid_stream_terminated', '');
    }
    return terminated;
  }
}
