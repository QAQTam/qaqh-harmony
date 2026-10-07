/**
 * 会话监控器（M2 上层）：把 RingingClient（lease/请求）与 EventStream（SSE）
 * 捏成一个自愈的监视循环，UI 层只消费回调。
 *
 * 流程：open → bootstrap → 从快照基线（或持久化 cursor，log_id 一致时）订阅；
 * 网络断流由 EventStream 自动退避重连；401/403 断流或 lease 失效 → 重新协商
 * （re-open + re-bootstrap + 重新订阅）；`ringing.reset_required` → 上报 UI
 * 清屏 + re-bootstrap；`ringing.stream_terminated`（租约撤销/过期）→ 重新协商。
 *
 * cursor 持久化：每个 reliable 事件落一次（preferences 的 put 便宜），重启用
 * 内存 lastCursor 续传，冷启动用持久化 cursor 追平手机离线期间的事件。
 */

import { CursorToken, pickPreferredSession, ProjectionPayload, ProtocolError,
  RingingV2Bootstrap, RingingV2EventEnvelope, RingingV2ResetRequired,
  RingingV2StreamTerminated } from '@qaqh/protocol';
import { ContentFetch, RingingClient, RingingClientState } from './RingingClient';
import { EventStream, EventStreamListener } from './EventStream';
import { LeaseTimer } from './transport/Transport';
import { StreamConnection, StreamEndpoint } from './transport/StreamConnection';

export class MonitorStatus {
  static readonly DISCOVERING: string = 'discovering';
  static readonly BOOTSTRAPPING: string = 'bootstrapping';
  static readonly LIVE: string = 'live';
  static readonly RENEGOTIATING: string = 'renegotiating';
  static readonly STOPPED: string = 'stopped';
}

/** 自动发现的轮询节拍（对齐安卓 ConnectionService：单活跃流 + 15s 轮询）。 */
const DISCOVERY_INTERVAL_MS: number = 15000;

/** cursor 持久化接口（真机用 @ohos.data.preferences，测试用内存假件）。 */
export interface CursorStore {
  load(): CursorToken | undefined;
  save(token: CursorToken): void;
  clear(): void;
}

export interface SessionMonitorListener {
  onBootstrap(snapshot: RingingV2Bootstrap): void;
  onEnvelope(envelope: RingingV2EventEnvelope, payload: ProjectionPayload): void;
  onResetRequired(reset: RingingV2ResetRequired): void;
  onStatusChanged(status: string): void;
  /** 协议解析响亮失败：订阅已停止，需要人工/上层介入。 */
  onProtocolError(error: ProtocolError): void;
}

export class SessionMonitor {
  private readonly client: RingingClient;
  private readonly connection: StreamConnection;
  private readonly streamTimer: LeaseTimer;
  private readonly discoveryTimer: LeaseTimer | undefined;
  private readonly cursorStore: CursorStore | undefined;
  private readonly listener: SessionMonitorListener;

  private sessionId: string = '';
  private autoDiscover: boolean = false;
  private stream: EventStream | undefined;
  private starting: boolean = false;
  private stopped: boolean = true;
  private status: string = MonitorStatus.STOPPED;

  constructor(client: RingingClient, connection: StreamConnection, streamTimer: LeaseTimer,
    listener: SessionMonitorListener, cursorStore?: CursorStore,
    discoveryTimer?: LeaseTimer) {
    this.client = client;
    this.connection = connection;
    this.streamTimer = streamTimer;
    this.listener = listener;
    this.cursorStore = cursorStore;
    this.discoveryTimer = discoveryTimer;
    // M1 只上报租约丢失，重新协商由这里接线（否则监视循环会停在 closed）。
    this.client.onLeaseLost(() => {
      this.scheduleRenegotiation();
    });
  }

  statusValue(): string {
    return this.status;
  }

  sessionIdValue(): string {
    return this.sessionId;
  }

  /**
   * 开始监视。带 sessionId = 固定会话；不带 = 自动发现模式（轮询
   * session.list,优先 running、其次 updated_at 最新，会话切换时重建流）。
   */
  async start(sessionId?: string): Promise<void> {
    if (sessionId === undefined || sessionId.length === 0) {
      if (this.discoveryTimer === undefined) {
        throw new ProtocolError('invalid_state',
          'auto discovery requires a discovery timer');
      }
      this.autoDiscover = true;
      this.stopped = false;
      await this.discoverOnce();
      return;
    }
    this.autoDiscover = false;
    this.sessionId = sessionId;
    this.stopped = false;
    await this.bootstrapAndSubscribe(undefined);
  }

  stop(): void {
    this.stopped = true;
    this.discoveryTimer?.stop();
    if (this.stream !== undefined) {
      this.stream.stop();
    }
    this.client.close();
    this.cursorStore?.clear();
    this.setStatus(MonitorStatus.STOPPED);
  }

  /** UI 取 ref 内容用（直接透传 client）。 */
  fetchContent(contentId: string): Promise<ContentFetch> {
    return this.client.fetchContent(contentId);
  }

  /** 自动发现一轮：拉会话列表选目标，会话变化时重建流；然后排下一轮。 */
  private async discoverOnce(): Promise<void> {
    if (this.stopped) {
      return;
    }
    if (this.sessionId.length === 0) {
      this.setStatus(MonitorStatus.DISCOVERING);
    }
    let picked: string = '';
    try {
      if (this.client.stateValue() !== RingingClientState.OPEN) {
        await this.client.open();
      }
      const entries = await this.client.sessionList();
      picked = pickPreferredSession(entries);
    } catch (error) {
      // 发现失败不终止监视：网络抖动等下一轮；lease 失效由 client/重连路径处理。
    }
    if (picked.length > 0 && picked !== this.sessionId) {
      this.sessionId = picked;
      if (this.stream !== undefined) {
        this.stream.stop();
        this.stream = undefined;
      }
      await this.bootstrapAndSubscribe(undefined);
    }
    if (!this.stopped && this.autoDiscover) {
      this.discoveryTimer!.start(DISCOVERY_INTERVAL_MS, () => {
        this.discoverOnce();
      });
    }
  }

  private setStatus(status: string): void {
    if (this.status !== status) {
      this.status = status;
      this.listener.onStatusChanged(status);
    }
  }

  private async bootstrapAndSubscribe(cursorOverride: CursorToken | undefined): Promise<void> {
    if (this.stopped || this.starting) {
      return;
    }
    this.starting = true;
    try {
      this.setStatus(MonitorStatus.BOOTSTRAPPING);
      if (this.client.stateValue() !== RingingClientState.OPEN) {
        await this.client.open();
      }
      // 设备身份：归属随 client_session_id 走，每次（重）协商后都要重新 attach，
      // 否则下面的 bootstrap 直接 403 forbidden_not_owner（admin 身份豁免，不attach）。
      if (this.client.attachesSessionsValue()) {
        await this.client.attachSession(this.sessionId);
      }
      const snapshot: RingingV2Bootstrap = await this.client.bootstrap(this.sessionId);
      let initial: CursorToken | undefined = cursorOverride;
      if (initial === undefined) {
        const saved: CursorToken | undefined = this.cursorStore?.load();
        if (saved !== undefined) {
          try {
            if (saved.decodeSnapshot().logId === snapshot.logId()) {
              initial = saved;
            }
          } catch (error) {
            // 无法解码的旧 token 视为不存在，从快照基线开始。
          }
        }
        if (initial === undefined) {
          initial = snapshot.snapshotCursor;
        }
      }
      this.listener.onBootstrap(snapshot);
      this.stream = new EventStream(this.sessionId, this.connection, this.streamTimer,
        (): StreamEndpoint => new StreamEndpoint(
          this.client.baseUrlValue(), this.client.sessionHeadersValue()),
        new MonitorPump(this));
      this.stream.start(initial);
      this.setStatus(MonitorStatus.LIVE);
    } catch (error) {
      if (error instanceof ProtocolError) {
        this.stopped = true;
        this.setStatus(MonitorStatus.STOPPED);
        this.listener.onProtocolError(error);
      } else {
        // 网络/传输错误：按重新协商处理（下轮 lease 定时与重试会继续尝试）。
        this.scheduleRenegotiation();
      }
    } finally {
      this.starting = false;
    }
  }

  private scheduleRenegotiation(): void {
    if (this.stopped) {
      return;
    }
    this.setStatus(MonitorStatus.RENEGOTIATING);
    if (this.client.stateValue() === RingingClientState.OPEN) {
      this.client.close();
    }
    this.bootstrapAndSubscribe(undefined);
  }

  /** @internal 仅由 MonitorPump 调用。 */
  onStreamEnvelope(envelope: RingingV2EventEnvelope): void {
    if (envelope.cursor !== undefined) {
      this.cursorStore?.save(envelope.cursor);
    }
    const payload: ProjectionPayload = ProjectionPayload.parse(envelope.payload);
    this.listener.onEnvelope(envelope, payload);
  }

  /** @internal 仅由 MonitorPump 调用。 */
  onStreamReset(reset: RingingV2ResetRequired): void {
    if (this.stopped) {
      return;
    }
    this.listener.onResetRequired(reset);
    this.bootstrapAndSubscribe(reset.snapshotCursor);
  }

  /**
   * @internal 仅由 MonitorPump 调用。服务端逐事件复查租约，撤销/过期即下发
   * `ringing.stream_terminated` 后断流——本端续期判定丢失之外的第二条发现路径
   * （以及本端从未续期成功过时的唯一路径），两条都走重新协商。
   */
  onStreamTerminated(terminated: RingingV2StreamTerminated): void {
    void terminated;
    this.scheduleRenegotiation();
  }

  /** @internal 仅由 MonitorPump 调用。 */
  onStreamHttpDisconnect(status: number): void {
    if (this.stopped) {
      return;
    }
    if (status === 401 || status === 403) {
      this.scheduleRenegotiation();
    } else {
      // 5xx 等服务端异常：EventStream 已停止，这里走重新协商兜底。
      this.scheduleRenegotiation();
    }
  }

  /** @internal 仅由 MonitorPump 调用。 */
  onStreamProtocolError(error: ProtocolError): void {
    this.stopped = true;
    this.setStatus(MonitorStatus.STOPPED);
    this.listener.onProtocolError(error);
  }

  /** @internal 仅由 MonitorPump 调用。 */
  streamStatusChanged(state: string): void {
    void state; // 流级状态透传给 UI 需要时再加；监视器状态已覆盖主路径。
  }
}

/** EventStreamListener → SessionMonitor 适配（同文件窄桥）。 */
class MonitorPump implements EventStreamListener {
  private readonly owner: SessionMonitor;

  constructor(owner: SessionMonitor) {
    this.owner = owner;
  }

  onEnvelope(envelope: RingingV2EventEnvelope): void {
    this.owner.onStreamEnvelope(envelope);
  }

  onResetRequired(reset: RingingV2ResetRequired): void {
    this.owner.onStreamReset(reset);
  }

  onStatusChanged(state: string): void {
    this.owner.streamStatusChanged(state);
  }

  onHttpDisconnect(status: number): void {
    this.owner.onStreamHttpDisconnect(status);
  }

  onStreamTerminated(terminated: RingingV2StreamTerminated): void {
    this.owner.onStreamTerminated(terminated);
  }

  onProtocolError(error: ProtocolError): void {
    this.owner.onStreamProtocolError(error);
  }
}
