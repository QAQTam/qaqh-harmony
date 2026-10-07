/**
 * Ringing v2 命令上行（镜像 RingingV2CommandEnvelope + 手机端所需命令子集）。
 *
 * 命令 wire 形态：`{ "channel": <channel>, "type": <variant>, ...fields }`
 * （Rust 侧 `RingingCommand` 内部 tag `channel` + 域命令 tag `type` 的展平）。
 * 只有 SessionCreate 允许省略 session_id（daemon 侧拦截校验）。
 */

import { RINGING_SCHEMA, RINGING_V2_VERSION, isSafeInteger } from './Constants';
import { ProtocolError } from './Json';

/** 单个 ask_user 答案。 */
export class AskAnswer {
  readonly questionId: string;
  readonly answer: string;

  constructor(questionId: string, answer: string) {
    this.questionId = questionId;
    this.answer = answer;
  }

  toWire(): Record<string, Object> {
    let wire: Record<string, Object> = {
      'question_id': this.questionId,
      'answer': this.answer
    };
    return wire;
  }
}

/** 命令变体（channel + type + 载荷），由各 builder 构造。 */
export class RingingCommand {
  readonly channel: string;
  readonly wire: object;

  constructor(channel: string, wire: object) {
    this.channel = channel;
    this.wire = wire;
  }
}

export class ControlCommands {
  /** 创建新会话（唯一允许无 session_id 的命令）。 */
  static sessionCreate(closeCurrent: boolean): RingingCommand {
    let command: CommandWire = {
      'type': 'session_create',
      'close_current': closeCurrent
    };
    return new RingingCommand('control', command);
  }

  static sessionResume(sessionId: string): RingingCommand {
    let command: CommandWire = {
      'type': 'session_resume',
      'session_id': sessionId
    };
    return new RingingCommand('control', command);
  }

  /** 只读观测场景的会话归属（不触碰 actor）。 */
  static sessionAttach(sessionId: string): RingingCommand {
    let command: CommandWire = {
      'type': 'session_attach',
      'session_id': sessionId
    };
    return new RingingCommand('control', command);
  }

  static sessionClose(sessionId: string): RingingCommand {
    let command: CommandWire = {
      'type': 'session_close',
      'session_id': sessionId
    };
    return new RingingCommand('control', command);
  }

  static interactionAskRespond(interactionId: string, answers: AskAnswer[]): RingingCommand {
    const wireAnswers: Object[] = [];
    for (const answer of answers) {
      wireAnswers.push(answer.toWire());
    }
    let command: CommandWire = {
      'type': 'interaction_ask_respond',
      'interaction_id': interactionId
    };
    command['answers'] = wireAnswers;
    return new RingingCommand('control', command);
  }

  static interactionAskDismiss(interactionId: string): RingingCommand {
    let command: CommandWire = {
      'type': 'interaction_ask_dismiss',
      'interaction_id': interactionId
    };
    return new RingingCommand('control', command);
  }

  static planReviewRespond(interactionId: string, approved: boolean, message: string,
    autonomous: boolean): RingingCommand {
    let command: CommandWire = {
      'type': 'plan_review_respond',
      'interaction_id': interactionId,
      'approved': approved,
      'autonomous': autonomous
    };
    if (message.length > 0) {
      command['message'] = message;
    }
    return new RingingCommand('control', command);
  }

  /** 认领 driver 席位。staleHolder 非空时允许接管已死 holder。 */
  static driverClaim(clientSessionId: string, staleHolder: string): RingingCommand {
    let command: CommandWire = {
      'type': 'driver_claim',
      'client_session_id': clientSessionId
    };
    if (staleHolder.length > 0) {
      command['stale_holder'] = staleHolder;
    }
    return new RingingCommand('control', command);
  }

  static driverRelease(clientSessionId: string, expectedEpoch: number): RingingCommand {
    let command: CommandWire = {
      'type': 'driver_release',
      'client_session_id': clientSessionId
    };
    if (expectedEpoch > 0) {
      command['expected_epoch'] = expectedEpoch;
    }
    return new RingingCommand('control', command);
  }
}

export class ConversationCommands {
  static sendMessage(text: string): RingingCommand {
    let command: CommandWire = {
      'type': 'conversation_send_message',
      'text': text
    };
    return new RingingCommand('conversation', command);
  }

  static cancel(turnId: string): RingingCommand {
    let command: CommandWire = { 'type': 'conversation_cancel' };
    if (turnId.length > 0) {
      command['turn_id'] = turnId;
    }
    return new RingingCommand('conversation', command);
  }
}

export class ToolCommands {
  /** 权限请求响应（M3 授权闭环的上行命令）。 */
  static toolPermissionRespond(toolCallId: string, approved: boolean, trustFolder: boolean):
    RingingCommand {
    let command: CommandWire = {
      'type': 'tool_permission_respond',
      'tool_call_id': toolCallId,
      'approved': approved,
      'trust_folder': trustFolder
    };
    return new RingingCommand('tool', command);
  }
}

type CommandWire = Record<string, Object>;

/** v2 命令信封。 */
export class RingingV2CommandEnvelope {
  readonly schema: string = RINGING_SCHEMA;
  readonly version: number = RINGING_V2_VERSION;
  readonly commandId: string;
  readonly clientInstanceId: string;
  readonly clientSessionId: string;
  readonly sessionId: string;
  readonly expectedRevision: number | undefined;
  readonly driverEpoch: number | undefined;
  readonly command: RingingCommand;

  private constructor(commandId: string, clientInstanceId: string, clientSessionId: string,
    sessionId: string, command: RingingCommand, expectedRevision: number | undefined,
    driverEpoch: number | undefined) {
    this.commandId = commandId;
    this.clientInstanceId = clientInstanceId;
    this.clientSessionId = clientSessionId;
    this.sessionId = sessionId;
    this.command = command;
    this.expectedRevision = expectedRevision;
    this.driverEpoch = driverEpoch;
  }

  static create(commandId: string, clientInstanceId: string, clientSessionId: string,
    sessionId: string, command: RingingCommand): RingingV2CommandEnvelope {
    return new RingingV2CommandEnvelope(commandId, clientInstanceId, clientSessionId,
      sessionId, command, undefined, undefined);
  }

  withExpectedRevision(revision: number): RingingV2CommandEnvelope {
    return new RingingV2CommandEnvelope(this.commandId, this.clientInstanceId,
      this.clientSessionId, this.sessionId, this.command, revision, undefined);
  }

  withDriverEpoch(epoch: number): RingingV2CommandEnvelope {
    return new RingingV2CommandEnvelope(this.commandId, this.clientInstanceId,
      this.clientSessionId, this.sessionId, this.command, undefined, epoch);
  }

  validate(): void {
    if (this.commandId.trim().length === 0 || this.clientInstanceId.trim().length === 0 ||
      this.clientSessionId.trim().length === 0) {
      throw new ProtocolError('invalid_v2_command_envelope', '');
    }
    if (this.sessionId.length === 0 &&
      this.command.wire['type'] !== 'session_create') {
      throw new ProtocolError('missing_session_id', '');
    }
    if (this.expectedRevision !== undefined && !isSafeInteger(this.expectedRevision)) {
      throw new ProtocolError('invalid_expected_revision', '');
    }
    if (this.driverEpoch !== undefined && !isSafeInteger(this.driverEpoch)) {
      throw new ProtocolError('invalid_driver_epoch', '');
    }
  }

  toWire(): object {
    this.validate();
    // RingingCommand 是内部 tag 枚举:channel 必须在 command 对象里
    // ({"channel":"control","type":...}),与信封顶层的 channel 并存
    // (2026-10-05 真机联调对拍修正,见 handle_command_v2)。
    let commandWire: CommandWire = { 'channel': this.command.channel };
    const source = this.command.wire as Record<string, Object>;
    const keys: string[] = Object.keys(source);
    for (const key of keys) {
      commandWire[key] = source[key];
    }
    let wire: CommandWire = {
      'schema': this.schema,
      'version': this.version,
      'channel': this.command.channel,
      'command_id': this.commandId,
      'client_instance_id': this.clientInstanceId,
      'client_session_id': this.clientSessionId,
      'command': commandWire
    };
    if (this.sessionId.length > 0) {
      wire['session_id'] = this.sessionId;
    }
    if (this.expectedRevision !== undefined) {
      wire['expected_revision'] = this.expectedRevision;
    }
    if (this.driverEpoch !== undefined) {
      wire['driver_epoch'] = this.driverEpoch;
    }
    return wire;
  }
}

/** 从 ACK 响应中核对 command_id（Rust 客户端同款防御）。 */
export function assertAckMatches(commandId: string, ackCommandId: string): void {
  if (ackCommandId !== commandId) {
    throw new ProtocolError('ack_mismatch', 'v2 command ack id does not match submission');
  }
}

/** Crockford base32 字母表——后端 `is_ulid_text` 只认这 26 位大写形态。 */
const CROCKFORD_BASE32: string = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/**
 * 生成命令 id（ULID 形态：10 位毫秒时间戳 + 16 位随机，全大写 Crockford）。
 *
 * 形态不是审美问题：daemon 的 `causation_for_command` 只把 `is_ulid_text`
 * 命中的 id 原样送进 canonical 因果链，其它形态（UUID、`cmd-xxx`…）一律
 * SHA-256 派生成另一个 ULID，客户端原始 id 永不上线——届时事件里的
 * `causation_id` 与本端记录的 command_id 不相等，「等因果事件确认应答
 * 生效」会静默永不收敛（receipt 只能靠 TTL 过期兜底）。
 */
export function newCommandId(): string {
  const chars: string[] = [];
  let remaining: number = Date.now();
  for (let index = 0; index < 10; index++) {
    chars.unshift(CROCKFORD_BASE32.charAt(remaining % 32));
    remaining = Math.floor(remaining / 32);
  }
  for (let index = 0; index < 16; index++) {
    chars.push(CROCKFORD_BASE32.charAt(Math.floor(Math.random() * 32)));
  }
  return chars.join('');
}
