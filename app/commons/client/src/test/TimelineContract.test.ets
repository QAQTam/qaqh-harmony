/**
 * M7 正文通道契约测试：TimelineStream（水位/去重/空洞/epoch 轮换/终止帧）
 * 与 TranscriptModel（快照 seed + 直播增量拼正文）。
 *
 * 帧夹具取自 scripts/wire-smoke.sh 抓到的真 daemon 输出（389 帧那一次）。
 */

import { describe, it, expect } from '@ohos/hypium';

import {
  encodeTimelineCursor, encodeUtf8, ProtocolError, RingingV2StreamTerminated,
  TimelineEntry, TimelineSnapshotResponse, TimelineTurn
} from '@qaqh/protocol';
import { TimelineStream, TimelineStreamListener, TimelineStreamState }
  from '../main/ets/TimelineStream';
import {
  TranscriptRow, TranscriptRowKind, TranscriptModel, TodoItemStatus, toolStatusTone,
  tailLines, headLines, countLines, parseTodoItems, lookupGroupNoun
} from '../main/ets/TranscriptModel';
import { StreamConnection, StreamEndpoint, StreamListener, StreamRequest }
  from '../main/ets/transport/StreamConnection';
import { LeaseTimer } from '../main/ets/transport/Transport';

const EPOCH: string = 'epoch-1';

function frame(entryJson: string, seq: number, turnId?: string): string {
  const turn: string = turnId !== undefined ? turnId : 't2';
  return `id: ${EPOCH}:timeline:${seq}\nevent: timeline.entry\n` +
    `data: {"schema":"qaqh.Ringing","version":2,"server_epoch":"${EPOCH}",` +
    `"session_id":"seed-1","entry":{"timeline_seq":${seq},"turn_id":"${turn}",` +
    `"event":${entryJson}}}\n\n`;
}

class FakeTimer implements LeaseTimer {
  lastIntervalMs: number = -1;
  lastFire: (() => void) | undefined;
  stopped: boolean = false;

  start(intervalMs: number, fire: () => void): void {
    this.lastIntervalMs = intervalMs;
    this.lastFire = fire;
    this.stopped = false;
  }

  stop(): void {
    this.stopped = true;
    this.lastFire = undefined;
  }

  fire(): void {
    if (this.lastFire !== undefined) {
      this.lastFire();
    }
  }
}

class FakeStreamConnection implements StreamConnection {
  readonly requests: StreamRequest[] = [];
  private listener: StreamListener | undefined;

  connect(request: StreamRequest, listener: StreamListener): void {
    this.requests.push(request);
    this.listener = listener;
  }

  cancel(): void {
    this.listener = undefined;
  }

  emit(text: string): void {
    if (this.listener !== undefined) {
      this.listener.onData(encodeUtf8(text));
    }
  }

  emitEnded(status: number): void {
    if (this.listener !== undefined) {
      const current = this.listener;
      this.listener = undefined;
      current.onEnded(status);
    }
  }

  count(): number {
    return this.requests.length;
  }

  lastUrl(): string {
    return this.requests[this.requests.length - 1].url;
  }
}

class RecordingTimelineListener implements TimelineStreamListener {
  entries: number = 0;
  lastSeq: number = -1;
  lastCursor: string = '';
  gaps: string[] = [];
  states: string[] = [];
  httpDisconnects: number[] = [];
  protocolErrors: string[] = [];
  terminations: string[] = [];
  leaseUnavailables: number = 0;

  onEntry(entry: TimelineEntry, cursor: string): void {
    this.entries++;
    this.lastSeq = entry.timelineSeq;
    this.lastCursor = cursor;
  }

  onGap(expectedSeq: number, actualSeq: number): void {
    this.gaps.push(`${expectedSeq}>${actualSeq}`);
  }

  onStatusChanged(state: string): void {
    this.states.push(state);
  }

  onHttpDisconnect(status: number): void {
    this.httpDisconnects.push(status);
  }

  onProtocolError(error: ProtocolError): void {
    this.protocolErrors.push(error.code);
  }

  onStreamTerminated(terminated: RingingV2StreamTerminated): void {
    this.terminations.push(terminated.code);
  }

  onLeaseUnavailable(): void {
    this.leaseUnavailables++;
  }
}

/** 租约开关：出 open 态后组装端点即抛 invalid_state（真机闪退的触发条件）。 */
class LeaseGate {
  open: boolean = true;
}

function makeGatedStream(connection: FakeStreamConnection, timer: FakeTimer,
  listener: RecordingTimelineListener, gate: LeaseGate): TimelineStream {
  return new TimelineStream('seed-1', connection, timer, (): StreamEndpoint => {
    if (!gate.open) {
      throw new ProtocolError('invalid_state', 'requires open state, got closed');
    }
    let headers: Record<string, string> = {
      'Authorization': 'Bearer tok-1',
      'X-QAQH-Client-Session-Id': 'cs-1'
    };
    return new StreamEndpoint('https://daemon.test', headers);
  }, listener, 10, EPOCH);
}

function makeStream(connection: FakeStreamConnection, timer: FakeTimer,
  listener: RecordingTimelineListener, watermark: number): TimelineStream {
  return new TimelineStream('seed-1', connection, timer, (): StreamEndpoint => {
    let headers: Record<string, string> = {
      'Authorization': 'Bearer tok-1',
      'X-QAQH-Client-Session-Id': 'cs-1',
      'Accept': 'text/event-stream'
    };
    return new StreamEndpoint('https://daemon.test', headers);
  }, listener, watermark, watermark > 0 ? EPOCH : '');
}

function snapshotObject(): Record<string, Object> {
  const reasoning: Record<string, Object> = {
    'block_id': 'round-0:reasoning:0', 'block_order': 0,
    'kind': 'reasoning', 'state': 'sealed', 'text': '想了一下'
  };
  const answer: Record<string, Object> = {
    'block_id': 'round-0:text:1', 'block_order': 1,
    'kind': 'text', 'state': 'sealed', 'text': '回答一'
  };
  const round: Record<string, Object> = {
    'round_num': 0, 'sealed': true, 'is_final': true, 'blocks': [reasoning, answer]
  };
  const turn: Record<string, Object> = {
    'turn_id': 't1', 'created_seq': 3, 'user_text': '问题一',
    'sealed': true, 'state': 'completed', 'rounds': [round]
  };
  const snapshot: Record<string, Object> = { 'watermark': 10, 'turns': [turn] };
  const page: Record<string, Object> = {
    'schema': 'qaqh.Ringing', 'version': 2, 'server_epoch': EPOCH,
    'session_id': 'seed-1', 'snapshot': snapshot,
    'has_more': false, 'total_turns': 1, 'truncated_before': false
  };
  return page;
}

function parseSnapshot(): TimelineSnapshotResponse {
  return TimelineSnapshotResponse.parse(JSON.stringify(snapshotObject()));
}

function applyEvent(model: TranscriptModel, seq: number,
  event: Record<string, Object>): void {
  const holder: Record<string, Object> = {
    'timeline_seq': seq, 'turn_id': 't2', 'event': event
  };
  model.applyEntry(new TimelineEntry(holder as object));
}

function findRow(rows: TranscriptRow[], kind: string): TranscriptRow | undefined {
  for (const row of rows) {
    if (row.kind === kind) {
      return row;
    }
  }
  return undefined;
}

function lastRowOfKind(rows: TranscriptRow[], kind: string): TranscriptRow | undefined {
  let found: TranscriptRow | undefined;
  for (const row of rows) {
    if (row.kind === kind) {
      found = row;
    }
  }
  return found;
}

function countRowsOfKind(rows: TranscriptRow[], kind: string): number {
  let n: number = 0;
  for (const row of rows) {
    if (row.kind === kind) {
      n++;
    }
  }
  return n;
}

function blockOpenedEvent(blockId: string, kind: string,
  state: string): Record<string, Object> {
  const block: Record<string, Object> = { 'block_id': blockId, 'block_order': 0,
    'kind': kind, 'state': state };
  return { 'type': 'block_opened', 'block': block };
}

function toolUpdatedEvent(blockId: string, callId: string, name: string,
  state: string, args: string, output: string, progress: string): Record<string, Object> {
  const tool: Record<string, Object> = {
    'tool_call_id': callId, 'name': name, 'state': state, 'args_json': args,
    'output': output, 'progress': progress
  };
  return { 'type': 'tool_updated', 'block_id': blockId, 'tool': tool };
}

export default function timelineStreamContractTest() {
  describe('timeline_stream_contract', () => {
    it('delivers_entries_and_advances_watermark', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingTimelineListener = new RecordingTimelineListener();
      const stream: TimelineStream = makeStream(connection, new FakeTimer(), listener, 0);
      stream.start();

      expect(connection.lastUrl())
        .assertEqual('https://daemon.test/ringing/v2/sessions/seed-1/timeline/events');

      connection.emit(frame('{"type":"turn_opened","user_text":"hi"}', 100, 't2'));
      connection.emit(frame('{"type":"text_delta","block_id":"b1",' +
        '"fragment_seq":1,"delta":"par"}', 101, 't2'));

      expect(listener.entries).assertEqual(2);
      expect(stream.watermarkValue()).assertEqual(101);
      // 游标直接取 SSE id，续传时原样带回。
      expect(stream.cursorValue()).assertEqual(`${EPOCH}:timeline:101`);
      expect(listener.lastCursor).assertEqual(encodeTimelineCursor(EPOCH, 101));
    });

    it('resumes_with_last_event_id_after_clean_eof', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const timer: FakeTimer = new FakeTimer();
      const listener: RecordingTimelineListener = new RecordingTimelineListener();
      const stream: TimelineStream = makeStream(connection, timer, listener, 14072);
      stream.start();

      connection.emit(frame('{"type":"block_sealed","block_id":"b1"}', 14073, 't2'));
      connection.emitEnded(200);
      timer.fire();

      expect(connection.count()).assertEqual(2);
      expect(connection.lastUrl().includes('last_event_id=' +
        encodeURIComponent(`${EPOCH}:timeline:14073`))).assertTrue();
    });

    it('drops_duplicate_seq_and_reports_gap_once', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingTimelineListener = new RecordingTimelineListener();
      const stream: TimelineStream = makeStream(connection, new FakeTimer(), listener, 50);
      stream.start();

      // 重放里已投递过的序号：静默丢弃。
      connection.emit(frame('{"type":"block_sealed","block_id":"b1"}', 50, 't2'));
      expect(listener.entries).assertEqual(0);
      expect(listener.gaps.length).assertEqual(0);

      // 跳号：报一次空洞并停手，等上层重取快照（补帧不会回来）。
      connection.emit(frame('{"type":"block_sealed","block_id":"b1"}', 57, 't2'));
      connection.emit(frame('{"type":"block_sealed","block_id":"b1"}', 58, 't2'));
      expect(listener.gaps.length).assertEqual(1);
      expect(listener.gaps[0]).assertEqual('51>57');
      expect(listener.entries).assertEqual(0);

      // prime（重新 seed）之后恢复投递。
      stream.prime(58, EPOCH);
      connection.emit(frame('{"type":"block_sealed","block_id":"b1"}', 59, 't2'));
      expect(listener.entries).assertEqual(1);
    });

    it('unknown_event_name_does_not_kill_the_stream', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingTimelineListener = new RecordingTimelineListener();
      const stream: TimelineStream = makeStream(connection, new FakeTimer(), listener, 0);
      stream.start();

      connection.emit('event: keepalive.mystery\ndata: {}\n\n');
      connection.emit(frame('{"type":"turn_opened","user_text":"still works"}', 7, 't2'));

      expect(listener.protocolErrors.length).assertEqual(0);
      expect(listener.entries).assertEqual(1);
      expect(stream.stateValue()).assertEqual(TimelineStreamState.CONNECTED);
    });

    it('terminated_frame_stops_stream_and_reports', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const timer: FakeTimer = new FakeTimer();
      const listener: RecordingTimelineListener = new RecordingTimelineListener();
      const stream: TimelineStream = makeStream(connection, timer, listener, 0);
      stream.start();

      connection.emit('event: ringing.stream_terminated\ndata: {"code":"revoked",' +
        '"session_id":"seed-1","message":"lease revoked"}\n\n');
      expect(listener.terminations.length).assertEqual(1);
      expect(listener.terminations[0]).assertEqual('revoked');
      expect(stream.stateValue()).assertEqual(TimelineStreamState.STOPPED);
      connection.emitEnded(200);
      expect(connection.count()).assertEqual(1);
    });

    it('http_4xx_stops_without_retry', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingTimelineListener = new RecordingTimelineListener();
      const stream: TimelineStream = makeStream(connection, new FakeTimer(), listener, 10);
      stream.start();

      connection.emitEnded(401);
      expect(listener.httpDisconnects.length).assertEqual(1);
      expect(listener.httpDisconnects[0]).assertEqual(401);
      expect(stream.stateValue()).assertEqual(TimelineStreamState.STOPPED);
    });

    it('closed_lease_on_retry_fire_does_not_escape', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const timer: FakeTimer = new FakeTimer();
      const listener: RecordingTimelineListener = new RecordingTimelineListener();
      const gate: LeaseGate = new LeaseGate();
      const stream: TimelineStream = makeGatedStream(connection, timer, listener, gate);
      stream.start();

      // 断流 → 1s 退避已武装；期间监视器把共用的 client 关成 CLOSED。
      connection.emitEnded(200);
      gate.open = false;
      // 定时器到点：旧实现在这里把异常抛过 setTimeout 边界 → 进程被杀
      // （真机 04:19 那次 JS_ERROR 就是 timeline 流，不是投影流）。
      timer.fire();

      expect(listener.leaseUnavailables).assertEqual(1);
      expect(stream.stateValue()).assertEqual(TimelineStreamState.STOPPED);
      expect(timer.stopped).assertTrue();
      expect(connection.count()).assertEqual(1);
    });
  });

  describe('transcript_model_contract', () => {
    it('seeds_history_from_snapshot_turns', 0, () => {
      const model: TranscriptModel = new TranscriptModel();
      model.seed(parseSnapshot().turns);

      const rows: TranscriptRow[] = model.rowsRef();
      expect(rows.length).assertEqual(4);
      expect(rows[0].kind).assertEqual(TranscriptRowKind.USER);
      expect(rows[0].text).assertEqual('问题一');
      expect(rows[1].kind).assertEqual(TranscriptRowKind.THINKING);
      expect(rows[1].text).assertEqual('想了一下');
      expect(rows[1].sealed).assertTrue();
      expect(rows[2].kind).assertEqual(TranscriptRowKind.TEXT);
      expect(rows[2].text).assertEqual('回答一');
      expect(rows[3].kind).assertEqual(TranscriptRowKind.MARKER);
      expect(model.turnActiveValue()).assertFalse();
    });

    it('streams_text_delta_incrementally_without_structural_bump', 0, () => {
      const model: TranscriptModel = new TranscriptModel();
      model.seed(parseSnapshot().turns);

      applyEvent(model, 11, { 'type': 'turn_opened', 'user_text': '问题二' });
      const opened: Record<string, Object> = { 'block_id': 'round-0:text:1',
        'block_order': 0, 'kind': 'text', 'state': 'open', 'text': 'He' };
      applyEvent(model, 12, { 'type': 'block_opened', 'block': opened });
      const version: number = model.structuralVersion();
      applyEvent(model, 13, { 'type': 'text_delta', 'block_id': 'round-0:text:1',
        'fragment_seq': 1, 'delta': 'llo' });
      applyEvent(model, 14, { 'type': 'block_checkpoint', 'block_id': 'round-0:text:1',
        'arg': ' world' });

      // O1 关键契约：逐字增量不动结构版本、只标脏对应行（视图据此局部刷新）。
      expect(model.structuralVersion()).assertEqual(version);
      const dirty: TranscriptRow[] = model.drainDirty();
      expect(dirty.length).assertEqual(1);
      expect(dirty[0].kind).assertEqual(TranscriptRowKind.TEXT);
      expect(dirty[0].text).assertEqual('Hello world');
      expect(model.drainDirty().length).assertEqual(0);
      expect(model.turnActiveValue()).assertTrue();

      applyEvent(model, 15, { 'type': 'turn_sealed', 'state': 'completed' });
      expect(model.turnActiveValue()).assertFalse();
    });

    it('block_checkpoint_text_overwrites_when_increment_lost', 0, () => {
      const model: TranscriptModel = new TranscriptModel();
      const block: Record<string, Object> = { 'block_id': 'b1', 'block_order': 0,
        'kind': 'text', 'state': 'open', 'text': 'abc' };
      applyEvent(model, 20, { 'type': 'block_opened', 'block': block });
      applyEvent(model, 21, { 'type': 'block_checkpoint', 'block_id': 'b1',
        'text': '完整覆盖' });

      const row: TranscriptRow | undefined = findRow(model.rowsRef(),
        TranscriptRowKind.TEXT);
      expect(row !== undefined).assertTrue();
      expect(row!.text).assertEqual('完整覆盖');
    });

    it('text_block_caps_tail_with_notice_when_overflow', 0, () => {
      // M13 防打爆：text_delta 无界累积是单条大消息打爆前端的根因——
      // 超过硬上限必须保尾 + 截断提示（正文服务端已摊平，没有 ref 可回拉）。
      const model: TranscriptModel = new TranscriptModel();
      const block: Record<string, Object> = { 'block_id': 'b1', 'block_order': 0,
        'kind': 'text', 'state': 'open', 'text': '头部' };
      applyEvent(model, 20, { 'type': 'block_opened', 'block': block });
      applyEvent(model, 21, { 'type': 'text_delta', 'block_id': 'b1',
        'fragment_seq': 1, 'delta': 'x'.repeat(200000) + '\n尾部内容' });

      const row: TranscriptRow | undefined = findRow(model.rowsRef(),
        TranscriptRowKind.TEXT);
      expect(row !== undefined).assertTrue();
      expect(row!.truncated).assertTrue();
      expect(row!.text.startsWith('……（前文过长已省略，完整正文见桌面端）')).assertTrue();
      expect(row!.text.endsWith('尾部内容')).assertTrue();
      // 截断后缓冲有界（< 200K 输入），且继续追加不炸、行数与全文扫描一致。
      const bounded: number = row!.text.length;
      expect(bounded < 200000).assertTrue();
      applyEvent(model, 22, { 'type': 'text_delta', 'block_id': 'b1',
        'fragment_seq': 2, 'delta': '！' });
      expect(row!.text.length).assertEqual(bounded + 1);
      expect(row!.lineCount).assertEqual(countLines(row!.text));
    });

    it('line_count_cache_matches_full_scan_after_deltas', 0, () => {
      // 行数缓存增量维护：appendText 只数增量换行，与全文扫描同口径。
      const model: TranscriptModel = new TranscriptModel();
      const block: Record<string, Object> = { 'block_id': 'b1', 'block_order': 0,
        'kind': 'text', 'state': 'open', 'text': '一行' };
      applyEvent(model, 20, { 'type': 'block_opened', 'block': block });
      applyEvent(model, 21, { 'type': 'text_delta', 'block_id': 'b1',
        'fragment_seq': 1, 'delta': '\n二行\n三行' });
      applyEvent(model, 22, { 'type': 'text_delta', 'block_id': 'b1',
        'fragment_seq': 2, 'delta': '续写' });
      applyEvent(model, 23, { 'type': 'block_checkpoint', 'block_id': 'b1',
        'text': '重置一行\n重置二行' });

      const row: TranscriptRow | undefined = findRow(model.rowsRef(),
        TranscriptRowKind.TEXT);
      expect(row !== undefined).assertTrue();
      expect(row!.lineCount).assertEqual(2);
      expect(row!.lineCount).assertEqual(countLines(row!.text));
    });

    it('tool_card_renders_target_body_and_terminal_tone', 0, () => {
      const model: TranscriptModel = new TranscriptModel();
      applyEvent(model, 30, blockOpenedEvent('round-0:tool:0', 'tool', 'open'));

      const running: Record<string, Object> = { 'tool_call_id': 'call_9', 'name': 'bash',
        'state': 'running', 'args_json': '{ "cmd": "make" }', 'output': '',
        'progress': 'out…' };
      applyEvent(model, 31, { 'type': 'tool_updated', 'block_id': 'round-0:tool:0',
        'tool': running });
      applyEvent(model, 32, { 'type': 'tool_progress', 'block_id': 'round-0:tool:0',
        'chunk': 'more', 'truncated': false });

      const failure: Record<string, Object> = { 'code': 'exit_1', 'message': 'non-zero' };
      // tool_updated 带的是整个 TimelineTool 快照（真 daemon 终态仍保留 args_json），
      // 所以模型整块替换而不是逐字段合并。
      const failed: Record<string, Object> = { 'tool_call_id': 'call_9', 'name': 'bash',
        'state': 'failed', 'args_json': '{ "cmd": "make" }', 'output': 'boom',
        'progress': '', 'failure': failure };
      applyEvent(model, 33, { 'type': 'tool_updated', 'block_id': 'round-0:tool:0',
        'tool': failed });

      const tool: TranscriptRow | undefined = findRow(model.rowsRef(),
        TranscriptRowKind.TOOL);
      expect(tool !== undefined).assertTrue();
      expect(tool!.toolName).assertEqual('bash');
      expect(tool!.target).assertEqual('make');
      expect(tool!.toolState).assertEqual('failed');
      expect(tool!.outputText).assertEqual('boom');
      expect(tool!.errorText).assertEqual('exit_1: non-zero');
      expect(toolStatusTone(tool!.toolState)).assertEqual('bad');
      expect(toolStatusTone('running')).assertEqual('running');
      expect(toolStatusTone('backgrounded')).assertEqual('other');
    });

    it('tool_body_washes_exec_envelope_and_escape_leftovers', 0, () => {
      const BS: string = '\\'; // 一个反斜杠，避免测试里多层转义看花眼
      const model: TranscriptModel = new TranscriptModel();
      applyEvent(model, 30, blockOpenedEvent('round-0:tool:0', 'tool', 'open'));

      // 真机 exec 回包：外层 JSON 信封，正文在 output 字段里又套一层转义。
      const envelope: string = '{"status":"completed","exit_code":0,"output":"Name  Length'
        + BS + 'r' + BS + 'n----  ------"}';
      const done: Record<string, Object> = { 'tool_call_id': 'call_9', 'name': 'exec',
        'state': 'completed', 'args_json': '{"path":"C:' + BS + BS + 'Users' + BS + BS + 'tsy3m"}',
        'output': envelope, 'progress': '' };
      applyEvent(model, 31, { 'type': 'tool_updated', 'block_id': 'round-0:tool:0',
        'tool': done });

      const tool: TranscriptRow | undefined = findRow(model.rowsRef(),
        TranscriptRowKind.TOOL);
      expect(tool !== undefined).assertTrue();
      // 信封剥掉 + 字面 \r\n 落成真实换行：卡片按行预览，不再满屏 \n。
      expect(tool!.outputText).assertEqual('Name  Length\n----  ------');
      expect(countLines(tool!.outputText)).assertEqual(2);
      // 转义反斜杠还原成单个（Windows 路径可读），且不再被当成换行前缀。
      expect(tool!.argsText).assertEqual('{"path":"C:' + BS + 'Users' + BS + 'tsy3m"}');
    });

    it('escaped_backslash_before_n_stays_literal', 0, () => {
      const BS: string = '\\';
      const model: TranscriptModel = new TranscriptModel();
      applyEvent(model, 30, blockOpenedEvent('round-0:tool:0', 'tool', 'open'));

      // 文本里是「转义过的反斜杠 + n」（如正则/日志字面量），不是换行指令。
      const raw: string = 'pattern A' + BS + BS + 'nB stays one line';
      const done: Record<string, Object> = { 'tool_call_id': 'call_9', 'name': 'grep',
        'state': 'completed', 'args_json': '', 'output': raw, 'progress': '' };
      applyEvent(model, 31, { 'type': 'tool_updated', 'block_id': 'round-0:tool:0',
        'tool': done });

      const tool: TranscriptRow | undefined = findRow(model.rowsRef(),
        TranscriptRowKind.TOOL);
      expect(tool!.outputText).assertEqual('pattern A' + BS + 'nB stays one line');
      expect(countLines(tool!.outputText)).assertEqual(1);
    });

    it('collapsed_tool_body_previews_three_lines', 0, () => {
      const model: TranscriptModel = new TranscriptModel();
      applyEvent(model, 1, { 'type': 'turn_opened', 'user_text': 'run' });
      applyEvent(model, 2, blockOpenedEvent('b1', 'tool', 'open'));
      applyEvent(model, 3, toolUpdatedEvent('b1', 'c1', 'bash', 'succeeded',
        '{"cmd":"tst"}', 'l1\nl2\nl3\nl4\nl5', ''));

      const tool: TranscriptRow | undefined = findRow(model.rowsRef(),
        TranscriptRowKind.TOOL);
      // 终态预览取头部 3 行（结局在开头），折叠行数如实报给「+N 行」徽标。
      expect(tool!.bodyText).assertEqual('l1\nl2\nl3');
      expect(tool!.hiddenLines).assertEqual(2);
      model.toggleExpanded(tool!.rowId);
      const expanded: TranscriptRow | undefined = findRow(model.rowsRef(),
        TranscriptRowKind.TOOL);
      expect(expanded!.bodyText).assertEqual('l1\nl2\nl3\nl4\nl5');
      expect(expanded!.hiddenLines).assertEqual(0);
    });

    it('progress_rolls_tail_and_buffer_stays_bounded', 0, () => {
      const model: TranscriptModel = new TranscriptModel();
      applyEvent(model, 1, { 'type': 'turn_opened', 'user_text': 'run' });
      applyEvent(model, 2, blockOpenedEvent('b1', 'tool', 'open'));
      applyEvent(model, 3, toolUpdatedEvent('b1', 'c1', 'pytest', 'running',
        '{"cmd":"t"}', '', 'test_a PASS'));
      applyEvent(model, 4, { 'type': 'tool_progress', 'block_id': 'b1',
        'chunk': ' / test_b PASS', 'truncated': false });

      let tool: TranscriptRow | undefined = findRow(model.rowsRef(),
        TranscriptRowKind.TOOL);
      expect(tool!.progressText).assertEqual('test_a PASS / test_b PASS');

      const chunk: string = `${'x'.repeat(100)}\n`;
      for (let i = 0; i < 120; i++) {
        applyEvent(model, 10 + i, { 'type': 'tool_progress', 'block_id': 'b1',
          'chunk': chunk, 'truncated': false });
      }
      tool = findRow(model.rowsRef(), TranscriptRowKind.TOOL);
      // 有界累积（TUI 纪律）：无界进度是内存税。
      expect(tool!.progressText.length <= 8192).assertTrue();
      // 滚动窗口取尾（进行态显示永远贴着最新输出）。
      expect(tailLines('a\nb\nc\nd\ne', 3)).assertEqual('c\nd\ne');
      expect(headLines('a\nb\nc\nd\ne', 2)).assertEqual('a\nb');
      expect(countLines('a\nb')).assertEqual(2);
    });

    it('thinking_streams_tail_window_then_seals_into_collapse', 0, () => {
      const model: TranscriptModel = new TranscriptModel();
      applyEvent(model, 1, { 'type': 'turn_opened', 'user_text': 'think' });
      applyEvent(model, 2, blockOpenedEvent('r1', 'reasoning', 'open'));
      applyEvent(model, 3, { 'type': 'text_delta', 'block_id': 'r1',
        'fragment_seq': 1, 'delta': 'l1\nl2\nl3\nl4\nl5' });

      const live: TranscriptRow | undefined = findRow(model.rowsRef(),
        TranscriptRowKind.THINKING);
      expect(live !== undefined).assertTrue();
      expect(live!.sealed).assertFalse();
      // 默认折叠成 3 行滚动窗口（渲染侧取尾三行）。
      expect(tailLines(live!.text, 3)).assertEqual('l3\nl4\nl5');

      applyEvent(model, 4, { 'type': 'block_sealed', 'block_id': 'r1' });
      const sealed: TranscriptRow | undefined = findRow(model.rowsRef(),
        TranscriptRowKind.THINKING);
      expect(sealed!.sealed).assertTrue();
      expect(sealed!.lineCount).assertEqual(5);
    });

    it('empty_sealed_reasoning_is_dropped_from_history', 0, () => {
      const model: TranscriptModel = new TranscriptModel();
      applyEvent(model, 1, { 'type': 'turn_opened', 'user_text': 'x' });
      applyEvent(model, 2, blockOpenedEvent('r0', 'reasoning', 'open'));
      expect(countRowsOfKind(model.rowsRef(), TranscriptRowKind.THINKING)).assertEqual(1);

      applyEvent(model, 3, { 'type': 'block_sealed', 'block_id': 'r0' });
      expect(countRowsOfKind(model.rowsRef(), TranscriptRowKind.THINKING)).assertEqual(0);
    });

    it('lookup_group_merges_consecutive_reads_and_expands_apart', 0, () => {
      const model: TranscriptModel = new TranscriptModel();
      applyEvent(model, 1, { 'type': 'turn_opened', 'user_text': 'explore' });
      for (let i = 0; i < 3; i++) {
        const blockId: string = `t${i}`;
        applyEvent(model, 10 + i, blockOpenedEvent(blockId, 'tool', 'open'));
        applyEvent(model, 20 + i, toolUpdatedEvent(blockId, `c${i}`, 'read',
          'succeeded', '{"path":"f"}', 'ok', ''));
      }

      const rows: TranscriptRow[] = model.rowsRef();
      expect(countRowsOfKind(rows, TranscriptRowKind.TOOL_GROUP)).assertEqual(1);
      expect(countRowsOfKind(rows, TranscriptRowKind.TOOL)).assertEqual(0);
      const group: TranscriptRow | undefined = findRow(rows, TranscriptRowKind.TOOL_GROUP);
      expect(group!.members.length).assertEqual(3);
      expect(group!.groupVerb).assertEqual('读取');
      expect(group!.groupNoun).assertEqual('个文件');
      expect(lookupGroupNoun('grep')).assertEqual('次搜索');

      // 展开即拆组：成员各自成卡（折叠态）。
      model.toggleExpanded(group!.rowId);
      const after: TranscriptRow[] = model.rowsRef();
      expect(countRowsOfKind(after, TranscriptRowKind.TOOL_GROUP)).assertEqual(0);
      expect(countRowsOfKind(after, TranscriptRowKind.TOOL)).assertEqual(3);
    });

    it('failed_tool_breaks_lookup_grouping', 0, () => {
      const model: TranscriptModel = new TranscriptModel();
      applyEvent(model, 1, { 'type': 'turn_opened', 'user_text': 'explore' });
      applyEvent(model, 2, blockOpenedEvent('a', 'tool', 'open'));
      applyEvent(model, 3, toolUpdatedEvent('a', 'c1', 'read', 'succeeded',
        '{"path":"f1"}', 'ok', ''));
      applyEvent(model, 4, blockOpenedEvent('b', 'tool', 'open'));
      applyEvent(model, 5, toolUpdatedEvent('b', 'c2', 'read', 'failed',
        '{"path":"f2"}', '', ''));

      const rows: TranscriptRow[] = model.rowsRef();
      expect(countRowsOfKind(rows, TranscriptRowKind.TOOL_GROUP)).assertEqual(0);
      expect(countRowsOfKind(rows, TranscriptRowKind.TOOL)).assertEqual(2);
    });

    it('todo_write_renders_checklist_and_feeds_panel', 0, () => {
      const model: TranscriptModel = new TranscriptModel();
      const items: Record<string, Object>[] = [
        { 'id': '1', 'title': '做A', 'status': 'pending' },
        { 'id': '2', 'title': '做B', 'status': 'in_progress' }
      ];
      const writeArgs: Record<string, Object> = { 'items': items };
      applyEvent(model, 1, { 'type': 'turn_opened', 'user_text': 'plan' });
      applyEvent(model, 2, blockOpenedEvent('td1', 'tool', 'open'));
      applyEvent(model, 3, toolUpdatedEvent('td1', 'c1', 'todo_write', 'succeeded',
        JSON.stringify(writeArgs), '', ''));

      const todo: TranscriptRow | undefined = findRow(model.rowsRef(),
        TranscriptRowKind.TODO);
      expect(todo !== undefined).assertTrue();
      expect(todo!.todoItems.length).assertEqual(2);
      expect(model.todoPanelItems().length).assertEqual(2);

      // todo_update 是一次一条的 delta（后端 split.rs 拒绝批量形态）。
      const delta: Record<string, Object> = { 'id': '1', 'status': 'completed' };
      applyEvent(model, 4, blockOpenedEvent('td2', 'tool', 'open'));
      applyEvent(model, 5, toolUpdatedEvent('td2', 'c2', 'todo_update', 'succeeded',
        JSON.stringify(delta), '', ''));
      let firstStatus: string = '';
      for (const item of model.todoPanelItems()) {
        if (item.id === '1') {
          firstStatus = item.status;
        }
      }
      expect(firstStatus).assertEqual(TodoItemStatus.COMPLETED);
      // update 入参没有 items 清单形态 → 走普通工具卡回退（TUI 语义）。
      expect(countRowsOfKind(model.rowsRef(), TranscriptRowKind.TOOL)).assertEqual(1);
    });

    it('last_todo_card_tracks_live_panel', 0, () => {
      const model: TranscriptModel = new TranscriptModel();
      const items: Record<string, Object>[] = [
        { 'id': '1', 'title': '写清单', 'status': 'in_progress' },
        { 'id': '2', 'title': '读文件', 'status': 'pending' }
      ];
      const writeArgs: Record<string, Object> = { 'items': items };
      applyEvent(model, 1, { 'type': 'turn_opened', 'user_text': 'plan' });
      applyEvent(model, 2, blockOpenedEvent('td1', 'tool', 'open'));
      applyEvent(model, 3, toolUpdatedEvent('td1', 'c1', 'todo_write', 'succeeded',
        JSON.stringify(writeArgs), '', ''));
      let card: TranscriptRow | undefined = findRow(model.rowsRef(),
        TranscriptRowKind.TODO);
      expect(card!.todoItems[0].status).assertEqual('in_progress');

      // 计划不再占侧栏：最后一条 todo 卡 = 面板实时态，update 就地折进卡里。
      const delta: Record<string, Object> = { 'id': '1', 'status': 'completed' };
      applyEvent(model, 4, blockOpenedEvent('td2', 'tool', 'open'));
      applyEvent(model, 5, toolUpdatedEvent('td2', 'c2', 'todo_update', 'succeeded',
        JSON.stringify(delta), '', ''));
      card = findRow(model.rowsRef(), TranscriptRowKind.TODO);
      expect(card!.todoItems[0].status).assertEqual(TodoItemStatus.COMPLETED);
      let live: TranscriptRow | undefined;
      for (const row of model.rowsRef()) {
        if (row.kind === TranscriptRowKind.TODO) {
          live = row;
        }
      }
      expect(live !== undefined).assertTrue();
    });

    it('parse_todo_items_rejects_partial_shapes', 0, () => {
      expect(parseTodoItems('{"items":[{"title":"a","status":"pending"}]}') !== undefined)
        .assertTrue();
      // 缺 title 的条目让整次解析作废：半个计划比没有计划更误导人。
      expect(parseTodoItems('{"items":[{"status":"pending"}]}') === undefined).assertTrue();
      expect(parseTodoItems('{"todos":[]}') === undefined).assertTrue();
      expect(parseTodoItems('not json') === undefined).assertTrue();
    });

    it('unknown_entry_type_is_flagged_not_fatal', 0, () => {
      const model: TranscriptModel = new TranscriptModel();
      model.seed(parseSnapshot().turns);
      applyEvent(model, 40, { 'type': 'turn_opened', 'user_text': 'x' });
      applyEvent(model, 41, { 'type': 'quantum_updated', 'block_id': 'b1' });

      expect(model.unrecognizedEventValue()).assertEqual('quantum_updated');
      expect(model.turnActiveValue()).assertTrue();
      // tool_estimated 是渲染旁路，不该算漂移。
      applyEvent(model, 42, { 'type': 'tool_estimated', 'block_id': 'b1',
        'lines_added': 3, 'lines_removed': 0 });
      expect(model.unrecognizedEventValue()).assertEqual('quantum_updated');
    });

    it('prepend_older_keeps_row_instances_stable', 0, () => {
      const model: TranscriptModel = new TranscriptModel();
      model.seed(parseSnapshot().turns);
      const marker: TranscriptRow | undefined = lastRowOfKind(model.rowsRef(),
        TranscriptRowKind.MARKER);
      expect(marker !== undefined).assertTrue();

      const older: Record<string, Object> = { 'turn_id': 't0', 'created_seq': 1,
        'user_text': '更早的问题', 'sealed': true, 'state': 'completed', 'rounds': [] };
      const raw: Object[] = [older];
      model.prependOlder(raw.map((entry: Object): TimelineTurn =>
        new TimelineTurn(entry as object)));

      const rows: TranscriptRow[] = model.rowsRef();
      expect(rows[0].kind).assertEqual(TranscriptRowKind.USER);
      expect(rows[0].text).assertEqual('更早的问题');
      // 行实例跨重建复用（LazyForEach 键稳定、视图不闪的前提）。
      expect(lastRowOfKind(rows, TranscriptRowKind.MARKER) === marker).assertTrue();
    });
  });
}
