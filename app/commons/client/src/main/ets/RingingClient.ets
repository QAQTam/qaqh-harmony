/**
 * Ringing v2 连接层（M1）：open / lease 定时 renew / bootstrap / 命令上行。
 *
 * 状态机：idle → open → closed。open 之后所有请求带
 * `X-QAQH-Client-Session-Id`（鉴权只看这个 header，信封里的
 * client_session_id 不参与鉴权——见 M0 handoff 契约认知 5）。
 *
 * lease 策略：open 成功后按 renew_interval_ms 排程续期；网络级失败只重排
 * 下一次（TTL 内还有机会），`ok:false` 或 4xx 视为租约丢失 → close 并回调
 * onLeaseLost。SSE 订阅与断线重连在 M2。
 */

import {
  CLIENT_SESSION_HEADER, openPath, renewLeasePath, bootstrapPath,
  commandPath, commandStatusPath, contentPath, servicePath, driverClaimPath,
  driverReleasePath, ProtocolError, ControlCommands, newCommandId,
  timelinePath, TimelineSnapshotResponse,
  RingingV2OpenRequest, RingingV2OpenResponse, RingingV2LeaseRenewResponse,
  RingingV2Bootstrap, RingingV2CommandEnvelope, RingingV2CommandAck,
  RingingV2CommandStatus, RingingSessionListEntry, RingingV2DriverClaimResponse,
  RingingConfigDto, RingingConfigPatch,
  approvalsPath, approvalRespondPath, RingingApprovalsSnapshot,
  RingingApprovalRespondRequest,
  assertAckMatches
} from '@qaqh/protocol';
import { Transport, TransportRequest, TransportResponse, TransportError,
  LeaseTimer } from './transport/Transport';

export class RingingClientState {
  static readonly IDLE: string = 'idle';
  static readonly OPEN: string = 'open';
  static readonly CLOSED: string = 'closed';
}

/** 租约丢失原因（snake_case）。 */
export class LeaseLostReason {
  static readonly REJECTED: string = 'lease_rejected';
  static readonly RENEWAL_FAILURES: string = 'renewal_failures_exceeded';
}

/** 对齐 qaqh-client session.rs 的判死精神，但真机实测 2 次过急（Wi-Fi 省电抖动
 * 会烧掉两个节拍）：瞬时失败 2s 快速重试，连续 3 次才判死——TTL 30s 窗口内
 * 能吸收 6s+ 的连续抖动，且判死时仍有余量。 */
export const MAX_RENEW_FAILURES: number = 3;

/**
 * 续期请求自己的读超时（对齐安卓 RingingConnection.kt 对 BUG-2026-09-13-09 的
 * 修法）。服务端 TTL 30s / 建议节拍 10s，而 RPC 传输层为容纳大正文快照配到
 * 120s——一次挂起的 renew 会静默烧穿整个 TTL 窗口（`renewing` 门还会挡住后续
 * 节拍），回来就是 401 lease_expired + 归属被 expire 连带清掉。
 */
export const RENEW_REQUEST_TIMEOUT_MS: number = 10000;
/** 瞬时失败后的快速重试间隔（ms）：不等完整节拍，在 TTL 窗口内密集补救。 */
export const RENEW_RETRY_MS: number = 2000;

/** content 端点取回的正文。 */
export class ContentFetch {
  readonly mediaType: string;
  readonly body: string;

  constructor(mediaType: string, body: string) {
    this.mediaType = mediaType;
    this.body = body;
  }
}

/**
 * 服务面 RPC（`/ringing/v2/service/{method}`）的错误回包：HTTP 4xx 且
 * body 为 `{code, message}`（`service_methods::error_response`——Read 类
 * code=`query_failed`，Write 类 code=`action_failed`，白名单拒绝
 * code=`forbidden`）。UI 可直接展示 message 并按 code 分支。
 */
export class ServiceRpcError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(code: string, message: string, status: number) {
    super(message.length > 0 ? `${code}: ${message}` : code);
    this.code = code;
    this.status = status;
  }
}

export class RingingClientConfig {
  readonly baseUrl: string;
  readonly token: string;
  readonly clientInstanceId: string;
  readonly transport: Transport;
  readonly timer: LeaseTimer;
  /**
   * true = 用的是配对来的设备身份：读任何会话前必须先 `session_attach` 建立归属
   * （daemon 的 `owns_session` 门禁，未 attach 一律 403 forbidden_not_owner）。
   * false = Admin 令牌（daemon 豁免归属），行为与桌面端一致。
   * 归属按 client_session_id 记，所以每次重新协商（换 cs）后都要重新 attach。
   */
  readonly attachesSessions: boolean;

  constructor(baseUrl: string, token: string, clientInstanceId: string,
    transport: Transport, timer: LeaseTimer, attachesSessions?: boolean) {
    this.baseUrl = baseUrl;
    this.token = token;
    this.clientInstanceId = clientInstanceId;
    this.transport = transport;
    this.timer = timer;
    this.attachesSessions = attachesSessions !== undefined ? attachesSessions : false;
  }
}

export class RingingClient {
  private readonly config: RingingClientConfig;
  private state: string = RingingClientState.IDLE;
  private clientSessionId: string = '';
  private serverEpoch: string = '';
  private leaseTtlMs: number = 0;
  private renewIntervalMs: number = 0;
  private renewing: boolean = false;
  private renewFailures: number = 0;
  private leaseLostCallback: ((reason: string) => void) | undefined;

  constructor(config: RingingClientConfig) {
    this.config = config;
  }

  /** 租约丢失回调（在 renew 判定丢失后同步触发）。 */
  onLeaseLost(callback: (reason: string) => void): void {
    this.leaseLostCallback = callback;
  }

  stateValue(): string {
    return this.state;
  }

  /** @internal 供 SessionMonitor 组装流请求（同模块窄接口）。 */
  baseUrlValue(): string {
    return this.config.baseUrl;
  }

  /** @internal 供 SessionMonitor 组装流请求（同模块窄接口）。 */
  sessionHeadersValue(): Record<string, string> {
    this.requireOpen();
    return this.sessionHeaders();
  }

  sessionHeader(): string {
    return this.clientSessionId;
  }

  serverEpochValue(): string {
    return this.serverEpoch;
  }

  leaseInfo(): number[] {
    return [this.leaseTtlMs, this.renewIntervalMs];
  }

  /**
   * `POST /ringing/v2/clients/open`。成功后进入 open 并启动续期定时。
   * 允许从 idle / closed 进入（closed = 租约失效后的重新协商）。
   */
  async open(): Promise<RingingV2OpenResponse> {
    if (this.state === RingingClientState.OPEN) {
      throw new ProtocolError('invalid_state', 'open while already open');
    }
    let body: string = JSON.stringify(
      new RingingV2OpenRequest(this.config.clientInstanceId).toWire());
    const response: TransportResponse = await this.sendJson(
      'POST', openPath(), this.anonymousHeaders(), body);
    const parsed: RingingV2OpenResponse = RingingV2OpenResponse.parse(response.body);
    if (!parsed.accepted) {
      throw new ProtocolError('open_rejected', 'server returned accepted:false');
    }
    if (!parsed.capabilities.singleStream) {
      throw new ProtocolError('single_stream_required',
        'capabilities.single_stream must be true (单流协议前提)');
    }
    this.clientSessionId = parsed.clientSessionId;
    this.serverEpoch = parsed.serverEpoch;
    this.leaseTtlMs = parsed.leaseTtlMs;
    this.renewIntervalMs = parsed.renewIntervalMs;
    this.state = RingingClientState.OPEN;
    this.scheduleRenew();
    return parsed;
  }

  /**
   * `POST /ringing/v2/leases/renew`。与 qaqh-client 参考实现逐字节对齐：
   * 无请求体，鉴权 = Bearer token + `X-QAQH-Client-Session-Id` header；
   * 租约过期时后端返回 HTTP 401 `lease_expired`（axum_impl/v2.rs handle_renew_v2）。
   *
   * 失败策略（M14 续期加固，真机定性后偏离 session.rs 参考实现）：
   * - 4xx = 服务端明确拒绝（过期/吊销/归属不符）→ 立即 leaseLost(REJECTED)；
   * - 瞬时失败（网络错误/超时/5xx）→ 2s 快速重试（RENEW_RETRY_MS），连续
   *   >= MAX_RENEW_FAILURES(3) 才判死 → close + onLeaseLost，重新 open 由
   *   上层会话循环负责（M2 接管）。
   */
  async renewLease(): Promise<void> {
    if (this.state !== RingingClientState.OPEN || this.renewing) {
      return;
    }
    this.renewing = true;
    try {
      const response: TransportResponse = await this.sendJson(
        'POST', renewLeasePath(), this.sessionHeaders(), '', RENEW_REQUEST_TIMEOUT_MS);
      const parsed: RingingV2LeaseRenewResponse = RingingV2LeaseRenewResponse.parse(response.body);
      if (!parsed.ok) {
        this.leaseLost(LeaseLostReason.REJECTED);
        return;
      }
      this.leaseTtlMs = parsed.leaseTtlMs;
      this.renewIntervalMs = parsed.renewIntervalMs;
      this.renewFailures = 0;
    } catch (error) {
      if (error instanceof TransportError && error.status >= 400 && error.status < 500) {
        this.leaseLost(LeaseLostReason.REJECTED);
        return;
      }
      this.renewFailures++;
      if (this.renewFailures >= MAX_RENEW_FAILURES) {
        this.leaseLost(LeaseLostReason.RENEWAL_FAILURES);
        return;
      }
      this.scheduleFastRenew();
      return;
    } finally {
      this.renewing = false;
    }
    if (this.state === RingingClientState.OPEN) {
      this.scheduleRenew();
    }
  }

  /** `GET /ringing/v2/sessions/{seed}/bootstrap`。 */
  async bootstrap(sessionId: string): Promise<RingingV2Bootstrap> {
    this.requireOpen();
    const response: TransportResponse = await this.sendJson(
      'GET', bootstrapPath(sessionId), this.sessionHeaders(), '');
    return RingingV2Bootstrap.parse(response.body);
  }

  /** 是否设备身份（需先 attach 才持有会话归属）。 */
  attachesSessionsValue(): boolean {
    return this.config.attachesSessions;
  }

  /**
   * `GET /ringing/v2/sessions/{id}/timeline`（正文快照，服务端已把 blocks 摊平成
   * 字符串，客户端不用再解 content ref）。
   *
   * 设备身份必须先 attach 才读得到（403 `lease_required`）；Admin 在这里**不豁免**
   * ——`handle_timeline_snapshot` 只按 `client_session_id` 判归属，实测未 attach 的
   * admin 也拿到 401 `lease_required: attach the session before reading timeline`。
   */
  async timelineSnapshot(sessionId: string, limit?: number,
    beforeIndex?: number): Promise<TimelineSnapshotResponse> {
    this.requireOpen();
    const response: TransportResponse = await this.sendJson('GET',
      timelinePath(sessionId, limit, beforeIndex), this.sessionHeaders(), '');
    return TimelineSnapshotResponse.parse(response.body);
  }

  /**
   * `session_attach`（control 频道）：只建立 lease↔会话归属，不触碰 actor。
   * 设备身份读/订阅任何会话的前提，且**每个新 client_session_id 都要做一次**
   * ——归属按 cs 记，重新协商换 cs 后旧归属即成僵尸身份。
   */
  async attachSession(sessionId: string): Promise<RingingV2CommandAck> {
    const envelope: RingingV2CommandEnvelope = RingingV2CommandEnvelope.create(
      newCommandId(), this.config.clientInstanceId, this.sessionHeader(), sessionId,
      ControlCommands.sessionAttach(sessionId));
    return this.sendCommand(envelope);
  }

  /**
   * `POST /ringing/v2/commands/{channel}`，核对 ACK 的 command_id。
   * 拒绝态 ACK 的 command_id 允许为空（如 not_driver 门禁拒绝，见
   * handle_command_v2 driver admission），command_id 核对只对 accepted 做。
   */
  async sendCommand(envelope: RingingV2CommandEnvelope): Promise<RingingV2CommandAck> {
    this.requireOpen();
    let body: string = JSON.stringify(envelope.toWire());
    const response: TransportResponse = await this.sendJson(
      'POST', commandPath(envelope.command.channel), this.sessionHeaders(), body);
    const ack: RingingV2CommandAck = RingingV2CommandAck.parse(response.body);
    if (ack.status === 'accepted') {
      assertAckMatches(envelope.commandId, ack.commandId);
    }
    return ack;
  }

  /** `GET /ringing/v2/commands/{command_id}`（ACK 丢失时的状态查询）。 */
  async commandStatus(commandId: string): Promise<RingingV2CommandStatus> {
    this.requireOpen();
    const response: TransportResponse = await this.sendJson(
      'GET', commandStatusPath(commandId), this.sessionHeaders(), '');
    return RingingV2CommandStatus.parse(response.body);
  }

  /**
   * `GET /ringing/v2/content/{content_id}`。返回原始正文（裸字节形态由
   * store 决定，通常为文本）与 media_type（无 Content-Type 时为空串）。
   */
  async fetchContent(contentId: string): Promise<ContentFetch> {
    this.requireOpen();
    const response: TransportResponse = await this.sendJson(
      'GET', contentPath(contentId), this.sessionHeaders(), '');
    const headers: Record<string, string> = response.headers;
    const contentType: string = headers['Content-Type'] !== undefined
      ? headers['Content-Type'] : (headers['content-type'] ?? '');
    return new ContentFetch(contentType, response.body);
  }

  /**
   * `POST /ringing/v2/service/session.list`（会话自动发现的数据源，
   * 对齐安卓 ConnectionService 的"单活跃流 + 轮询"模式）。
   */
  async sessionList(): Promise<RingingSessionListEntry[]> {
    this.requireOpen();
    const response: TransportResponse = await this.sendJson(
      'POST', servicePath('session.list'), this.sessionHeaders(), '{}');
    return RingingSessionListEntry.parseArray(response.body);
  }

  /**
   * `POST /ringing/v2/service/config.load`：读模型（BYOK 六字段 +
   * 掩码 apiKey，camelCase、缺字段即解析失败）。
   */
  async configLoad(): Promise<RingingConfigDto> {
    this.requireOpen();
    const response: TransportResponse = await this.sendServiceRpc('config.load', '{}');
    return RingingConfigDto.parse(response.body);
  }

  /**
   * `POST /ringing/v2/service/config.save`：JSON Merge Patch（缺失 = 不动）。
   * 本地先做与后端 `ConfigPatch::validate` 同域的值域校验，非法补丁不出端；
   * apiKey 掩码语义：`"****"`/空串 = 保持现值。
   */
  async configSave(patch: RingingConfigPatch): Promise<void> {
    this.requireOpen();
    const problem: string = patch.validate();
    if (problem.length > 0) {
      throw new ProtocolError('invalid_patch', problem);
    }
    await this.sendServiceRpc('config.save', JSON.stringify(patch.toWire()));
  }

  /** `POST /ringing/v2/service/profile.apply`：切 profile = 切端点（wire/compat/contextLength 一起换）。 */
  async applyProfile(name: string): Promise<void> {
    this.requireOpen();
    const params: Record<string, Object> = { 'name': name };
    await this.sendServiceRpc('profile.apply', JSON.stringify(params));
  }

  /** `POST /ringing/v2/service/profile.save_current`：把当前配置存为新 profile。 */
  async saveCurrentProfile(name: string): Promise<void> {
    this.requireOpen();
    const params: Record<string, Object> = { 'name': name };
    await this.sendServiceRpc('profile.save_current', JSON.stringify(params));
  }

  /** `POST /ringing/v2/service/profile.delete`：删 profile（default 与不存在者被后端拒绝）。 */
  async deleteProfile(name: string): Promise<void> {
    this.requireOpen();
    const params: Record<string, Object> = { 'name': name };
    await this.sendServiceRpc('profile.delete', JSON.stringify(params));
  }

  /** `POST /ringing/v2/service/config.set_permission_level`：权限档位 1..=3 单写口。 */
  async setPermissionLevel(level: number): Promise<void> {
    this.requireOpen();
    if (level < 1 || level > 3) {
      throw new ProtocolError('invalid_patch',
        'permissionLevel 仅允许 1..=3（1=read-only, 2=workspace-write, 3=skip-permissions）');
    }
    const params: Record<string, Object> = { 'level': level };
    await this.sendServiceRpc('config.set_permission_level', JSON.stringify(params));
  }

  /**
   * `POST /ringing/v2/sessions/{id}/driver/claim`（驱动席认领）。
   * accepted=false（driver_busy）= 活跃 holder 在位；accepted=true 时
   * reason=already_holder 表示本端已持有（driverEpoch 即当前值），
   * claim_requested 表示认领已转发、席位经 DriverChanged 事件生效。
   */
  async driverClaim(sessionId: string): Promise<RingingV2DriverClaimResponse> {
    this.requireOpen();
    const response: TransportResponse = await this.sendJson(
      'POST', driverClaimPath(sessionId), this.sessionHeaders(), '');
    return RingingV2DriverClaimResponse.parse(response.body);
  }

  /** `POST /ringing/v2/sessions/{id}/driver/release`（礼貌释放驱动席）。 */
  async driverRelease(sessionId: string): Promise<void> {
    this.requireOpen();
    await this.sendJson('POST', driverReleasePath(sessionId), this.sessionHeaders(), '');
  }

  /**
   * `GET /ringing/v2/sessions/{id}/approvals`：会话待审批快照（M12 聚合轮询
   * 数据源）。device 身份要求本 client 的租约已 attach 该会话；device/admin
   * 两种快照形状由解析器自动判别。
   */
  async approvalsList(sessionId: string): Promise<RingingApprovalsSnapshot> {
    this.requireOpen();
    const response: TransportResponse = await this.sendJson(
      'GET', approvalsPath(sessionId), this.sessionHeaders(), '');
    return RingingApprovalsSnapshot.parse(response.body);
  }

  /**
   * `POST /ringing/v2/sessions/{id}/approvals/respond`（device 身份的审批应答）。
   * challenge 与会话绑定且一次性消费：应答必须打到**条目自带**的 sessionId 上，
   * 票错会话会被服务端以 approval_scope_violation 拒绝（且票被消费，不可重试）。
   */
  async approvalsRespond(sessionId: string, challengeId: string, decision: string,
    payload: object | undefined): Promise<void> {
    this.requireOpen();
    if (!RingingApprovalRespondRequest.validateDecision(decision)) {
      throw new ProtocolError('invalid_decision', `unknown decision: ${decision}`);
    }
    const request: RingingApprovalRespondRequest =
      new RingingApprovalRespondRequest(challengeId, decision, payload);
    await this.sendJson('POST', approvalRespondPath(sessionId), this.sessionHeaders(),
      JSON.stringify(request.toWire()));
  }

  close(): void {
    this.config.timer.stop();
    this.state = RingingClientState.CLOSED;
  }

  private requireOpen(): void {
    if (this.state !== RingingClientState.OPEN) {
      throw new ProtocolError('invalid_state', `requires open state, got ${this.state}`);
    }
  }

  private scheduleRenew(): void {
    this.config.timer.start(Math.max(1000, Math.floor(this.renewIntervalMs / 2)), () => {
      this.renewLease();
    });
  }

  /** 瞬时失败后的快速重试（固定 2s，不等完整节拍）。 */
  private scheduleFastRenew(): void {
    this.config.timer.start(RENEW_RETRY_MS, () => {
      this.renewLease();
    });
  }

  private anonymousHeaders(): Record<string, string> {
    let headers: Record<string, string> = {
      'Authorization': `Bearer ${this.config.token}`,
      'Content-Type': 'application/json'
    };
    return headers;
  }

  private sessionHeaders(): Record<string, string> {
    let headers: Record<string, string> = this.anonymousHeaders();
    headers[CLIENT_SESSION_HEADER] = this.clientSessionId;
    return headers;
  }

  private async sendJson(method: string, path: string,
    headers: Record<string, string>, body: string, timeoutMs?: number): Promise<TransportResponse> {
    const response: TransportResponse = await this.config.transport.send(
      new TransportRequest(method, this.config.baseUrl + path, headers, body, timeoutMs));
    if (response.status < 200 || response.status >= 300) {
      const excerpt: string = response.body.length > 200
        ? response.body.substring(0, 200) : response.body;
      throw new TransportError('http_status', response.status, excerpt);
    }
    return response;
  }

  /**
   * 服务面 RPC 专用发送：错误回包按 `{code, message}` 解析成
   * `ServiceRpcError`（后端 `service_methods::error_response`）；解不出该
   * 形状（如 404 unknown_method 的固定 body 之外、网关/代理页）退回
   * `TransportError`，与其它端点失败形态一致。
   */
  private async sendServiceRpc(method: string, body: string): Promise<TransportResponse> {
    const response: TransportResponse = await this.config.transport.send(
      new TransportRequest('POST', this.config.baseUrl + servicePath(method),
        this.sessionHeaders(), body));
    if (response.status >= 200 && response.status < 300) {
      return response;
    }
    try {
      const parsed = JSON.parse(response.body) as Record<string, Object>;
      const code: Object | undefined = parsed['code'];
      const message: Object | undefined = parsed['message'];
      if (typeof code === 'string' && typeof message === 'string') {
        throw new ServiceRpcError(code, message, response.status);
      }
    } catch (error) {
      if (error instanceof ServiceRpcError) {
        throw error;
      }
      // body 不是 JSON：落到下面的 TransportError。
    }
    const excerpt: string = response.body.length > 200
      ? response.body.substring(0, 200) : response.body;
    throw new TransportError('http_status', response.status, excerpt);
  }

  private leaseLost(reason: string): void {
    this.config.timer.stop();
    this.state = RingingClientState.CLOSED;
    if (this.leaseLostCallback !== undefined) {
      this.leaseLostCallback(reason);
    }
  }
}
