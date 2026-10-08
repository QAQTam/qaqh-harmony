/**
 * Ringing v2 **Timeline 通道**（镜像 qaqh-domain/src/timeline.rs +
 * axum_impl/timeline_api.rs + axum_impl/sse.rs）。
 *
 * 为什么需要它（2026-10-06 真机定性）：投影单流 `/events` 里**没有正文**。
 * 同一次真机发送，`/events` 只出 1 帧 `control_delta/driver_changed`，
 * 而 `/timeline/events` 出了 389 帧（turn_opened/block_opened/text_delta×364/
 * block_checkpoint/block_sealed/round_sealed/turn_sealed）。桌面 webui 的正文
 * 一直走的就是这条通道：`GET .../timeline`（快照，服务端已把正文摊平成字符串，
 * 客户端不需要再解 content ref）+ `GET .../timeline/events`（增量，按
 * `timeline_seq` 全序去重）。
 *
 * 展示面策略沿用 M6：未知 kind / 未知 event 变体**收下不显示、不断流**，
 * 只把漂移标出来（`unrecognized*` 字段）；结构畸形才抛。
 */

import { RINGING_SCHEMA, RINGING_V2_VERSION, RINGING_V2_BASE_PATH, isSafeInteger }
  from './Constants';
import { ProtocolError, parseJson, requiredString, optionalString, requiredNumber,
  optionalNumber, optionalBoolean, requiredObject, optionalObject, isArray } from './Json';

/** `GET /ringing/v2/sessions/{id}/timeline`（快照分页）。 */
export function timelinePath(sessionId: string, limit?: number,
  beforeIndex?: number): string {
  const base: string = `${RINGING_V2_BASE_PATH}/sessions/${sessionId}/timeline`;
  const parts: string[] = [];
  if (limit !== undefined) {
    parts.push(`limit=${limit}`);
  }
  if (beforeIndex !== undefined) {
    parts.push(`before_index=${beforeIndex}`);
  }
  return parts.length > 0 ? `${base}?${parts.join('&')}` : base;
}

/**
 * `GET /ringing/v2/sessions/{id}/timeline/events`（直播/续传）。
 * 游标走 `last_event_id` 查询参数，形态 `{server_epoch}:timeline:{seq}`；
 * 缺省 = 从头重放（服务端语义，见 sse.rs parse_timeline_cursor）。
 */
export function timelineEventsPath(sessionId: string, lastEventId?: string): string {
  const base: string =
    `${RINGING_V2_BASE_PATH}/sessions/${sessionId}/timeline/events`;
  if (lastEventId === undefined || lastEventId.length === 0) {
    return base;
  }
  return `${base}?last_event_id=${encodeURIComponent(lastEventId)}`;
}

/** 时间线游标编码。 */
export function encodeTimelineCursor(epoch: string, seq: number): string {
  return `${epoch}:timeline:${seq}`;
}

/**
 * 时间线游标解码：形状不符（epoch 轮换、别的通道的 id）返回 undefined，
 * 由调用方回退全量重放——与 daemon 的告警口径一致，不在客户端猜。
 */
export function parseTimelineCursor(cursor: string,
  epoch: string): number | undefined {
  if (cursor.length === 0 || epoch.length === 0) {
    return undefined;
  }
  const parts: string[] = cursor.split(':');
  if (parts.length !== 3 || parts[0] !== epoch || parts[1] !== 'timeline') {
    return undefined;
  }
  const seq: number = Number.parseInt(parts[2], 10);
  if (Number.isNaN(seq) || !isSafeInteger(seq) || seq < 0) {
    return undefined;
  }
  return seq;
}

/** 展示块类别（timeline.rs TimelineBlockKind）。 */
export class TimelineBlockKind {
  static readonly REASONING: string = 'reasoning';
  static readonly TEXT: string = 'text';
  static readonly TOOL: string = 'tool';
  static readonly NOTICE: string = 'notice';

  static isKnown(value: string): boolean {
    return value === TimelineBlockKind.REASONING || value === TimelineBlockKind.TEXT ||
      value === TimelineBlockKind.TOOL || value === TimelineBlockKind.NOTICE;
  }
}

export class TimelineBlockState {
  static readonly OPEN: string = 'open';
  static readonly SEALED: string = 'sealed';
}

/** 工具态：prepared/running 是进行态，其余是终态（timeline.rs TimelineToolState）。 */
export class TimelineToolState {
  static readonly PREPARED: string = 'prepared';
  static readonly RUNNING: string = 'running';
  static readonly SUCCEEDED: string = 'succeeded';
  static readonly FAILED: string = 'failed';
  static readonly CANCELLED: string = 'cancelled';
  static readonly BACKGROUNDED: string = 'backgrounded';

  static isTerminal(value: string): boolean {
    return value === TimelineToolState.SUCCEEDED ||
      value === TimelineToolState.FAILED ||
      value === TimelineToolState.CANCELLED ||
      value === TimelineToolState.BACKGROUNDED;
  }
}

export class TimelineTurnState {
  static readonly RUNNING: string = 'running';
  static readonly COMPLETED: string = 'completed';
  static readonly FAILED: string = 'failed';
  static readonly CANCELLED: string = 'cancelled';
}

/** TimelineEvent 的 tag 值（`{"type": …}`，timeline.rs serde tag="type"）。 */
export class TimelineEventType {
  static readonly TURN_OPENED: string = 'turn_opened';
  static readonly BLOCK_OPENED: string = 'block_opened';
  static readonly TEXT_DELTA: string = 'text_delta';
  static readonly BLOCK_CHECKPOINT: string = 'block_checkpoint';
  static readonly TOOL_UPDATED: string = 'tool_updated';
  static readonly TOOL_PROGRESS: string = 'tool_progress';
  static readonly TOOL_ESTIMATED: string = 'tool_estimated';
  static readonly BLOCK_SEALED: string = 'block_sealed';
  static readonly ROUND_SEALED: string = 'round_sealed';
  static readonly TURN_SEALED: string = 'turn_sealed';

  static isKnown(value: string): boolean {
    return value === TimelineEventType.TURN_OPENED ||
      value === TimelineEventType.BLOCK_OPENED ||
      value === TimelineEventType.TEXT_DELTA ||
      value === TimelineEventType.BLOCK_CHECKPOINT ||
      value === TimelineEventType.TOOL_UPDATED ||
      value === TimelineEventType.TOOL_PROGRESS ||
      value === TimelineEventType.TOOL_ESTIMATED ||
      value === TimelineEventType.BLOCK_SEALED ||
      value === TimelineEventType.ROUND_SEALED ||
      value === TimelineEventType.TURN_SEALED;
  }
}

/**
 * `TimelineFailure.code` 的结构化值域（2026-10 起）：
 * 模型请求失败槽的 code = gate 统一 ErrorKind 的 snake_case 码
 * （mutil-ai `ErrorKind::as_str()`，经 `qaqh_gate::ErrorKind` 贯通）；
 * 仅本地构造失败（请求未到 gate）保留历史字面量 `model_request_failed`。
 * 工具侧失败槽另有自有码（`tool_denied`/`duplicate_tool_call` 等）。
 *
 * 展示面策略不变：未知 code 照常收下并展示 message（按码分支只对
 * 已知值做，未知值不特殊处理、不断流）。
 */
export class TimelineFailureCode {
  /** 历史字面量：仅本地构造失败（未到 gate）时出现。 */
  static readonly MODEL_REQUEST_FAILED: string = 'model_request_failed';
  static readonly AUTHENTICATION: string = 'authentication';
  static readonly PERMISSION_DENIED: string = 'permission_denied';
  static readonly NOT_FOUND: string = 'not_found';
  static readonly INVALID_REQUEST: string = 'invalid_request';
  static readonly CONTEXT_LENGTH_EXCEEDED: string = 'context_length_exceeded';
  static readonly CONTENT_FILTERED: string = 'content_filtered';
  static readonly RATE_LIMITED: string = 'rate_limited';
  static readonly OVERLOADED: string = 'overloaded';
  static readonly TIMEOUT: string = 'timeout';
  static readonly CONNECTION: string = 'connection';
  static readonly CANCELLED: string = 'cancelled';
  static readonly DECODE: string = 'decode';
  static readonly STREAM_PROTOCOL: string = 'stream_protocol';
  static readonly PROVIDER_INTERNAL: string = 'provider_internal';
  static readonly CONFIGURATION: string = 'configuration';
  static readonly UNKNOWN: string = 'unknown';

  /** gate 实际会给出的 kind 全集（未知值仍在展示面容忍策略内）。 */
  static isKnownGateKind(code: string): boolean {
    return code === TimelineFailureCode.AUTHENTICATION ||
      code === TimelineFailureCode.PERMISSION_DENIED ||
      code === TimelineFailureCode.NOT_FOUND ||
      code === TimelineFailureCode.INVALID_REQUEST ||
      code === TimelineFailureCode.CONTEXT_LENGTH_EXCEEDED ||
      code === TimelineFailureCode.CONTENT_FILTERED ||
      code === TimelineFailureCode.RATE_LIMITED ||
      code === TimelineFailureCode.OVERLOADED ||
      code === TimelineFailureCode.TIMEOUT ||
      code === TimelineFailureCode.CONNECTION ||
      code === TimelineFailureCode.CANCELLED ||
      code === TimelineFailureCode.DECODE ||
      code === TimelineFailureCode.STREAM_PROTOCOL ||
      code === TimelineFailureCode.PROVIDER_INTERNAL ||
      code === TimelineFailureCode.CONFIGURATION ||
      code === TimelineFailureCode.UNKNOWN;
  }
}

/** `TimelineFailure{code,message}`。 */
export class TimelineFailure {
  readonly code: string;
  readonly message: string;

  constructor(holder: object) {
    this.code = requiredString(holder, 'code');
    this.message = requiredString(holder, 'message');
  }
}

/** header 变体判别（对齐 qaqh_domain::TimelineToolHeader 的 `kind`）。 */
export class TimelineToolHeaderKind {
  static readonly PATH: string = 'path';
  static readonly SHELL: string = 'shell';
  static readonly QUERY: string = 'query';
  static readonly OTHER: string = 'other';
  static readonly UNKNOWN: string = 'unknown';
}

/**
 * 类型化标题投影（wire `tool.display.header`，serde tag = `kind`）。
 *
 * 后端已把「这是什么工具、对谁做了什么」算好：path 给文件与操作、shell 给命令、
 * query 给检索式、other 给厂商自定义标签。展示端据此出标题，**不必再从
 * `args_json` 里猜**（旧路径 toolVerbOf 那套动词表就是猜出来的）。
 */
export class TimelineToolHeader {
  readonly kind: string;
  readonly path: string;
  readonly op: string;
  readonly command: string;
  readonly query: string;
  readonly scope: string;
  readonly label: string;

  constructor(holder: object) {
    this.kind = optionalString(holder, 'kind') ?? 'unknown';
    this.path = optionalString(holder, 'path') ?? '';
    this.op = optionalString(holder, 'op') ?? '';
    this.command = optionalString(holder, 'command') ?? '';
    this.query = optionalString(holder, 'query') ?? '';
    this.scope = optionalString(holder, 'scope') ?? '';
    this.label = optionalString(holder, 'label') ?? '';
  }
}

/** body 变体判别（对齐 qaqh_domain::TimelineToolBody 的 `kind`）。 */
export class TimelineToolBodyKind {
  static readonly NONE: string = 'none';
  static readonly TEXT: string = 'text';
  static readonly DIFF: string = 'diff';
  static readonly SHELL: string = 'shell';
  static readonly STREAMS: string = 'streams';
  static readonly SUBAGENT: string = 'subagent';
  static readonly UNKNOWN: string = 'unknown';
}

/**
 * 类型化正文投影（wire `tool.display.body`）。取代按字符串拆信封：
 * `streams` 是 stdout/stderr 分离（旧扁平 `output` 里两者已被拼在一起）、
 * `exit_code`/`truncated` 是权威值（旧路径只能从信封 JSON 里捞）。
 */
export class TimelineToolBody {
  readonly kind: string;
  readonly text: string;
  readonly truncated: boolean;
  readonly unified: string;
  readonly output: string;
  readonly exitCode: number | undefined;
  readonly stdout: string;
  readonly stderr: string;
  readonly interleaved: boolean;
  readonly name: string;
  readonly sessionId: string;

  constructor(holder: object) {
    this.kind = optionalString(holder, 'kind') ?? TimelineToolBodyKind.UNKNOWN;
    this.text = optionalString(holder, 'text') ?? '';
    this.truncated = optionalBoolean(holder, 'truncated') ?? false;
    this.unified = optionalString(holder, 'unified') ?? '';
    this.output = optionalString(holder, 'output') ?? '';
    this.exitCode = optionalNumber(holder, 'exit_code');
    this.stdout = optionalString(holder, 'stdout') ?? '';
    this.stderr = optionalString(holder, 'stderr') ?? '';
    this.interleaved = optionalBoolean(holder, 'interleaved') ?? false;
    this.name = optionalString(holder, 'name') ?? '';
    this.sessionId = optionalString(holder, 'session_id') ?? '';
  }

  /** 是否携带可见正文（`none`/`subagent`/`diff` 之外的空壳返回 false）。 */
  hasContent(): boolean {
    if (this.kind === TimelineToolBodyKind.TEXT) {
      return this.text.length > 0;
    }
    if (this.kind === TimelineToolBodyKind.SHELL) {
      return this.output.length > 0;
    }
    if (this.kind === TimelineToolBodyKind.STREAMS) {
      return this.stdout.length > 0 || this.stderr.length > 0;
    }
    if (this.kind === TimelineToolBodyKind.DIFF) {
      return this.unified.length > 0;
    }
    return false;
  }
}

/** 调用度量（wire `tool.display.metrics`）：耗时/字节/重试，展示端做副行元数据。 */
export class TimelineToolMetrics {
  readonly elapsedMs: number;
  readonly outputBytes: number;
  readonly retryCount: number;
  readonly effectiveToolName: string;
  readonly userInitiated: boolean;

  constructor(holder: object) {
    this.elapsedMs = optionalNumber(holder, 'elapsed_ms') ?? 0;
    this.outputBytes = optionalNumber(holder, 'output_bytes') ?? 0;
    this.retryCount = optionalNumber(holder, 'retry_count') ?? 0;
    this.effectiveToolName = optionalString(holder, 'effective_tool_name') ?? '';
    this.userInitiated = optionalBoolean(holder, 'user_initiated') ?? false;
  }
}

/**
 * 结构化终态（wire `tool.display.outcome`）。与 tool 层的 `state` 是同一事实的
 * 两个投影（`state` 管流程、`outcome` 管结果），退出码优先级：body → 顶层槽 →
 * outcome（对齐 TUI adapter 的取值顺序）。
 */
export class TimelineToolOutcome {
  readonly state: string;
  readonly exitCode: number | undefined;
  readonly durationMs: number | undefined;
  readonly outputBytes: number | undefined;
  readonly truncated: boolean | undefined;

  constructor(holder: object) {
    this.state = optionalString(holder, 'state') ?? 'unknown';
    this.exitCode = optionalNumber(holder, 'exit_code');
    this.durationMs = optionalNumber(holder, 'duration_ms');
    this.outputBytes = optionalNumber(holder, 'output_bytes');
    this.truncated = optionalBoolean(holder, 'truncated');
  }
}

/**
 * 类型化展示投影（wire `tool.display`，跨仓展示契约 §3.3）。
 *
 * 后端保证：全部字段可选，未知 header/body 变体解析为 unknown，**缺失时客户端
 * 完整回退旧扁平字段**（H16）。所以要按「display 优先、扁平兜底」消费，而不是
 * 反过来从 `output` 字符串里拆结构——那是 display 出现之前的旧路径。
 */
export class TimelineToolDisplay {
  readonly summary: string;
  readonly diff: string;
  readonly linesAdded: number;
  readonly linesRemoved: number;
  readonly header: TimelineToolHeader | undefined;
  readonly body: TimelineToolBody | undefined;
  readonly metrics: TimelineToolMetrics | undefined;
  readonly outcome: TimelineToolOutcome | undefined;

  constructor(holder: object) {
    this.summary = optionalString(holder, 'summary') ?? '';
    this.diff = optionalString(holder, 'diff') ?? '';
    this.linesAdded = optionalNumber(holder, 'lines_added') ?? 0;
    this.linesRemoved = optionalNumber(holder, 'lines_removed') ?? 0;
    const headerObject: object | undefined = optionalObject(holder, 'header');
    this.header = headerObject !== undefined ? new TimelineToolHeader(headerObject) : undefined;
    const bodyObject: object | undefined = optionalObject(holder, 'body');
    this.body = bodyObject !== undefined ? new TimelineToolBody(bodyObject) : undefined;
    const metricsObject: object | undefined = optionalObject(holder, 'metrics');
    this.metrics = metricsObject !== undefined
      ? new TimelineToolMetrics(metricsObject) : undefined;
    const outcomeObject: object | undefined = optionalObject(holder, 'outcome');
    this.outcome = outcomeObject !== undefined
      ? new TimelineToolOutcome(outcomeObject) : undefined;
  }
}

function optionalFailure(holder: object, field: string): TimelineFailure | undefined {
  const raw: object | undefined = optionalObject(holder, field);
  return raw !== undefined ? new TimelineFailure(raw) : undefined;
}

/** `TimelineTool`：正文侧只取渲染卡片需要的字段。 */
export class TimelineTool {
  readonly toolCallId: string;
  readonly name: string;
  readonly state: string;
  readonly summary: string;
  readonly argsText: string;
  readonly output: string;
  readonly diff: string;
  readonly progress: string;
  readonly progressTruncated: boolean;
  readonly failure: TimelineFailure | undefined;
  /** 类型化展示投影；缺失 = 该工具未挂 display（自定义工具），展示端走扁平兜底。 */
  readonly display: TimelineToolDisplay | undefined;
  /** 进度流标识（`stdout` | `stderr`）：区分进行中输出来自哪个流。 */
  readonly progressStream: string;
  /** 本次调用累计观测字节（emitted + dropped）。 */
  readonly progressBytesTotal: number;
  /** 工具退出码顶层槽（body/outcome 之外的第三个投影）。 */
  readonly exitCode: number | undefined;

  constructor(holder: object) {
    this.toolCallId = requiredString(holder, 'tool_call_id');
    this.name = requiredString(holder, 'name');
    this.state = requiredString(holder, 'state');
    this.summary = optionalString(holder, 'summary') ?? '';
    this.argsText = optionalString(holder, 'args_json') ?? '';
    this.output = optionalString(holder, 'output') ?? '';
    this.diff = optionalString(holder, 'diff') ?? '';
    this.progress = optionalString(holder, 'progress') ?? '';
    this.progressTruncated = optionalBoolean(holder, 'progress_truncated') ?? false;
    this.failure = optionalFailure(holder, 'failure');
    const displayObject: object | undefined = optionalObject(holder, 'display');
    this.display = displayObject !== undefined
      ? new TimelineToolDisplay(displayObject) : undefined;
    this.progressStream = optionalString(holder, 'progress_stream') ?? '';
    this.progressBytesTotal = optionalNumber(holder, 'progress_bytes_total') ?? 0;
    this.exitCode = optionalNumber(holder, 'exit_code');
  }

  /**
   * 退出码：优先类型化 body → 顶层槽 → outcome（对齐 TUI adapter 的取值顺序，
   * 三者是同一事实的三个投影，取先到者）。
   */
  resolvedExitCode(): number | undefined {
    const display: TimelineToolDisplay | undefined = this.display;
    if (display !== undefined && display.body !== undefined &&
      display.body.exitCode !== undefined) {
      return display.body.exitCode;
    }
    if (this.exitCode !== undefined) {
      return this.exitCode;
    }
    return display !== undefined && display.outcome !== undefined
      ? display.outcome.exitCode : undefined;
  }
}

/** `TimelineBlock`（快照里的已物化块；直播里由 block_opened 引入）。 */
export class TimelineBlock {
  readonly blockId: string;
  readonly blockOrder: number;
  readonly kind: string;
  readonly state: string;
  readonly text: string;
  readonly tool: TimelineTool | undefined;

  constructor(holder: object) {
    this.blockId = requiredString(holder, 'block_id');
    this.blockOrder = requiredNumber(holder, 'block_order');
    this.kind = requiredString(holder, 'kind');
    this.state = requiredString(holder, 'state');
    this.text = optionalString(holder, 'text') ?? '';
    const toolObject: object | undefined = optionalObject(holder, 'tool');
    this.tool = toolObject !== undefined ? new TimelineTool(toolObject) : undefined;
  }
}

export class TimelineRound {
  readonly roundNum: number;
  readonly sealed: boolean;
  readonly isFinal: boolean;
  readonly blocks: TimelineBlock[];

  constructor(holder: object) {
    this.roundNum = requiredNumber(holder, 'round_num');
    this.sealed = (holder as Record<string, Object>)['sealed'] === true;
    this.isFinal = (holder as Record<string, Object>)['is_final'] === true;
    const raw: Object[] = ((holder as Record<string, Object>)['blocks'] !== undefined &&
      isArray((holder as Record<string, Object>)['blocks']))
      ? (holder as Record<string, Object>)['blocks'] as Object[] : [];
    const blocks: TimelineBlock[] = [];
    for (const entry of raw) {
      blocks.push(new TimelineBlock(entry as object));
    }
    this.blocks = blocks;
  }
}

export class TimelineTurn {
  readonly turnId: string;
  /** 全局回合序号：**当前 daemon 在 rehydrate 后把它覆盖成 null**（深翻页游标
   * 因此不可依赖），缺省时由 `total_turns - 已载入条数` 推。见 M7 记录。 */
  readonly turnIndex: number | undefined;
  readonly createdSeq: number;
  readonly userText: string;
  readonly sealed: boolean;
  readonly state: string;
  readonly failure: TimelineFailure | undefined;
  readonly rounds: TimelineRound[];

  constructor(holder: object) {
    this.turnId = requiredString(holder, 'turn_id');
    this.turnIndex = optionalNumber(holder, 'turn_index');
    this.createdSeq = optionalNumber(holder, 'created_seq') ?? 0;
    this.userText = optionalString(holder, 'user_text') ?? '';
    this.sealed = (holder as Record<string, Object>)['sealed'] === true;
    this.state = requiredString(holder, 'state');
    this.failure = optionalFailure(holder, 'failure');
    const raw: Object[] = isArray((holder as Record<string, Object>)['rounds'])
      ? (holder as Record<string, Object>)['rounds'] as Object[] : [];
    const rounds: TimelineRound[] = [];
    for (const entry of raw) {
      rounds.push(new TimelineRound(entry as object));
    }
    this.rounds = rounds;
  }
}

/** `GET .../timeline` 响应。 */
export class TimelineSnapshotResponse {
  readonly schema: string;
  readonly version: number;
  readonly serverEpoch: string;
  readonly sessionId: string;
  readonly watermark: number;
  readonly turns: TimelineTurn[];
  readonly hasMore: boolean;
  readonly totalTurns: number;
  /** 物化窗口没覆盖到历史开头：还有更早的回合，别把当前页当完整历史。 */
  readonly truncatedBefore: boolean;

  private constructor(holder: object) {
    this.schema = requiredString(holder, 'schema');
    this.version = requiredNumber(holder, 'version');
    this.serverEpoch = requiredString(holder, 'server_epoch');
    this.sessionId = requiredString(holder, 'session_id');
    const snapshot: object = requiredObject(holder, 'snapshot');
    this.watermark = requiredNumber(snapshot, 'watermark');
    const raw: Object[] = isArray((snapshot as Record<string, Object>)['turns'])
      ? (snapshot as Record<string, Object>)['turns'] as Object[] : [];
    const turns: TimelineTurn[] = [];
    for (const entry of raw) {
      turns.push(new TimelineTurn(entry as object));
    }
    this.turns = turns;
    this.hasMore = (holder as Record<string, Object>)['has_more'] === true;
    this.totalTurns = requiredNumber(holder, 'total_turns');
    this.truncatedBefore = (holder as Record<string, Object>)['truncated_before'] === true;
  }

  static parse(text: string): TimelineSnapshotResponse {
    const page: TimelineSnapshotResponse = new TimelineSnapshotResponse(parseJson(text));
    if (page.schema !== RINGING_SCHEMA || page.version !== RINGING_V2_VERSION ||
      !isSafeInteger(page.watermark) || !isSafeInteger(page.totalTurns)) {
      throw new ProtocolError('invalid_timeline_snapshot', '');
    }
    return page;
  }

  /**
   * 深翻页游标（排他上界）：优先用服务端给的全局序号；缺省时按
   * 「本页是最新的连续一段」推算 `total_turns - 本页条数`。
   *
   * 为什么要兜底：`handle_timeline_snapshot` 回填 `turn_index` 后又要过
   * `rehydrate_timeline_page`，而已 offload 的回合被 sidecar 全文**整体替换**，
   * 序号就丢了（实测 4 个回合全为 null）。客户端拿不到游标会永远停在最新一页。
   * 真游标应由 daemon 在 rehydrate 后重新回填——已在 M7 记录里报给后端。
   */
  oldestIndex(): number {
    if (this.turns.length === 0) {
      return this.totalTurns;
    }
    const explicit: number | undefined = this.turns[0].turnIndex;
    if (explicit !== undefined) {
      return explicit;
    }
    return Math.max(0, this.totalTurns - this.turns.length);
  }
}

/** `TimelineEvent`（tag=`type`）的宽松形态：字段按变体取，缺省为空。 */
export class TimelineEvent {
  readonly type: string;
  readonly userText: string;
  readonly block: TimelineBlock | undefined;
  readonly blockId: string;
  readonly fragmentSeq: number;
  readonly delta: string;
  readonly arg: string;
  readonly text: string;
  readonly tool: TimelineTool | undefined;
  readonly chunk: string;
  readonly truncated: boolean;
  readonly isFinal: boolean;
  readonly state: string;
  readonly failure: TimelineFailure | undefined;
  /** 未建模/未知变体的原始对象（漂移可见化用）。 */
  readonly raw: object;

  constructor(holder: object) {
    this.raw = holder;
    this.type = requiredString(holder, 'type');
    this.userText = optionalString(holder, 'user_text') ?? '';
    const blockObject: object | undefined = optionalObject(holder, 'block');
    this.block = blockObject !== undefined ? new TimelineBlock(blockObject) : undefined;
    this.blockId = optionalString(holder, 'block_id') ?? '';
    this.fragmentSeq = optionalNumber(holder, 'fragment_seq') ?? 0;
    this.delta = optionalString(holder, 'delta') ?? '';
    this.arg = optionalString(holder, 'arg') ?? '';
    this.text = optionalString(holder, 'text') ?? '';
    const toolObject: object | undefined = optionalObject(holder, 'tool');
    this.tool = toolObject !== undefined ? new TimelineTool(toolObject) : undefined;
    this.chunk = optionalString(holder, 'chunk') ?? '';
    this.truncated = (holder as Record<string, Object>)['truncated'] === true;
    this.isFinal = (holder as Record<string, Object>)['is_final'] === true;
    this.state = optionalString(holder, 'state') ?? '';
    this.failure = optionalFailure(holder, 'failure');
  }

  known(): boolean {
    return TimelineEventType.isKnown(this.type);
  }
}

/** `TimelineEntry{timeline_seq,turn_id,round_num?,event}`。 */
export class TimelineEntry {
  readonly timelineSeq: number;
  readonly turnId: string;
  readonly roundNum: number | undefined;
  readonly event: TimelineEvent;

  constructor(holder: object) {
    this.timelineSeq = requiredNumber(holder, 'timeline_seq');
    this.turnId = requiredString(holder, 'turn_id');
    this.roundNum = optionalNumber(holder, 'round_num');
    this.event = new TimelineEvent(requiredObject(holder, 'event'));
    if (!isSafeInteger(this.timelineSeq) || this.timelineSeq < 0) {
      throw new ProtocolError('invalid_timeline_seq', '');
    }
  }
}

/** `timeline.entry` 帧的 data 体。`version` 必须是 2：服务端注释里记着实测——
 * 写死 1 曾让每一帧被判协议违例，1s 重连死循环、正文永远渲不出来。 */
export class RingingV2TimelineFrame {
  readonly schema: string;
  readonly version: number;
  readonly serverEpoch: string;
  readonly sessionId: string;
  readonly entry: TimelineEntry;

  private constructor(holder: object) {
    this.schema = requiredString(holder, 'schema');
    this.version = requiredNumber(holder, 'version');
    this.serverEpoch = requiredString(holder, 'server_epoch');
    this.sessionId = requiredString(holder, 'session_id');
    this.entry = new TimelineEntry(requiredObject(holder, 'entry'));
  }

  static parse(text: string): RingingV2TimelineFrame {
    const frame: RingingV2TimelineFrame =
      new RingingV2TimelineFrame(parseJson(text));
    if (frame.schema !== RINGING_SCHEMA || frame.version !== RINGING_V2_VERSION) {
      throw new ProtocolError('invalid_timeline_frame',
        `schema=${frame.schema} version=${frame.version}`);
    }
    return frame;
  }
}
