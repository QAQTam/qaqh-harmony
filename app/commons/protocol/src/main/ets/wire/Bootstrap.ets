/**
 * `GET /ringing/v2/sessions/{seed}/bootstrap` 响应。
 *
 * daemon 侧控制频道快照是 `V2ControlState`（session/project 投影形态），
 * 这里对授权闭环所需的字段（interactions / driver / activity / revision）
 * 强类型解析；conversation/tool 的 state 保留为原始 object，待 M2 timeline
 * 迭代再逐字段收紧。
 */

import { RINGING_SCHEMA, RINGING_V2_VERSION } from './Constants';
import { ProtocolError, parseJson, requiredString, requiredNumber, optionalString,
  optionalObject, requiredObject } from './Json';
import { CursorToken, CanonicalCursor } from './Cursor';
import { Channel, RingingV2PendingInteraction, RingingV2DriverState } from './WireTypes';

/** bootstrap 控制频道 state（投影形态，字段名 snake_case）。 */
export class V2ControlState {
  readonly interactions: RingingV2PendingInteraction[];
  readonly driver: RingingV2DriverState | undefined;
  readonly activity: string | undefined;
  readonly currentTurnId: string | undefined;
  readonly currentCallId: string | undefined;
  readonly revision: number;
  readonly lastFactSeq: number;
  /** round / tools / subagents / last_recovery 等 M2 再收紧。 */
  readonly raw: object;

  constructor(holder: object) {
    this.raw = holder;
    this.interactions = RingingV2PendingInteraction.parseArray(holder, 'interactions');
    const driverObject: object | undefined = optionalObject(holder, 'driver');
    this.driver = driverObject !== undefined ? RingingV2DriverState.parse(driverObject) : undefined;
    this.activity = optionalString(holder, 'activity');
    this.currentTurnId = optionalString(holder, 'current_turn_id');
    this.currentCallId = optionalString(holder, 'current_call_id');
    this.revision = requiredNumber(holder, 'revision');
    this.lastFactSeq = requiredNumber(holder, 'last_fact_seq');
  }
}

/** 工具频道 state：`{ "tools": [...] }`。 */
export class V2ToolState {
  readonly tools: Object[];
  readonly raw: object;

  constructor(holder: object) {
    this.raw = holder;
    const raw = (holder as Record<string, Object>)['tools'];
    if (!Array.isArray(raw)) {
      throw new ProtocolError('missing_field', 'tools must be an array');
    }
    this.tools = raw as Object[];
  }
}

/** 单频道快照。`state` 由调用方按频道选择解析器。 */
export class RingingV2ChannelSnapshot {
  readonly channel: string;
  readonly stateRevision: number;
  readonly snapshotVersion: number;
  readonly rawState: object;

  constructor(holder: object, expectedChannel: string) {
    this.channel = requiredString(holder, 'channel');
    this.stateRevision = requiredNumber(holder, 'state_revision');
    this.snapshotVersion = requiredNumber(holder, 'snapshot_version');
    this.rawState = requiredObject(holder, 'state');
    if (this.channel !== expectedChannel) {
      throw new ProtocolError('invalid_snapshot_channel',
        `expected ${expectedChannel}, got ${this.channel}`);
    }
  }
}

/** bootstrap 响应（三频道冻结形态）。 */
export class RingingV2Bootstrap {
  readonly schema: string;
  readonly version: number;
  readonly serverEpoch: string;
  readonly sessionId: string;
  readonly snapshotCursor: CursorToken;
  readonly control: RingingV2ChannelSnapshot;
  readonly controlState: V2ControlState;
  readonly conversation: RingingV2ChannelSnapshot;
  readonly tool: RingingV2ChannelSnapshot;
  readonly toolState: V2ToolState;

  private constructor(holder: object) {
    this.schema = requiredString(holder, 'schema');
    this.version = requiredNumber(holder, 'version');
    this.serverEpoch = requiredString(holder, 'server_epoch');
    this.sessionId = requiredString(holder, 'session_id');
    this.snapshotCursor = CursorToken.fromOpaque(requiredString(holder, 'snapshot_cursor'));
    this.control = new RingingV2ChannelSnapshot(
      requiredObject(holder, 'control'), Channel.CONTROL);
    this.controlState = new V2ControlState(this.control.rawState);
    this.conversation = new RingingV2ChannelSnapshot(
      requiredObject(holder, 'conversation'), Channel.CONVERSATION);
    this.tool = new RingingV2ChannelSnapshot(requiredObject(holder, 'tool'), Channel.TOOL);
    this.toolState = new V2ToolState(this.tool.rawState);
  }

  static parse(text: string): RingingV2Bootstrap {
    return RingingV2Bootstrap.parseValue(parseJson(text));
  }

  static parseValue(holder: object): RingingV2Bootstrap {
    const bootstrap: RingingV2Bootstrap = new RingingV2Bootstrap(holder);
    bootstrap.validate();
    return bootstrap;
  }

  validate(): void {
    if (this.schema !== RINGING_SCHEMA || this.version !== RINGING_V2_VERSION ||
      this.serverEpoch.trim().length === 0 || this.sessionId.trim().length === 0) {
      throw new ProtocolError('invalid_v2_bootstrap', '');
    }
    const cursor: CanonicalCursor = this.snapshotCursor.decodeSnapshot();
    void cursor;
  }

  logId(): string {
    return this.snapshotCursor.decodeSnapshot().logId;
  }
}
