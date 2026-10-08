/**
 * 单流 SSE 事件订阅（M2）。
 *
 * wire 形态（axum_impl/v2.rs handle_events_v2，与 qaqh-client subscribe_v2 对拍）：
 * - `event: ringing.event` + `id: v2:{epoch}:{event_id}` + data = 事件信封 JSON；
 * - `event: ringing.reset_required`（单次，随后服务端断流）；
 * - `event: ringing.stream_terminated`（租约撤销/过期，单帧后服务端断流）；
 * - `?since_cursor=` 续传；keepalive 注释帧由 SseDecoder 吞掉。
 *
 * 重连策略：网络失败 / 2xx EOF 自动按指数退避重连（1s→15s 封顶，收到事件即
 * 复位）；4xx/5xx 断流则停止并上报——401/403 意味着 lease 失效，重新协商
 * 由 SessionMonitor 决策，避免两条重连循环互踩。
 */

import { CursorToken, ProtocolError, RingingV2EventEnvelope, RingingV2ResetRequired,
  RingingV2StreamTerminated, SseDecoder, eventsPath } from '@qaqh/protocol';
import { LeaseTimer } from './transport/Transport';
import { StreamConnection, StreamEndpoint, StreamListener, StreamRequest }
  from './transport/StreamConnection';

export class StreamState {
  static readonly CONNECTING: string = 'connecting';
  static readonly CONNECTED: string = 'connected';
  static readonly RECONNECTING: string = 'reconnecting';
  static readonly STOPPED: string = 'stopped';
}

/** 退避序列（ms），对齐 qaqh-client 的指数退避姿态。 */
const BACKOFF_MS: number[] = [1000, 2000, 4000, 8000, 15000];

/** 看门狗（M14）：服务端 keepalive 15s，45s 无任何字节 = 连接静默死亡
 * （最恶劣形态：不报错只冻住），主动断开走退避重连（cursor 续传兜底）。 */
const WATCHDOG_TICK_MS: number = 15000;
const WATCHDOG_TIMEOUT_MS: number = 45000;

export interface EventStreamListener {
  onEnvelope(envelope: RingingV2EventEnvelope): void;
  onResetRequired(reset: RingingV2ResetRequired): void;
  onStatusChanged(state: string): void;
  /** 4xx/5xx 断流（EventStream 已停止，不再自动重试）。 */
  onHttpDisconnect(status: number): void;
  /** SSE 帧解析响亮失败（EventStream 已停止，坏帧不进重连循环）。 */
  onProtocolError(error: ProtocolError): void;
  /** `ringing.stream_terminated`：租约被撤销/过期，服务端单帧后断流。 */
  onStreamTerminated(terminated: RingingV2StreamTerminated): void;
  /**
   * 到点重连时租约已不在 open（端点组不出来）：本流已停止，
   * 恢复归 SessionMonitor 的重新协商循环。
   */
  onLeaseUnavailable(): void;
}

export class EventStream {
  private readonly sessionId: string;
  private readonly connection: StreamConnection;
  private readonly timer: LeaseTimer;
  private readonly endpointFactory: () => StreamEndpoint;
  private readonly listener: EventStreamListener;

  private state: string = StreamState.STOPPED;
  private decoder: SseDecoder = new SseDecoder();
  private lastCursor: CursorToken | undefined;
  private backoffIndex: number = 0;
  private stopped: boolean = true;
  private lastDataAt: number = 0;

  constructor(sessionId: string, connection: StreamConnection, timer: LeaseTimer,
    endpointFactory: () => StreamEndpoint, listener: EventStreamListener) {
    this.sessionId = sessionId;
    this.connection = connection;
    this.timer = timer;
    this.endpointFactory = endpointFactory;
    this.listener = listener;
  }

  stateValue(): string {
    return this.state;
  }

  lastCursorValue(): CursorToken | undefined {
    return this.lastCursor;
  }

  /** 开始订阅。initialCursor 为空 = 从头重放；快照基线由调用方决定。 */
  start(initialCursor: CursorToken | undefined): void {
    if (initialCursor !== undefined) {
      this.lastCursor = initialCursor;
    }
    this.stopped = false;
    this.connect();
  }

  stop(): void {
    this.stopped = true;
    this.timer.stop();
    this.connection.cancel();
    this.setState(StreamState.STOPPED);
  }

  private setState(state: string): void {
    if (this.state !== state) {
      this.state = state;
      this.listener.onStatusChanged(state);
    }
  }

  private url(): string {
    const base: string = eventsPath(this.sessionId);
    if (this.lastCursor === undefined) {
      return base;
    }
    return `${base}?since_cursor=${this.lastCursor.asString()}`;
  }

  private connect(): void {
    if (this.stopped) {
      // 陈旧回调兜底：stop() 解武装与已排程的 fire 之间存在竞态。
      return;
    }
    // 端点必须在武装看门狗之前组好：connect 由 setTimeout 回调直接调用，异常
    // 越过 napi 边界就是未捕获错误，框架直接杀进程（真机 M14 闪退：
    // invalid_state requires open state, got closed）。
    let endpoint: StreamEndpoint;
    try {
      endpoint = this.endpointFactory();
    } catch (error) {
      void (error as Error);
      this.stop();
      this.listener.onLeaseUnavailable();
      return;
    }
    this.decoder = new SseDecoder();
    this.setState(this.state === StreamState.CONNECTED
      ? StreamState.CONNECTED : StreamState.CONNECTING);
    this.armWatchdog();
    this.connection.connect(
      new StreamRequest(endpoint.baseUrl + this.url(), endpoint.headers),
      new StreamPump(this));
  }

  /** 看门狗用同一个 timer 槽：connect 时武装，15s 一查，45s 无字节强制重连。 */
  private armWatchdog(): void {
    this.lastDataAt = Date.now();
    this.timer.start(WATCHDOG_TICK_MS, () => this.checkWatchdog());
  }

  private checkWatchdog(): void {
    if (this.stopped) {
      return;
    }
    if (Date.now() - this.lastDataAt >= WATCHDOG_TIMEOUT_MS) {
      this.connection.cancel();
      this.scheduleRetry();
      return;
    }
    this.timer.start(WATCHDOG_TICK_MS, () => this.checkWatchdog());
  }

  /** @internal 仅由 StreamPump 调用。 */
  scheduleRetry(): void {
    if (this.stopped || this.state === StreamState.RECONNECTING) {
      // 看门狗 cancel 会连带触发 onFailed → 二次进入由守卫挡掉。
      return;
    }
    const delay: number = BACKOFF_MS[Math.min(this.backoffIndex, BACKOFF_MS.length - 1)];
    this.backoffIndex++;
    this.setState(StreamState.RECONNECTING);
    this.timer.start(delay, () => {
      this.connect();
    });
  }

  /** @internal 仅由 StreamPump 调用：非 2xx 断流上报。 */
  onHttpDisconnect(status: number): void {
    this.listener.onHttpDisconnect(status);
  }

  /** @internal 仅由 StreamPump 调用：坏帧响亮失败，停止订阅。 */
  onStreamProtocolError(error: ProtocolError): void {
    this.listener.onProtocolError(error);
  }

  /** @internal 仅由 StreamPump 调用。 */
  feedChunk(chunk: Uint8Array): void {
    // keepalive 注释帧也走这里（SseDecoder 吞掉但不影响字节计数）。
    this.lastDataAt = Date.now();
    this.decoder.push(chunk);
    for (let frame = this.decoder.nextFrame(); frame !== undefined;
      frame = this.decoder.nextFrame()) {
      if (frame.eventType === 'ringing.reset_required') {
        // 单次事件，随后服务端断流：不再重试，交上层重新 bootstrap。
        this.stopped = true;
        this.timer.stop();
        this.setState(StreamState.STOPPED);
        this.listener.onResetRequired(RingingV2ResetRequired.parse(frame.data));
        return;
      }
      if (frame.eventType === 'ringing.stream_terminated') {
        // 租约撤销/过期：单帧后服务端断流。自动重连只会继续撞门禁，
        // 交 SessionMonitor 重新协商（重新 open + bootstrap）。
        this.stopped = true;
        this.timer.stop();
        this.setState(StreamState.STOPPED);
        this.listener.onStreamTerminated(RingingV2StreamTerminated.parse(frame.data));
        return;
      }
      if (frame.eventType !== 'ringing.event') {
        throw new ProtocolError('invalid_sse_event_type', frame.eventType);
      }
      const envelope: RingingV2EventEnvelope = RingingV2EventEnvelope.parse(frame.data);
      if (envelope.cursor !== undefined) {
        this.lastCursor = envelope.cursor;
      }
      if (this.backoffIndex > 0) {
        this.backoffIndex = 0;
      }
      if (this.state !== StreamState.CONNECTED) {
        this.setState(StreamState.CONNECTED);
      }
      this.listener.onEnvelope(envelope);
    }
  }
}

/** StreamListener 适配：把连接回调转回 EventStream 的私有路径。 */
class StreamPump implements StreamListener {
  private readonly owner: EventStream;

  constructor(owner: EventStream) {
    this.owner = owner;
  }

  onData(chunk: Uint8Array): void {
    let parsed: boolean = false;
    try {
      this.owner.feedChunk(chunk);
      parsed = true;
    } catch (error) {
      if (error instanceof ProtocolError) {
        // 响亮失败：坏帧不进重连循环，停下交上层处置。
        this.owner.stop();
        this.owner.onStreamProtocolError(error);
      } else {
        throw error as Error;
      }
    }
    void parsed;
  }

  onEnded(status: number): void {
    if (status >= 200 && status < 300) {
      // 服务端正常收尾（重启/断开）：自动重连，带 since_cursor 续传。
      this.owner.scheduleRetry();
    } else {
      this.owner.stop();
      this.owner.onHttpDisconnect(status);
    }
  }

  onFailed(code: string, message: string): void {
    this.owner.scheduleRetry();
  }
}
