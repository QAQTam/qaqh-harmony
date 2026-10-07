/**
 * Timeline 通道的直播订阅（M7）。
 *
 * 与 EventStream（投影单流 `/events`）的三点差异，决定了它单独成类而不是复用：
 * 1. 帧名是 `timeline.entry`，data 是 `{schema,version,server_epoch,session_id,entry}`；
 * 2. 游标不是 CursorToken，而是 SSE `id:` 原样 `{server_epoch}:timeline:{seq}`，
 *    续传走 `?last_event_id=`；
 * 3. 顺序性靠 `timeline_seq` 全序：`<=` 已知即重复丢弃，`> 已知+1` 是**空洞**——
 *    补帧不回来，必须重取快照（webui store.ts 同款处置；这里交给 listener）。
 *
 * 退避与 EventStream 同节拍；4xx/5xx 不自动重试，交上层决策。
 */

import {
  encodeTimelineCursor, ProtocolError, RingingV2StreamTerminated,
  RingingV2TimelineFrame, SseDecoder, TimelineEntry, timelineEventsPath
} from '@qaqh/protocol';
import { LeaseTimer } from './transport/Transport';
import { StreamConnection, StreamEndpoint, StreamListener, StreamRequest }
  from './transport/StreamConnection';

export class TimelineStreamState {
  static readonly CONNECTING: string = 'connecting';
  static readonly CONNECTED: string = 'connected';
  static readonly RECONNECTING: string = 'reconnecting';
  static readonly STOPPED: string = 'stopped';
}

const BACKOFF_MS: number[] = [1000, 2000, 4000, 8000, 15000];

/** 看门狗（M14，与 EventStream 同参数）：服务端 keepalive 15s，45s 无任何
 * 字节 = 连接静默死亡，主动断开走退避重连（last_event_id 续传兜底）。 */
const WATCHDOG_TICK_MS: number = 15000;
const WATCHDOG_TIMEOUT_MS: number = 45000;

export interface TimelineStreamListener {
  onEntry(entry: TimelineEntry, cursor: string): void;
  /** seq 跳号：中间帧丢了且不会补发，上层必须重取快照。 */
  onGap(expectedSeq: number, actualSeq: number): void;
  onStatusChanged(state: string): void;
  onHttpDisconnect(status: number): void;
  onProtocolError(error: ProtocolError): void;
  /** 租约撤销/过期（timeline 通道同款单帧终止）。 */
  onStreamTerminated(terminated: RingingV2StreamTerminated): void;
}

export class TimelineStream {
  private readonly sessionId: string;
  private readonly connection: StreamConnection;
  private readonly timer: LeaseTimer;
  private readonly endpointFactory: () => StreamEndpoint;
  private readonly listener: TimelineStreamListener;

  private state: string = TimelineStreamState.STOPPED;
  private decoder: SseDecoder = new SseDecoder();
  private watermark: number;
  private serverEpoch: string;
  private cursor: string;
  private backoffIndex: number = 0;
  private stopped: boolean = true;
  private awaitingResnapshot: boolean = false;
  private lastDataAt: number = 0;

  constructor(sessionId: string, connection: StreamConnection, timer: LeaseTimer,
    endpointFactory: () => StreamEndpoint, listener: TimelineStreamListener,
    initialWatermark: number, initialEpoch: string) {
    this.sessionId = sessionId;
    this.connection = connection;
    this.timer = timer;
    this.endpointFactory = endpointFactory;
    this.listener = listener;
    this.watermark = initialWatermark;
    this.serverEpoch = initialEpoch;
    this.cursor = initialEpoch.length > 0
      ? encodeTimelineCursor(initialEpoch, initialWatermark) : '';
  }

  stateValue(): string {
    return this.state;
  }

  watermarkValue(): number {
    return this.watermark;
  }

  cursorValue(): string {
    return this.cursor;
  }

  /** 快照更新水位（重新 seed 后调用，避免把已渲染的条目判成空洞）。 */
  prime(watermark: number, epoch: string): void {
    this.watermark = watermark;
    this.serverEpoch = epoch;
    this.cursor = epoch.length > 0 ? encodeTimelineCursor(epoch, watermark) : '';
    this.awaitingResnapshot = false;
  }

  start(): void {
    this.stopped = false;
    this.connect();
  }

  stop(): void {
    this.stopped = true;
    this.timer.stop();
    this.connection.cancel();
    this.setState(TimelineStreamState.STOPPED);
  }

  private setState(state: string): void {
    if (this.state !== state) {
      this.state = state;
      this.listener.onStatusChanged(state);
    }
  }

  private connect(): void {
    this.decoder = new SseDecoder();
    this.setState(this.state === TimelineStreamState.CONNECTED
      ? TimelineStreamState.CONNECTED : TimelineStreamState.CONNECTING);
    this.armWatchdog();
    const endpoint: StreamEndpoint = this.endpointFactory();
    this.connection.connect(
      new StreamRequest(endpoint.baseUrl + timelineEventsPath(this.sessionId,
        this.cursor), endpoint.headers),
      new TimelinePump(this));
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

  /** @internal 仅由 TimelinePump 调用。 */
  scheduleRetry(): void {
    if (this.stopped || this.state === TimelineStreamState.RECONNECTING) {
      // 看门狗 cancel 会连带触发 onFailed → 二次进入由守卫挡掉。
      return;
    }
    const delay: number = BACKOFF_MS[Math.min(this.backoffIndex, BACKOFF_MS.length - 1)];
    this.backoffIndex++;
    this.setState(TimelineStreamState.RECONNECTING);
    this.timer.start(delay, () => {
      this.connect();
    });
  }

  /** @internal 仅由 TimelinePump 调用。 */
  onHttpDisconnect(status: number): void {
    this.listener.onHttpDisconnect(status);
  }

  /** @internal 仅由 TimelinePump 调用。 */
  onStreamProtocolError(error: ProtocolError): void {
    this.listener.onProtocolError(error);
  }

  /** @internal 仅由 TimelinePump 调用。 */
  feedChunk(chunk: Uint8Array): void {
    this.lastDataAt = Date.now();
    this.decoder.push(chunk);
    for (let frame = this.decoder.nextFrame(); frame !== undefined;
      frame = this.decoder.nextFrame()) {
      if (frame.eventType === 'ringing.stream_terminated') {
        this.stopped = true;
        this.timer.stop();
        this.setState(TimelineStreamState.STOPPED);
        this.listener.onStreamTerminated(RingingV2StreamTerminated.parse(frame.data));
        return;
      }
      if (frame.eventType !== 'timeline.entry') {
        // 与 M6 同策略：陌生帧名不断流（timeline 通道未来也可能加帧）。
        continue;
      }
      const parsed: RingingV2TimelineFrame =
        RingingV2TimelineFrame.parse(frame.data);
      const entry: TimelineEntry = parsed.entry;
      const epochChanged: boolean = this.serverEpoch.length > 0 &&
        parsed.serverEpoch !== this.serverEpoch;
      if (epochChanged) {
        // 服务端重启：旧游标作废，且重放会全量重复 —— 一律交上层重取快照。
        this.serverEpoch = parsed.serverEpoch;
        this.requestResnapshot(this.watermark + 1, entry.timelineSeq);
        return;
      }
      this.serverEpoch = parsed.serverEpoch;
      if (entry.timelineSeq <= this.watermark) {
        continue;
      }
      if (this.watermark > 0 && entry.timelineSeq > this.watermark + 1) {
        // 空洞：中间帧不会补发，这条也不能先渲（否则正文里插一段缺口）。
        this.requestResnapshot(this.watermark + 1, entry.timelineSeq);
        return;
      }
      this.watermark = entry.timelineSeq;
      this.cursor = frame.id.length > 0
        ? frame.id : encodeTimelineCursor(this.serverEpoch, entry.timelineSeq);
      if (this.backoffIndex > 0) {
        this.backoffIndex = 0;
      }
      if (this.state !== TimelineStreamState.CONNECTED) {
        this.setState(TimelineStreamState.CONNECTED);
      }
      this.listener.onEntry(entry, this.cursor);
    }
  }

  /** 只报一次，直到上层 prime() 重新水位；避免每帧都触发重取快照。 */
  private requestResnapshot(expectedSeq: number, actualSeq: number): void {
    if (this.awaitingResnapshot) {
      return;
    }
    this.awaitingResnapshot = true;
    this.listener.onGap(expectedSeq, actualSeq);
  }
}

/** StreamListener → TimelineStream 私有路径适配。 */
class TimelinePump implements StreamListener {
  private readonly owner: TimelineStream;

  constructor(owner: TimelineStream) {
    this.owner = owner;
  }

  onData(chunk: Uint8Array): void {
    try {
      this.owner.feedChunk(chunk);
    } catch (error) {
      if (error instanceof ProtocolError) {
        this.owner.stop();
        this.owner.onStreamProtocolError(error);
      } else {
        throw error as Error;
      }
    }
  }

  onEnded(status: number): void {
    if (status >= 200 && status < 300) {
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
