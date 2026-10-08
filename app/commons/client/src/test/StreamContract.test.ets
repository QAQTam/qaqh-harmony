/**
 * M2 流式订阅契约测试：EventStream（SSE 解码/cursor/退避重连/reset）与
 * SessionMonitor（bootstrap 订阅/401 重新协商/reset 重建/cursor 持久化）。
 * 传输与定时器全部假件；wire 夹具与 axum_impl/v2.rs handle_events_v2 对拍。
 */

import { describe, it, expect } from '@ohos/hypium';

import { CanonicalCursor, ContentValueInline, CursorToken, encodeUtf8, ProjectionPayload,
  ProtocolError, RingingV2Bootstrap, RingingV2EventEnvelope, RingingV2ResetRequired,
  RingingV2StreamTerminated, TimelineInput } from '@qaqh/protocol';
import { EventStream, EventStreamListener, StreamState } from '../main/ets/EventStream';
import { SessionMonitor, SessionMonitorListener, MonitorStatus, CursorStore }
  from '../main/ets/SessionMonitor';
import { RingingClient, RingingClientConfig }
  from '../main/ets/RingingClient';
import { StreamConnection, StreamEndpoint, StreamListener, StreamRequest }
  from '../main/ets/transport/StreamConnection';
import { LeaseTimer, Transport, TransportRequest, TransportResponse, TransportError }
  from '../main/ets/transport/Transport';

const OPEN_OK: string = '{"schema":"qaqh.Ringing","version":2,"accepted":true,' +
  '"client_session_id":"cs-1","server_epoch":"epoch-1","lease_ttl_ms":30000,' +
  '"renew_interval_ms":10000,"capabilities":{"subscribe":true,"interact":true,' +
  '"drive":true,"timeline":true,"service":true,"content":true,"single_stream":true}}';

function bootstrapFixture(): string {
  const token: string =
    CursorToken.encodeSnapshot(CanonicalCursor.snapshot('log-1', 42)).asString();
  return '{"schema":"qaqh.Ringing","version":2,"server_epoch":"epoch-1",' +
    '"session_id":"seed-1","snapshot_cursor":"' + token + '",' +
    '"control":{"channel":"control","state_revision":7,"snapshot_version":1,' +
    '"state":{"session_id":"seed-1","revision":7,"last_fact_seq":42,' +
    '"interactions":[],"driver":{"holder":null,"driver_epoch":3,"can_claim":true}}},' +
    '"conversation":{"channel":"conversation","state_revision":19,"snapshot_version":1,' +
    '"state":{"revision":19,"messages":[]}},' +
    '"tool":{"channel":"tool","state_revision":11,"snapshot_version":1,' +
    '"state":{"tools":[]}}}';
}

function reliableEnvelopeFrame(eventId: string, factSeq: number): string {
  const cursor: string =
    CursorToken.encodeReliable(new CanonicalCursor('log-1', factSeq, 1)).asString();
  const data: string = '{"schema":"qaqh.Ringing","version":2,"server_epoch":"epoch-1",' +
    '"session_id":"seed-1","event_id":"' + eventId + '",' +
    '"stream_key":{"kind":"channel","data":"control"},' +
    '"delivery":"reliable","cursor":"' + cursor + '","log_id":"log-1","fact_seq":' +
    factSeq + ',"projection_index":1,"revision":7,' +
    '"payload":{"kind":"timeline_delta","data":{"kind":"input","data":' +
    '{"revision":9,"input_id":"in-1","content":{"kind":"inline","data":{"text":"你好"}}}}}}';
  return 'id: v2:epoch-1:' + eventId + '\nevent: ringing.event\ndata: ' + data + '\n\n';
}

function resetFrame(): string {
  const token: string =
    CursorToken.encodeSnapshot(CanonicalCursor.snapshot('log-1', 42)).asString();
  const data: string = '{"schema":"qaqh.Ringing","version":2,"server_epoch":"epoch-1",' +
    '"session_id":"seed-1","log_id":"log-1","snapshot_cursor":"' + token + '",' +
    '"reason":"cursor_expired"}';
  return 'event: ringing.reset_required\ndata: ' + data + '\n\n';
}

/** 夹具与后端 v2.rs:596-604 逐字段对齐（裸 json!，无 schema/version）。 */
function streamTerminatedFrame(): string {
  const data: string = '{"code":"revoked","session_id":"seed-1",' +
    '"message":"client lease revoked or expired; reconnect after re-auth"}';
  return 'event: ringing.stream_terminated\ndata: ' + data + '\n\n';
}

class ScriptedReply {
  readonly failed: boolean;
  readonly status: number;
  readonly body: string;

  constructor(failed: boolean, status: number, body: string) {
    this.failed = failed;
    this.status = status;
    this.body = body;
  }
}

class FakeTransport implements Transport {
  readonly requests: TransportRequest[] = [];
  readonly script: ScriptedReply[] = [];

  enqueue(status: number, body: string): FakeTransport {
    this.script.push(new ScriptedReply(false, status, body));
    return this;
  }

  enqueueNetworkError(): FakeTransport {
    this.script.push(new ScriptedReply(true, -1, ''));
    return this;
  }

  send(request: TransportRequest): Promise<TransportResponse> {
    this.requests.push(request);
    const next: ScriptedReply | undefined = this.script.shift();
    if (next === undefined) {
      return Promise.reject(new TransportError('script_empty', -1, 'no scripted reply'));
    }
    if (next.failed) {
      return Promise.reject(new TransportError('network_error', -1, 'injected failure'));
    }
    return Promise.resolve(new TransportResponse(next.status, next.body));
  }

  lastRequest(): TransportRequest {
    return this.requests[this.requests.length - 1];
  }

  count(): number {
    return this.requests.length;
  }
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

/** 脚本化流连接：测试手动推字节 / 断流 / 失败。 */
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

  emitFailed(): void {
    if (this.listener !== undefined) {
      this.listener.onFailed('network_error', 'injected');
    }
  }

  lastUrl(): string {
    return this.requests[this.requests.length - 1].url;
  }

  connectCount(): number {
    return this.requests.length;
  }
}

class MemoryCursorStore implements CursorStore {
  token: CursorToken | undefined = undefined;
  cleared: boolean = false;

  load(): CursorToken | undefined {
    return this.token;
  }

  save(token: CursorToken): void {
    this.token = token;
  }

  clear(): void {
    this.cleared = true;
    this.token = undefined;
  }
}

class RecordingStreamListener implements EventStreamListener {
  envelopes: number = 0;
  lastEnvelopeId: string = '';
  resets: string[] = [];
  states: string[] = [];
  httpDisconnects: number[] = [];
  protocolErrors: string[] = [];
  terminations: string[] = [];
  leaseUnavailables: number = 0;

  onEnvelope(envelope: RingingV2EventEnvelope): void {
    this.envelopes++;
    this.lastEnvelopeId = envelope.eventId;
  }

  onResetRequired(reset: RingingV2ResetRequired): void {
    this.resets.push(reset.reason);
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
    this.terminations.push(`${terminated.code}/${terminated.sessionId}`);
  }

  onLeaseUnavailable(): void {
    this.leaseUnavailables++;
  }
}

function makeStream(connection: FakeStreamConnection, timer: FakeTimer,
  listener: RecordingStreamListener): EventStream {
  return new EventStream('seed-1', connection, timer, (): StreamEndpoint => {
    let headers: Record<string, string> = {
      'Authorization': 'Bearer tok-1',
      'Content-Type': 'application/json',
      'X-QAQH-Client-Session-Id': 'cs-1',
      'Accept': 'text/event-stream'
    };
    return new StreamEndpoint('http://daemon.test', headers);
  }, listener);
}

/**
 * 真机闪退形态：租约一失效（client 出 open 态），组装流端点就抛 invalid_state。
 * 关 gate 复现「定时器到点时租约已经没了」。
 */
class LeaseGate {
  open: boolean = true;
}

function makeGatedStream(connection: FakeStreamConnection, timer: FakeTimer,
  listener: RecordingStreamListener, gate: LeaseGate): EventStream {
  return new EventStream('seed-1', connection, timer, (): StreamEndpoint => {
    if (!gate.open) {
      throw new ProtocolError('invalid_state', 'requires open state, got closed');
    }
    let headers: Record<string, string> = {
      'Authorization': 'Bearer tok-1',
      'X-QAQH-Client-Session-Id': 'cs-1'
    };
    return new StreamEndpoint('http://daemon.test', headers);
  }, listener);
}

async function settle(): Promise<void> {
  for (let i = 0; i < 10; i++) {
    await Promise.resolve();
  }
}

class RecordingMonitorListener implements SessionMonitorListener {
  bootstraps: number = 0;
  envelopes: number = 0;
  inputTexts: string[] = [];
  resets: string[] = [];
  statuses: string[] = [];
  protocolErrors: string[] = [];

  onBootstrap(snapshot: RingingV2Bootstrap): void {
    this.bootstraps++;
  }

  onEnvelope(envelope: RingingV2EventEnvelope, payload: ProjectionPayload): void {
    this.envelopes++;
    if (payload.timeline !== undefined &&
      payload.timeline.kind() === 'input') {
      const input = payload.timeline as TimelineInput;
      this.inputTexts.push((input.content as ContentValueInline).text);
    }
  }

  onResetRequired(reset: RingingV2ResetRequired): void {
    this.resets.push(reset.reason);
  }

  onStatusChanged(status: string): void {
    this.statuses.push(status);
  }

  onProtocolError(error: ProtocolError): void {
    this.protocolErrors.push(error.code);
  }
}

function makeMonitor(transport: FakeTransport, streamTimer: FakeTimer,
  connection: FakeStreamConnection, listener: RecordingMonitorListener,
  store?: MemoryCursorStore): SessionMonitor {
  const client: RingingClient = new RingingClient(new RingingClientConfig(
    'http://daemon.test', 'tok-1', 'instance-1', transport, streamTimer));
  return new SessionMonitor(client, connection, streamTimer, listener, store);
}

export default function streamContractTest() {
  describe('event_stream_contract', () => {
    it('streams_envelopes_and_tracks_cursor', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const timer: FakeTimer = new FakeTimer();
      const listener: RecordingStreamListener = new RecordingStreamListener();
      const stream: EventStream = makeStream(connection, timer, listener);

      stream.start(undefined);

      expect(connection.connectCount()).assertEqual(1);
      expect(connection.lastUrl())
        .assertEqual('http://daemon.test/ringing/v2/sessions/seed-1/events');
      expect(connection.requests[0].headers['Accept']).assertEqual('text/event-stream');
      expect(connection.requests[0].headers['X-QAQH-Client-Session-Id'])
        .assertEqual('cs-1');

      connection.emit(reliableEnvelopeFrame('event-1', 42));

      expect(listener.envelopes).assertEqual(1);
      expect(listener.lastEnvelopeId).assertEqual('event-1');
      expect(stream.stateValue()).assertEqual(StreamState.CONNECTED);
      expect(stream.lastCursorValue()!.decodeReliable().factSeq).assertEqual(42);
    });

    it('resumes_with_since_cursor_after_clean_eof', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const timer: FakeTimer = new FakeTimer();
      const listener: RecordingStreamListener = new RecordingStreamListener();
      const stream: EventStream = makeStream(connection, timer, listener);
      stream.start(undefined);
      connection.emit(reliableEnvelopeFrame('event-1', 42));

      connection.emitEnded(200);

      expect(stream.stateValue()).assertEqual(StreamState.RECONNECTING);
      expect(timer.lastIntervalMs).assertEqual(1000);
      timer.fire();
      expect(connection.connectCount()).assertEqual(2);
      expect(connection.lastUrl().includes('?since_cursor=v2.')).assertTrue();
    });

    it('backoff_escalates_and_resets_on_traffic', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const timer: FakeTimer = new FakeTimer();
      const listener: RecordingStreamListener = new RecordingStreamListener();
      const stream: EventStream = makeStream(connection, timer, listener);
      stream.start(undefined);

      connection.emitEnded(200);
      expect(timer.lastIntervalMs).assertEqual(1000);
      timer.fire();
      connection.emitFailed();
      expect(timer.lastIntervalMs).assertEqual(2000);
      timer.fire();

      connection.emit(reliableEnvelopeFrame('event-1', 42));
      connection.emitEnded(200);
      expect(timer.lastIntervalMs).assertEqual(1000);
      expect(stream.stateValue()).assertEqual(StreamState.RECONNECTING);
    });

    it('closed_lease_on_retry_fire_does_not_escape', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const timer: FakeTimer = new FakeTimer();
      const listener: RecordingStreamListener = new RecordingStreamListener();
      const gate: LeaseGate = new LeaseGate();
      const stream: EventStream = makeGatedStream(connection, timer, listener, gate);
      stream.start(undefined);

      // 断流 → 1s 退避重连已武装；随后租约失效（client 出 open）。
      connection.emitEnded(200);
      gate.open = false;
      // 定时器到点：旧实现在这里把异常抛过 setTimeout 边界 → napi 判未捕获
      // 错误 → 框架杀进程（真机 JS_ERROR 闪退）。
      timer.fire();

      expect(listener.leaseUnavailables).assertEqual(1);
      expect(stream.stateValue()).assertEqual(StreamState.STOPPED);
      expect(timer.stopped).assertTrue();
      expect(connection.connectCount()).assertEqual(1);
    });

    it('stops_on_http_disconnect', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const timer: FakeTimer = new FakeTimer();
      const listener: RecordingStreamListener = new RecordingStreamListener();
      const stream: EventStream = makeStream(connection, timer, listener);
      stream.start(undefined);

      connection.emitEnded(401);

      expect(stream.stateValue()).assertEqual(StreamState.STOPPED);
      expect(listener.httpDisconnects.length).assertEqual(1);
      expect(listener.httpDisconnects[0]).assertEqual(401);
      expect(timer.stopped).assertTrue();
    });

    it('reset_required_stops_stream_and_reports', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const timer: FakeTimer = new FakeTimer();
      const listener: RecordingStreamListener = new RecordingStreamListener();
      const stream: EventStream = makeStream(connection, timer, listener);
      stream.start(undefined);

      connection.emit(resetFrame());

      expect(listener.resets.length).assertEqual(1);
      expect(listener.resets[0]).assertEqual('cursor_expired');
      expect(stream.stateValue()).assertEqual(StreamState.STOPPED);
      expect(timer.stopped).assertTrue();
    });

    it('stream_terminated_stops_stream_and_reports', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const timer: FakeTimer = new FakeTimer();
      const listener: RecordingStreamListener = new RecordingStreamListener();
      const stream: EventStream = makeStream(connection, timer, listener);
      stream.start(undefined);

      connection.emit(streamTerminatedFrame());

      expect(listener.terminations.length).assertEqual(1);
      expect(listener.terminations[0]).assertEqual('revoked/seed-1');
      expect(listener.protocolErrors.length).assertEqual(0);
      expect(stream.stateValue()).assertEqual(StreamState.STOPPED);
      expect(timer.stopped).assertTrue();
      // 服务端随后断流：本端已 stopped，不再排重连（撤销后不空转）。
      connection.emitEnded(200);
      expect(connection.connectCount()).assertEqual(1);
    });

    it('bad_frame_fails_loudly', 0, () => {
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const timer: FakeTimer = new FakeTimer();
      const listener: RecordingStreamListener = new RecordingStreamListener();
      const stream: EventStream = makeStream(connection, timer, listener);
      stream.start(undefined);

      connection.emit('event: ringing.event\ndata: {"kind":"mystery"}\n\n');

      expect(listener.protocolErrors.length).assertEqual(1);
      expect(stream.stateValue()).assertEqual(StreamState.STOPPED);
    });
  });

  describe('session_monitor_contract', () => {
    it('bootstraps_and_subscribes_from_snapshot_cursor', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, bootstrapFixture());
      const timer: FakeTimer = new FakeTimer();
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingMonitorListener = new RecordingMonitorListener();
      const monitor: SessionMonitor = makeMonitor(transport, timer, connection, listener);

      await monitor.start('seed-1');

      expect(listener.bootstraps).assertEqual(1);
      expect(monitor.statusValue()).assertEqual(MonitorStatus.LIVE);
      const snapshotToken: string =
        CursorToken.encodeSnapshot(CanonicalCursor.snapshot('log-1', 42)).asString();
      expect(connection.lastUrl())
        .assertEqual('http://daemon.test/ringing/v2/sessions/seed-1/events?since_cursor='
          + snapshotToken);
    });

    it('reuses_persisted_cursor_with_matching_log', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, bootstrapFixture());
      const timer: FakeTimer = new FakeTimer();
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingMonitorListener = new RecordingMonitorListener();
      const store: MemoryCursorStore = new MemoryCursorStore();
      store.save(CursorToken.encodeSnapshot(CanonicalCursor.snapshot('log-1', 40)));
      const monitor: SessionMonitor =
        makeMonitor(transport, timer, connection, listener, store);

      await monitor.start('seed-1');

      const savedToken: string =
        CursorToken.encodeSnapshot(CanonicalCursor.snapshot('log-1', 40)).asString();
      expect(connection.lastUrl().endsWith('?since_cursor=' + savedToken)).assertTrue();
    });

    it('falls_back_to_snapshot_on_log_mismatch', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, bootstrapFixture());
      const timer: FakeTimer = new FakeTimer();
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingMonitorListener = new RecordingMonitorListener();
      const store: MemoryCursorStore = new MemoryCursorStore();
      store.save(CursorToken.encodeSnapshot(CanonicalCursor.snapshot('log-OLD', 40)));
      const monitor: SessionMonitor =
        makeMonitor(transport, timer, connection, listener, store);

      await monitor.start('seed-1');

      const snapshotToken: string =
        CursorToken.encodeSnapshot(CanonicalCursor.snapshot('log-1', 42)).asString();
      expect(connection.lastUrl().endsWith('?since_cursor=' + snapshotToken)).assertTrue();
    });

    it('persists_cursor_and_decodes_envelope_payload', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, bootstrapFixture());
      const timer: FakeTimer = new FakeTimer();
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingMonitorListener = new RecordingMonitorListener();
      const store: MemoryCursorStore = new MemoryCursorStore();
      const monitor: SessionMonitor =
        makeMonitor(transport, timer, connection, listener, store);

      await monitor.start('seed-1');
      connection.emit(reliableEnvelopeFrame('event-1', 43));

      expect(listener.envelopes).assertEqual(1);
      expect(listener.inputTexts.length).assertEqual(1);
      expect(listener.inputTexts[0]).assertEqual('你好');
      expect(store.token!.decodeReliable().factSeq).assertEqual(43);
    });

    it('renegotiates_on_401_disconnect', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, bootstrapFixture())
          .enqueue(200, OPEN_OK).enqueue(200, bootstrapFixture());
      const timer: FakeTimer = new FakeTimer();
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingMonitorListener = new RecordingMonitorListener();
      const monitor: SessionMonitor = makeMonitor(transport, timer, connection, listener);
      await monitor.start('seed-1');

      connection.emitEnded(401);
      await settle();

      expect(listener.statuses.includes(MonitorStatus.RENEGOTIATING)).assertTrue();
      expect(transport.count()).assertEqual(4);
      expect(transport.lastRequest().url)
        .assertEqual('http://daemon.test/ringing/v2/sessions/seed-1/bootstrap');
      expect(monitor.statusValue()).assertEqual(MonitorStatus.LIVE);
      expect(connection.connectCount()).assertEqual(2);
    });

    it('lease_loss_while_retry_armed_leaves_no_orphan_timer', 0, async () => {
      // 生产接线是两个 timer 槽（client 续期 / 流重连+看门狗，见 AppModel），
      // 假件必须照搬：共槽会互相顶掉排程，把闪退窗口测没。
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, bootstrapFixture())
          .enqueueNetworkError().enqueueNetworkError().enqueueNetworkError()
          .enqueue(200, OPEN_OK).enqueue(200, bootstrapFixture());
      const renewTimer: FakeTimer = new FakeTimer();
      const streamTimer: FakeTimer = new FakeTimer();
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingMonitorListener = new RecordingMonitorListener();
      const client: RingingClient = new RingingClient(new RingingClientConfig(
        'http://daemon.test', 'tok-1', 'instance-1', transport, renewTimer));
      const monitor: SessionMonitor = new SessionMonitor(client, connection,
        streamTimer, listener);
      await monitor.start('seed-1');

      connection.emitFailed();
      const staleRetry: (() => void) | undefined = streamTimer.lastFire;
      expect(staleRetry !== undefined).assertTrue();

      // 注入三次瞬时续期失败 → leaseLost → CLOSED + 重新协商（判死阈值 3）。
      renewTimer.fire();
      await settle();
      renewTimer.fire();
      await settle();
      renewTimer.fire();
      await settle();

      expect(transport.lastRequest().url)
        .assertEqual('http://daemon.test/ringing/v2/sessions/seed-1/bootstrap');
      expect(monitor.statusValue()).assertEqual(MonitorStatus.LIVE);
      expect(connection.connectCount()).assertEqual(2);
      expect(streamTimer.lastIntervalMs).assertEqual(15000);

      // 漏网的陈旧回调只许沉默：不得外抛，也不得留下第二条流。
      staleRetry!();
      expect(connection.connectCount()).assertEqual(2);
      expect(monitor.statusValue()).assertEqual(MonitorStatus.LIVE);
    });

    it('renegotiates_on_stream_terminated', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, bootstrapFixture())
          .enqueue(200, OPEN_OK).enqueue(200, bootstrapFixture());
      const timer: FakeTimer = new FakeTimer();
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingMonitorListener = new RecordingMonitorListener();
      const monitor: SessionMonitor = makeMonitor(transport, timer, connection, listener);
      await monitor.start('seed-1');

      connection.emit(streamTerminatedFrame());
      await settle();

      // 租约撤销不是坏帧：重新 open + bootstrap 并重新订阅。
      expect(listener.protocolErrors.length).assertEqual(0);
      expect(transport.count()).assertEqual(4);
      expect(transport.requests[2].url).assertEqual('http://daemon.test/ringing/v2/clients/open');
      expect(monitor.statusValue()).assertEqual(MonitorStatus.LIVE);
      expect(connection.connectCount()).assertEqual(2);
    });

    it('rebootstraps_on_reset_required', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, bootstrapFixture())
          .enqueue(200, bootstrapFixture());
      const timer: FakeTimer = new FakeTimer();
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingMonitorListener = new RecordingMonitorListener();
      const monitor: SessionMonitor = makeMonitor(transport, timer, connection, listener);
      await monitor.start('seed-1');

      connection.emit(resetFrame());
      await settle();

      expect(listener.resets.length).assertEqual(1);
      expect(transport.count()).assertEqual(3);
      expect(monitor.statusValue()).assertEqual(MonitorStatus.LIVE);
      expect(connection.connectCount()).assertEqual(2);
    });

const SESSION_LIST: string = '[{"session_id":"seed-1","updated_at":100},' +
  '{"session_id":"seed-2","updated_at":50,"running":true}]';

const SESSION_LIST_WITH_ARCHIVE: string = '[{"session_id":"seed-1","updated_at":100},' +
  '{"session_id":"arch-1","updated_at":999,"running":true,"archived":true},' +
  '{"session_id":"sub-1","updated_at":998,"ephemeral":true}]';

    it('auto_discovers_running_session', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, SESSION_LIST)
          .enqueue(200, bootstrapFixture());
      const streamTimer: FakeTimer = new FakeTimer();
      const discoveryTimer: FakeTimer = new FakeTimer();
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingMonitorListener = new RecordingMonitorListener();
      const client: RingingClient = new RingingClient(new RingingClientConfig(
        'http://daemon.test', 'tok-1', 'instance-1', transport, streamTimer));
      const monitor: SessionMonitor = new SessionMonitor(client, connection,
        streamTimer, listener, undefined, discoveryTimer);

      await monitor.start();

      // wire:POST /service/session.list,空 body,session header。
      const listRequest: TransportRequest = transport.requests[1];
      expect(listRequest.url)
        .assertEqual('http://daemon.test/ringing/v2/service/session.list');
      expect(listRequest.body).assertEqual('{}');
      expect(listRequest.headers['X-QAQH-Client-Session-Id']).assertEqual('cs-1');
      // 选中 running 会话并订阅其事件流。
      expect(monitor.sessionIdValue()).assertEqual('seed-2');
      expect(connection.lastUrl()
        .includes('/sessions/seed-2/events?since_cursor=')).assertTrue();
      expect(monitor.statusValue()).assertEqual(MonitorStatus.LIVE);
      // 轮询节拍 15s。
      expect(discoveryTimer.lastIntervalMs).assertEqual(15000);
    });

    it('auto_discovery_skips_archived_and_ephemeral', 0, async () => {
      // 后端 set_archived 会把 updated_at 刷成当下：归档那条既在跑又最新，
      // 但手机不能去监视一个用户已经收进归档组的会话。
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, SESSION_LIST_WITH_ARCHIVE)
          .enqueue(200, bootstrapFixture());
      const streamTimer: FakeTimer = new FakeTimer();
      const discoveryTimer: FakeTimer = new FakeTimer();
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingMonitorListener = new RecordingMonitorListener();
      const client: RingingClient = new RingingClient(new RingingClientConfig(
        'http://daemon.test', 'tok-1', 'instance-1', transport, streamTimer));
      const monitor: SessionMonitor = new SessionMonitor(client, connection,
        streamTimer, listener, undefined, discoveryTimer);

      await monitor.start();

      expect(monitor.sessionIdValue()).assertEqual('seed-1');
      expect(connection.lastUrl()
        .includes('/sessions/seed-1/events?since_cursor=')).assertTrue();
      expect(monitor.statusValue()).assertEqual(MonitorStatus.LIVE);
    });

    it('stop_clears_store_and_disconnects', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, bootstrapFixture());
      const timer: FakeTimer = new FakeTimer();
      const connection: FakeStreamConnection = new FakeStreamConnection();
      const listener: RecordingMonitorListener = new RecordingMonitorListener();
      const store: MemoryCursorStore = new MemoryCursorStore();
      const monitor: SessionMonitor =
        makeMonitor(transport, timer, connection, listener, store);
      await monitor.start('seed-1');

      monitor.stop();

      expect(monitor.statusValue()).assertEqual(MonitorStatus.STOPPED);
      expect(store.cleared).assertTrue();
      expect(transport.lastRequest().url.includes('/bootstrap')).assertTrue();
    });
  });
}
