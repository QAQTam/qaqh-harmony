/**
 * v2 命令 ACK / 幂等回执 / 命令状态（镜像 RingingV2CommandAck 及其
 * `existing`/`result` 判别式；wire 值 snake_case）。
 */

import { parseJson, requiredString, optionalString, optionalNumber, requiredObject,
  optionalObject, requiredBoolean, ProtocolError } from './Json';

/** ACK 状态（snake_case）。 */
export class AckStatus {
  static readonly ACCEPTED: string = 'accepted';
  static readonly REJECTED: string = 'rejected';
}

/** 命令执行状态（snake_case；ACK 丢失时用原 command_id 查询）。 */
export class CommandState {
  static readonly ACCEPTED: string = 'accepted';
  static readonly RUNNING: string = 'running';
  static readonly SUCCEEDED: string = 'succeeded';
  static readonly FAILED: string = 'failed';
  static readonly REJECTED: string = 'rejected';
}

/** ask_user 交互结果（snake_case）。 */
export class AskOutcome {
  static readonly ANSWERED: string = 'answered';
  static readonly DISMISSED: string = 'dismissed';
}

/** 命令的类型化终态载荷（`kind` 判别式，snake_case）。 */
export abstract class RingingV2CommandResult {
  abstract kind(): string;
}

export class AskResolvedResult extends RingingV2CommandResult {
  readonly interactionId: string;
  readonly outcome: string;

  constructor(interactionId: string, outcome: string) {
    super();
    this.interactionId = interactionId;
    this.outcome = outcome;
  }

  kind(): string {
    return 'ask_resolved';
  }
}

export class PlanReviewResolvedResult extends RingingV2CommandResult {
  readonly interactionId: string;
  readonly approved: boolean;

  constructor(interactionId: string, approved: boolean) {
    super();
    this.interactionId = interactionId;
    this.approved = approved;
  }

  kind(): string {
    return 'plan_review_resolved';
  }
}

export class PermissionResolvedResult extends RingingV2CommandResult {
  readonly interactionId: string;
  readonly approved: boolean;

  constructor(interactionId: string, approved: boolean) {
    super();
    this.interactionId = interactionId;
    this.approved = approved;
  }

  kind(): string {
    return 'permission_resolved';
  }
}

export function parseCommandResult(holder: object): RingingV2CommandResult {
  const kind: string = requiredString(holder, 'kind');
  if (kind === 'ask_resolved') {
    return new AskResolvedResult(
      requiredString(holder, 'interaction_id'), requiredString(holder, 'outcome'));
  }
  if (kind === 'plan_review_resolved') {
    return new PlanReviewResolvedResult(
      requiredString(holder, 'interaction_id'), requiredBoolean(holder, 'approved'));
  }
  if (kind === 'permission_resolved') {
    return new PermissionResolvedResult(
      requiredString(holder, 'interaction_id'), requiredBoolean(holder, 'approved'));
  }
  throw new ProtocolError('invalid_command_result', `unknown kind: ${kind}`);
}

/** 与已记录结果冲突的来源（`source` 判别式，snake_case）。 */
export abstract class RingingV2ExistingResult {
  abstract source(): string;
}

export class CommandReceiptExisting extends RingingV2ExistingResult {
  readonly state: string;
  readonly terminalEventId: string | undefined;
  readonly errorCode: string | undefined;
  readonly result: RingingV2CommandResult | undefined;

  constructor(holder: object) {
    super();
    this.state = requiredString(holder, 'state');
    this.terminalEventId = optionalString(holder, 'terminal_event_id');
    this.errorCode = optionalString(holder, 'error_code');
    const resultObject: object | undefined = optionalObject(holder, 'result');
    this.result = resultObject !== undefined ? parseCommandResult(resultObject) : undefined;
  }

  source(): string {
    return 'command_receipt';
  }
}

export class InteractionResolvedExisting extends RingingV2ExistingResult {
  readonly result: RingingV2CommandResult;

  constructor(holder: object) {
    super();
    this.result = parseCommandResult(requiredObject(holder, 'result'));
  }

  source(): string {
    return 'interaction_resolved';
  }
}

export function parseExistingResult(holder: object): RingingV2ExistingResult {
  const source: string = requiredString(holder, 'source');
  if (source === 'command_receipt') {
    return new CommandReceiptExisting(holder);
  }
  if (source === 'interaction_resolved') {
    return new InteractionResolvedExisting(holder);
  }
  throw new ProtocolError('invalid_existing_result', `unknown source: ${source}`);
}

/** v2 命令确认。 */
export class RingingV2CommandAck {
  readonly commandId: string;
  readonly status: string;
  readonly code: string | undefined;
  readonly message: string | undefined;
  readonly retryAfterMs: number | undefined;
  readonly existing: RingingV2ExistingResult | undefined;

  private constructor(holder: object) {
    // 拒绝态 ACK（如 not_driver 门禁）的 command_id 是空串（axum_impl/v2.rs
    // driver admission），必须宽容解析；核对由调用方对 accepted 做。
    this.commandId = optionalString(holder, 'command_id') ?? '';
    this.status = requiredString(holder, 'status');
    if (this.status !== AckStatus.ACCEPTED && this.status !== AckStatus.REJECTED) {
      throw new ProtocolError('invalid_ack_status', this.status);
    }
    this.code = optionalString(holder, 'code');
    this.message = optionalString(holder, 'message');
    this.retryAfterMs = optionalNumber(holder, 'retry_after_ms');
    const existingObject: object | undefined = optionalObject(holder, 'existing');
    this.existing =
      existingObject !== undefined ? parseExistingResult(existingObject) : undefined;
  }

  static parse(text: string): RingingV2CommandAck {
    return RingingV2CommandAck.parseValue(parseJson(text));
  }

  static parseValue(holder: object): RingingV2CommandAck {
    return new RingingV2CommandAck(holder);
  }
}

/** `GET /ringing/v2/commands/{command_id}` 响应。 */
export class RingingV2CommandStatus {
  readonly commandId: string;
  readonly state: string;
  readonly payloadFingerprint: string;
  readonly terminalEventId: string | undefined;
  readonly errorCode: string | undefined;
  readonly result: RingingV2CommandResult | undefined;

  constructor(holder: object) {
    this.commandId = requiredString(holder, 'command_id');
    this.state = requiredString(holder, 'state');
    this.payloadFingerprint = requiredString(holder, 'payload_fingerprint');
    this.terminalEventId = optionalString(holder, 'terminal_event_id');
    this.errorCode = optionalString(holder, 'error_code');
    const resultObject: object | undefined = optionalObject(holder, 'result');
    this.result = resultObject !== undefined ? parseCommandResult(resultObject) : undefined;
  }

  static parse(text: string): RingingV2CommandStatus {
    return new RingingV2CommandStatus(parseJson(text));
  }
}
