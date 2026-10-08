/**
 * AppModel（M9-1）：业务逻辑出视图——连接/配对/列表轮询/会话监视/正文流/
 * 审批闭环/流式 flush 全部收进这个单例，页面组件只做渲染与事件转发。
 *
 * 视图态经 AppStorage 广播（`qaqh*` 键，常量见 QaqhState）：
 * - 为什么不用 @Observed 层层 @ObjectLink：三 tab + Navigation 路由下，
 *   状态消费者散在多处（tabBar 角标要跟着 pending 数变），AppStorage 的
 *   @StorageLink 是 ArkUI 里唯一跨任意层级、零样板的响应通道；
 * - 正文行表走 TranscriptModel 增量 + RowsDataSource（M8 的 O1 契约不变），
 *   tick 键只当节拍信号，不搬数据。
 *
 * 迁移自 pages/Index.ets（M2-M8.1），行为语义逐条对齐，未动连接层。
 */

import {
  ContentFetch, HttpStreamConnection, HttpTransport, InteractionCenter,
  InteractionCenterListener, MonitorStatus, PendingInteractionView, PairingClient,
  PairingError, RingingClient, RingingClientConfig, RingingClientState, SessionMonitor,
  SessionMonitorListener, SystemLeaseTimer, StreamEndpoint, TimelineStream,
  TimelineStreamListener, TranscriptModel, TlsTrust
} from '@qaqh/client';
import {
  AskAnswer, ApprovalDecision, ConfigWire, ContentValueInline, ContentValueRef,
  ControlCommands, ConversationCommands, InteractionBody, PairQrPayload,
  ProjectionPayload, ProtocolError, RingingCommand, RingingConfigDto,
  RingingConfigPatch, RingingSessionListEntry, RingingV2Bootstrap,
  RingingV2CommandAck,
  RingingV2CommandEnvelope, RingingV2EventEnvelope, RingingV2ResetRequired,
  RingingV2StreamTerminated, TimelineEntry, TimelineSnapshotResponse, ToolCommands,
  visibleSessions,
  RingingApprovalsSnapshot, newCommandId
} from '@qaqh/protocol';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { DaemonAccessStore, PairedDevice, TrustSettings } from '../config/DaemonAccessStore';
import { PreferencesCursorStore } from '../cursor/PreferencesCursorStore';
import { Authenticator, UserIamAuthenticator, NoopAuthenticator } from '../auth/Authenticator';
import { approvalSummary, ApprovalNotifier } from '../notify/ApprovalNotifier';
import { LiveViewNotifier } from '../notify/LiveViewNotifier';
import { MemoryProbe } from '../perf/MemoryProbe';
import { ApprovalCardView } from '../view/ApprovalPanel';
import { RowsDataSource } from '../view/TranscriptVm';
import { QaqhState } from './QaqhState';

/** AppStorage 键名单源在 QaqhState（独立文件避免视图↔模型循环引用），这里转发方便老代码引用。 */
export { QaqhState };

/** 列表轮询节拍（对齐 SessionMonitor 自动发现：15s）。 */
const LIST_POLL_MS: number = 15000;
/** hilog 出口（同 MemoryProbe 配方）：wire 漂移一条不落，但每进程只响一次。 */
const HILOG_DOMAIN: number = 0x0;
const HILOG_TAG: string = 'QaqhWire';
/** 正文快照一页的回合数（对齐 webui 的 SNAPSHOT_LIMIT）。 */
const TRANSCRIPT_PAGE_LIMIT: number = 50;
/** 流式渲染合并节拍（M8 契约：一个窗口内的多条 delta 渲一次）。 */
const FLUSH_MS: number = 150;
/** 跨会话审批聚合轮询节拍（challenge TTL 5min，6s 足够新鲜且不重）。 */
const APPROVAL_POLL_MS: number = 6000;
/** 应答成功后抑制该会话重入轮询的窗口：投影落地有短延迟，防同一挂起闪回。 */
const RESPOND_SUPPRESS_MS: number = 8000;

/** 回调装配：SessionMonitorListener 闭包桥（struct 不能被普通类引用）。 */
class LambdaListener implements SessionMonitorListener {
  private bootstrapFn: (snapshot: RingingV2Bootstrap) => void;
  private envelopeFn: (envelope: RingingV2EventEnvelope, payload: ProjectionPayload) => void;
  private resetFn: (reset: RingingV2ResetRequired) => void;
  private statusFn: (status: string) => void;
  private errorFn: (error: ProtocolError) => void;

  constructor(bootstrapFn: (snapshot: RingingV2Bootstrap) => void,
    envelopeFn: (envelope: RingingV2EventEnvelope, payload: ProjectionPayload) => void,
    resetFn: (reset: RingingV2ResetRequired) => void,
    statusFn: (status: string) => void, errorFn: (error: ProtocolError) => void) {
    this.bootstrapFn = bootstrapFn;
    this.envelopeFn = envelopeFn;
    this.resetFn = resetFn;
    this.statusFn = statusFn;
    this.errorFn = errorFn;
  }

  onBootstrap(snapshot: RingingV2Bootstrap): void {
    this.bootstrapFn(snapshot);
  }

  onEnvelope(envelope: RingingV2EventEnvelope, payload: ProjectionPayload): void {
    this.envelopeFn(envelope, payload);
  }

  onResetRequired(reset: RingingV2ResetRequired): void {
    this.resetFn(reset);
  }

  onStatusChanged(status: string): void {
    this.statusFn(status);
  }

  onProtocolError(error: ProtocolError): void {
    this.errorFn(error);
  }
}

/** 回调装配：TimelineStreamListener 闭包桥（正文通道）。 */
class LambdaTimelineListener implements TimelineStreamListener {
  private entryFn: (entry: TimelineEntry) => void;
  private gapFn: (expectedSeq: number, actualSeq: number) => void;
  private statusFn: (text: string) => void;

  constructor(entryFn: (entry: TimelineEntry) => void,
    gapFn: (expectedSeq: number, actualSeq: number) => void,
    statusFn: (text: string) => void) {
    this.entryFn = entryFn;
    this.gapFn = gapFn;
    this.statusFn = statusFn;
  }

  onEntry(entry: TimelineEntry, cursor: string): void {
    void cursor;
    this.entryFn(entry);
  }

  onGap(expectedSeq: number, actualSeq: number): void {
    this.gapFn(expectedSeq, actualSeq);
  }

  onStatusChanged(state: string): void {
    void state;
  }

  onHttpDisconnect(status: number): void {
    this.statusFn(`正文流断开（HTTP ${status}），重新协商后自动重连`);
  }

  onProtocolError(error: ProtocolError): void {
    this.statusFn(`正文流协议错误: ${error.code}`);
  }

  onStreamTerminated(terminated: RingingV2StreamTerminated): void {
    this.statusFn(`正文流被服务端终止（${terminated.code}）`);
  }

  onLeaseUnavailable(): void {
    this.statusFn('正文流租约失效，重新协商后自动重连');
  }
}

/** 回调装配：InteractionCenterListener 同款闭包桥。 */
class LambdaInteractionListener implements InteractionCenterListener {
  private pendingFn: (pending: PendingInteractionView[]) => void;
  private resolvedFn: (interactionId: string, detail: string) => void;
  private failedFn: (interactionId: string, detail: string) => void;

  constructor(pendingFn: (pending: PendingInteractionView[]) => void,
    resolvedFn: (interactionId: string, detail: string) => void,
    failedFn: (interactionId: string, detail: string) => void) {
    this.pendingFn = pendingFn;
    this.resolvedFn = resolvedFn;
    this.failedFn = failedFn;
  }

  onPendingChanged(pending: PendingInteractionView[]): void {
    this.pendingFn(pending);
  }

  onInteractionResolved(interactionId: string, detail: string): void {
    this.resolvedFn(interactionId, detail);
  }

  onRespondFailed(interactionId: string, detail: string): void {
    this.failedFn(interactionId, detail);
  }
}

/** 审批 wire kind → 视图 kind（UI/InteractionBody 用 `permission`）。 */
function approvalViewKind(wireKind: string): string {
  return wireKind === 'tool_permission' ? 'permission' : wireKind;
}

export class AppModel {
  private static instanceValue: AppModel | undefined;

  static instance(): AppModel {
    if (AppModel.instanceValue === undefined) {
      AppModel.instanceValue = new AppModel();
    }
    return AppModel.instanceValue;
  }
  /** 正文模型与行数据源：详情页/视图直接引用（行为对象，不进 AppStorage）。 */
  readonly transcript: TranscriptModel = new TranscriptModel();
  readonly rowsSource: RowsDataSource = new RowsDataSource();
  /** 深链预选（EntryAbility 广播；详情页 ApprovalPanel 消费）。 */
  focusInteraction: string = '';
  focusAction: string = '';

  private context: common.UIAbilityContext | undefined;
  private listClient: RingingClient | undefined;
  private listInstanceId: string = '';
  private listPoller: SystemLeaseTimer = new SystemLeaseTimer();
  private monitor: SessionMonitor | undefined;
  private accessStore: DaemonAccessStore | undefined;
  private paired: PairedDevice | undefined;
  private monitorClient: RingingClient | undefined;
  private monitorInstanceId: string = '';
  private interactionCenter: InteractionCenter | undefined;
  private interactionBodies: Map<string, InteractionBody> = new Map();
  private cursorStore: PreferencesCursorStore | undefined;
  private timelineStream: TimelineStream | undefined;
  private timelineLoading: boolean = false;
  private olderCursor: number = -1;
  private flushScheduled: boolean = false;
  // ---------- 跨会话审批聚合（M12） ----------
  // 数据源：独立聚合 client（一条租约 attach 全部运行中会话）轮询
  // GET /sessions/{id}/approvals。防串频的三道本地防线：
  // 1. 条目不可变绑定 (sessionId, wireId)，应答永远打到条目自带的会话路径；
  // 2. 当前监视会话不进聚合轮询（它的审批走 InteractionCenter 实时流，
  //    每会话单一数据源，不会出现双卡漂移）；
  // 3. 应答成功后本会话抑制一个轮询窗口（投影落地短延迟，防同一挂起闪回）。
  //    服务端兜底：challenge 与会话绑定 + 一次性消费（scope 错也消费）。
  private approvalClient: RingingClient | undefined;
  private approvalInstanceId: string = '';
  private approvalPoller: SystemLeaseTimer = new SystemLeaseTimer();
  private approvalPollBusy: boolean = false;
  /** 已就绪（device 身份 = attach 完成）可轮询的会话集合。 */
  private approvalTargets: Set<string> = new Set();
  private sessionSuppressedUntil: Map<string, number> = new Map();
  /** key = `${sessionId}#${wireId}`（本地唯一键，ForEach/深链/去重全用它）。 */
  private remotePending: Map<string, PendingInteractionView> = new Map();
  /** 监视会话的实时 pending（InteractionCenter 广播的最新一份）。 */
  private livePending: PendingInteractionView[] = [];
  /** 最近一轮 session.list（卡片会话徽标的名称来源）。 */
  private listEntries: RingingSessionListEntry[] = [];
  /** 表外键已告警过（15s 一轮，不刷屏）。 */
  private wireDriftNoted: boolean = false;
  /** 实况窗回合胶囊的本地边沿标记（与 AppStorage TURN_ACTIVE 解耦，防漏 flip）。 */
  private turnLiveShown: boolean = false;
  private notifier: ApprovalNotifier = new ApprovalNotifier('com.qaqh.harmony',
    'EntryAbility');
  private liveView: LiveViewNotifier = new LiveViewNotifier('com.qaqh.harmony',
    'EntryAbility');
  private authenticator: Authenticator = UserIamAuthenticator.create() ??
    new NoopAuthenticator();
  /** 内存探针（M13）：init 即开表，hilog 落账 + 设置页调试卡消费。 */
  private probe: MemoryProbe = new MemoryProbe();

  // ---------- 状态广播（写 AppStorage，视图 @StorageLink 消费） ----------

  private put(key: string, value: Object): void {
    AppStorage.setOrCreate(key, value);
  }

  private text(key: string): string {
    const raw: Object | undefined = AppStorage.get<Object>(key);
    return typeof raw === 'string' ? raw as string : '';
  }

  private numberValue(key: string): number {
    const raw: Object | undefined = AppStorage.get<Object>(key);
    return typeof raw === 'number' ? raw as number : 0;
  }

  private boolValue(key: string): boolean {
    const raw: Object | undefined = AppStorage.get<Object>(key);
    return raw === true;
  }

  private status(text: string): void {
    this.put(QaqhState.STATUS, text);
  }

  private setStatus(): void {
    this.put(QaqhState.TICK, this.numberValue(QaqhState.TICK) + 1);
  }

  // ---------- 启动 ----------

  init(context: common.UIAbilityContext): void {
    if (this.context !== undefined) {
      return;
    }
    this.context = context;
    this.probe.start();
    const store: DaemonAccessStore = new DaemonAccessStore(context);
    this.accessStore = store;
    // daemon 地址一律由配对/设置页写入，不预置任何默认值：内网地址写进源码
    // 会随构建产物分发，且残留值会让"当前地址"看起来已经配置好。
    this.put(QaqhState.BASE_URL, '');
    this.put(QaqhState.STATUS, '未连接');
    store.prime().then(() => {
      const trust: TrustSettings = store.loadTrust();
      this.put(QaqhState.CA_PEM, trust.caCertPem);
      this.put(QaqhState.SKIP_VERIFY, trust.skipVerify);
      this.paired = store.loadDevice();
      // 冷启回灌已配对凭证里的地址：地址不再有源码默认值，不回灌就得每次手填
      // （activeToken 也要求两边地址一致，否则静默自连不会触发）。
      if (this.paired !== undefined && this.text(QaqhState.BASE_URL).trim().length === 0) {
        this.put(QaqhState.BASE_URL, this.paired.baseUrl);
      }
      this.refreshPairedLabel();
      // 开屏引导（M14）：没有已配对凭证 = 首屏落在扫码/手动配对，不进主壳。
      this.put(QaqhState.ONBOARD, this.paired === undefined);
      // 移动端前端标准：有已配对的凭证就静默自连，设置页只留给改配置用。
      if (this.activeToken().length > 0) {
        this.connect();
      }
    }).catch((error: Error) => {
      this.statusText(`本地凭证读取失败: ${error.message}`);
    });
  }

  private statusText(message: string): void {
    this.put(QaqhState.STATUS, message);
  }

  // ---------- 信任与凭证 ----------

  private trust(): TlsTrust {
    return new TlsTrust(this.text(QaqhState.CA_PEM).trim(),
      this.boolValue(QaqhState.SKIP_VERIFY));
  }

  refreshPairedLabel(): void {
    const paired: PairedDevice | undefined = this.paired;
    if (paired === undefined) {
      this.put(QaqhState.PAIRED_LABEL, '');
      return;
    }
    const sameDaemon: boolean = paired.baseUrl === this.text(QaqhState.BASE_URL).trim();
    this.put(QaqhState.PAIRED_LABEL,
      `已配对 ${paired.deviceId.substring(0, 8)}…（${paired.scope}）` +
        (sameDaemon ? '' : '，与当前地址不匹配，将用手填 token'));
  }

  /** 有配对凭证且地址一致时用它，否则退回手填 token（Admin 身份）。 */
  private activeToken(): string {
    const paired: PairedDevice | undefined = this.paired;
    if (paired !== undefined && paired.baseUrl === this.text(QaqhState.BASE_URL).trim()) {
      return paired.deviceToken;
    }
    return this.text(QaqhState.TOKEN).trim();
  }

  /** 设备身份才需要 session_attach（Admin 被 daemon 豁免归属）。 */
  usesDeviceIdentity(): boolean {
    const paired: PairedDevice | undefined = this.paired;
    return paired !== undefined && paired.baseUrl === this.text(QaqhState.BASE_URL).trim();
  }

  /** 用一次性 Admin token 换长期设备凭证（配对四面由 PairingClient 串好）。 */
  pairDevice(): void {
    if (this.boolValue(QaqhState.PAIRING)) {
      return;
    }
    const adminToken: string = this.text(QaqhState.TOKEN).trim();
    if (adminToken.length === 0) {
      this.statusText('配对需要桌面端 token（换到设备凭证后即可清空）');
      return;
    }
    this.put(QaqhState.PAIRING, true);
    const client: PairingClient = new PairingClient(
      new HttpTransport(10000, 15000, this.trust()),
      this.text(QaqhState.BASE_URL).trim());
    client.pairWithAdminToken(adminToken, 'harmony-phone').then((paired) => {
      const record: PairedDevice = new PairedDevice(paired.deviceId, paired.deviceToken,
        paired.scope, this.text(QaqhState.BASE_URL).trim());
      this.paired = record;
      if (this.accessStore !== undefined) {
        this.accessStore.saveDevice(record);
        this.accessStore.saveTrust(new TrustSettings(this.text(QaqhState.CA_PEM).trim(),
          this.boolValue(QaqhState.SKIP_VERIFY)));
      }
      // Admin 明文不留在页面状态里。
      this.put(QaqhState.TOKEN, '');
      this.refreshPairedLabel();
      this.statusText(`已配对（scope=${paired.scope}），此后只用设备凭证`);
      this.finishOnboarding();
    }).catch((error: Error) => {
      this.statusText(error instanceof PairingError
        ? `配对失败 ${error.code}: ${error.message}` : `配对失败: ${error.message}`);
    }).finally(() => {
      this.put(QaqhState.PAIRING, false);
    });
  }

  unpairDevice(): void {
    this.paired = undefined;
    if (this.accessStore !== undefined) {
      this.accessStore.clearDevice();
    }
    this.refreshPairedLabel();
    // 凭证清掉 = 回到开屏引导态（下次启动落在扫码配对首屏）。
    this.put(QaqhState.ONBOARD, true);
    this.statusText('已清除本机设备凭证（daemon 侧仍可吊销，需桌面端操作）');
  }

  /** 配对成功（扫码/手动）后收开屏引导并直接进入连接。 */
  private finishOnboarding(): void {
    this.put(QaqhState.ONBOARD, false);
    this.connect();
  }

  /** 开屏引导的「跳过」出口：不配对先进主壳，之后可在设置页完成。 */
  skipOnboarding(): void {
    this.put(QaqhState.ONBOARD, false);
  }

  /**
   * 扫码配对：调系统扫码 UI 消费桌面端配对二维码（spec §11 payload，含
   * base_url + 一次性 pairing_token），成功即换到长期设备凭证——免手填
   * Admin token。TLS 信任沿用本机现有设置：导入过 PEM 的走标准校验，
   * 都没有时自签端点会握手失败，按提示先导入 PEM（或调试时开跳过校验）。
   */
  pairViaScan(): void {
    if (this.boolValue(QaqhState.PAIRING) || this.context === undefined) {
      return;
    }
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.QR_CODE],
      enableMultiMode: false,
      enableAlbum: false
    };
    scanBarcode.startScanForResult(this.context, options).then(
      (result: scanBarcode.ScanResult) => {
        const payload: PairQrPayload = PairQrPayload.parse(result.originalValue);
        this.put(QaqhState.PAIRING, true);
        this.statusText(`识别到 ${payload.hostName.length > 0 ? payload.hostName : payload.baseUrl}，配对中…`);
        const transport: HttpTransport = new HttpTransport(10000, 15000, this.trust());
        PairingClient.pairWithQr(transport, payload, 'harmony-phone').then(
          (paired) => {
            const record: PairedDevice = new PairedDevice(paired.deviceId,
              paired.deviceToken, paired.scope, payload.baseUrl);
            this.paired = record;
            if (this.accessStore !== undefined) {
              this.accessStore.saveDevice(record);
              this.accessStore.saveTrust(new TrustSettings(
                this.text(QaqhState.CA_PEM).trim(), this.boolValue(QaqhState.SKIP_VERIFY)));
            }
            this.put(QaqhState.BASE_URL, payload.baseUrl);
            this.refreshPairedLabel();
            this.statusText(`已扫码配对（scope=${paired.scope}），凭证已入系统关键资产`);
            this.finishOnboarding();
          }).catch((error: Error) => {
          this.statusText(error instanceof PairingError
            ? `扫码配对失败 ${error.code}: ${error.message}` : `扫码配对失败: ${error.message}`);
        }).finally(() => {
          this.put(QaqhState.PAIRING, false);
        });
      }).catch((error: Error) => {
      // 用户取消扫码 / 相机权限拒绝：静默收场，不打成错误。
      this.statusText(`扫码未完成: ${error.message}`);
    });
  }

  saveTrustSettings(): void {
    if (this.accessStore !== undefined) {
      this.accessStore.saveTrust(new TrustSettings(this.text(QaqhState.CA_PEM).trim(),
        this.boolValue(QaqhState.SKIP_VERIFY)));
    }
  }

  // ---------- 连接生命周期 ----------

  isConnected(): boolean {
    return this.boolValue(QaqhState.CONNECTED);
  }

  connect(): void {
    if (this.activeToken().length === 0) {
      this.statusText('请填写 token 或先配对');
      return;
    }
    const instanceId: string = `harmony-ui-${Date.now()}`;
    this.listInstanceId = instanceId;
    this.saveTrustSettings();
    const client: RingingClient = this.makeRingingClient(instanceId);
    client.onLeaseLost((reason: string) => {
      // 列表 client 租约丢失：提示状态，下一轮 poll 里自动重开。
      this.statusText(`列表连接失效（${reason}），自动恢复中…`);
    });
    this.listClient = client;
    // 聚合 client 独立租约（M12）：列表/监视/聚合三条租约互不牵连——
    // 监视流重建不会动审批轮询的 attach 归属。
    if (this.approvalClient !== undefined) {
      this.approvalClient.close();
    }
    this.approvalInstanceId = `harmony-approve-${Date.now()}`;
    this.approvalClient = this.makeRingingClient(this.approvalInstanceId);
    this.approvalTargets.clear();
    this.listPoller.stop();
    this.statusText('连接中…');
    client.open().then(() => {
      this.put(QaqhState.CONNECTED, true);
      this.statusText('已连接，拉取会话列表…');
      this.refreshList();
      // 设置页的配置面随连接自动就绪（失败不打扰主流程，页内可手动重读）。
      this.loadDaemonConfig(true);
    }).catch((error: Error) => {
      this.statusText(`连接失败: ${error.message}`);
      this.listClient = undefined;
    });
  }

  /** 统一的 client 工厂：同一 baseUrl/token/信任设置，各自独立租约。 */
  private makeRingingClient(instanceId: string): RingingClient {
    return new RingingClient(new RingingClientConfig(
      this.text(QaqhState.BASE_URL).trim(), this.activeToken(), instanceId,
      new HttpTransport(10000, 120000, this.trust()), new SystemLeaseTimer(),
      this.usesDeviceIdentity()));
  }

  disconnect(): void {
    this.teardownMonitor();
    this.listPoller.stop();
    if (this.listClient !== undefined) {
      this.listClient.close();
      this.listClient = undefined;
    }
    this.approvalPoller.stop();
    this.approvalPollBusy = false;
    if (this.approvalClient !== undefined) {
      this.approvalClient.close();
      this.approvalClient = undefined;
    }
    this.approvalTargets.clear();
    this.remotePending.clear();
    this.sessionSuppressedUntil.clear();
    this.livePending = [];
    this.put(QaqhState.SESSION_ENTRIES, [] as RingingSessionListEntry[]);
    this.listEntries = [];
    this.rebuildCards();
    this.liveView.stop();
    this.put(QaqhState.CONNECTED, false);
    this.statusText('已断开');
  }

  /** 列表轮询一轮；无论成败都在末尾排下一轮（断开后不再排）。 */
  private refreshList(): void {
    const client = this.listClient;
    if (client === undefined || !this.isConnected()) {
      return;
    }
    const pollAgain = (): void => {
      if (this.isConnected()) {
        this.listPoller.start(LIST_POLL_MS, () => this.refreshList());
      }
    };
    const ensureOpen = (): Promise<void> => {
      if (client.stateValue() === RingingClientState.OPEN) {
        return Promise.resolve();
      }
      return client.open().then((): void => undefined);
    };
    ensureOpen().then(() => client.sessionList()).then((entries: RingingSessionListEntry[]) => {
      // 全量留底：徽标/模型名按 sessionId 反查，归档会话也要认得出名字。
      this.listEntries = entries;
      this.noteWireDrift(entries);
      // 后端不过滤归档与临时（子代理）会话，活跃面在端侧滤——UI 只吃这一份。
      const visible: RingingSessionListEntry[] = visibleSessions(entries);
      this.put(QaqhState.SESSION_ENTRIES, visible);
      if (this.text(QaqhState.STATUS).startsWith('已连接')) {
        this.statusText(`已连接（${visible.length} 个会话）`);
      }
      // 运行中会话集合变化 → 聚合轮询目标跟着增删（fire-and-forget）。
      this.syncApprovalTargets(visible);
    }).catch((error: Error) => {
      // 轮询失败不终止：lease 重开/网络抖动由下一轮兜底。
      void error;
    }).then(() => {
      pollAgain();
    });
  }

  /**
   * 键表外的 session.list 字段落一条 hilog。解析器宽容是对的（后端加法式演进
   * 不该让手机报错），静默不是：手抄件的失败模式是「某个功能永远显示缺省值」，
   * 没人发现。响一次，剩下的交给契约测试与协议层键表。
   */
  private noteWireDrift(entries: RingingSessionListEntry[]): void {
    if (this.wireDriftNoted) {
      return;
    }
    for (const entry of entries) {
      if (entry.unmodeledKeys.length > 0) {
        this.wireDriftNoted = true;
        hilog.warn(HILOG_DOMAIN, HILOG_TAG,
          `session.list 键表外字段：${entry.unmodeledKeys.join(',')}`);
        return;
      }
    }
  }

  /** 创建会话：control 频道 session_create（唯一允许无 session_id 的命令）。 */
  createSession(): void {
    const client = this.listClient;
    if (client === undefined || this.boolValue(QaqhState.CREATING)) {
      return;
    }
    this.put(QaqhState.CREATING, true);
    const envelope: RingingV2CommandEnvelope = RingingV2CommandEnvelope.create(
      newCommandId(), this.listInstanceId, client.sessionHeader(), '',
      ControlCommands.sessionCreate(false));
    client.sendCommand(envelope).then(() => {
      this.statusText('会话创建命令已受理');
      setTimeout((): void => {
        this.put(QaqhState.CREATING, false);
        if (this.isConnected()) {
          this.refreshList();
        }
      }, 800);
    }).catch((error: Error) => {
      this.put(QaqhState.CREATING, false);
      this.statusText(`创建会话失败: ${error.message}`);
    });
  }

  /**
   * 设备身份下把桌面端已有的会话归属到本端：归属按 client_session_id 记，
   * 用列表 client 的 lease attach（会话页的 monitor client 会再 attach 一次）。
   */
  attachKnownSession(sessionId: string): void {
    const client = this.listClient;
    if (client === undefined) {
      this.statusText('请先连接 daemon');
      return;
    }
    this.statusText(`归属会话 ${sessionId.substring(0, 8)}… 中`);
    client.attachSession(sessionId).then(() => {
      this.statusText('已归属，刷新列表…');
      this.refreshList();
    }).catch((error: Error) => {
      this.statusText(`归属失败: ${error.message}`);
    });
  }

  // ---------- 会话监视 ----------

  enterSession(sessionId: string): void {
    if (this.listClient === undefined || this.context === undefined) {
      return;
    }
    this.teardownMonitor();
    // 该会话的审批改由实时流接管：先撤聚合卡片与抑制窗口（单一数据源）。
    this.approvalTargets.delete(sessionId);
    this.sessionSuppressedUntil.delete(sessionId);
    this.dropRemoteOfSession(sessionId);
    this.monitorInstanceId = `harmony-stream-${Date.now()}`;
    const monitorClient: RingingClient = new RingingClient(new RingingClientConfig(
      this.text(QaqhState.BASE_URL).trim(), this.activeToken(), this.monitorInstanceId,
      new HttpTransport(10000, 120000, this.trust()), new SystemLeaseTimer(),
      this.usesDeviceIdentity()));
    this.monitorClient = monitorClient;
    // cursor store 按会话分 key：log_id 不一致时 monitor 自动回退快照基线。
    this.cursorStore = new PreferencesCursorStore(this.context, sessionId);
    this.interactionCenter = new InteractionCenter(monitorClient,
      new LambdaInteractionListener(
        (pending: PendingInteractionView[]) => this.onPendingChanged(pending),
        (interactionId: string, detail: string) => {
          this.statusText(`交互已生效（${detail}）`);
          this.cancelNotice(interactionId);
        },
        (interactionId: string, detail: string) => {
          void interactionId;
          this.statusText(`应答失败: ${detail}`);
        }));
    this.monitor = new SessionMonitor(monitorClient,
      new HttpStreamConnection(this.trust()), new SystemLeaseTimer(),
      new LambdaListener(
        (snapshot: RingingV2Bootstrap) => this.onBootstrap(snapshot),
        (envelope: RingingV2EventEnvelope, payload: ProjectionPayload) =>
          this.onEnvelope(envelope, payload),
        (reset: RingingV2ResetRequired) => this.onReset(reset),
        (status: string) => this.onStatus(status),
        (error: ProtocolError) => this.onProtocolError(error)
      ), this.cursorStore);
    this.put(QaqhState.ACTIVE_SESSION, sessionId);
    this.put(QaqhState.ACTIVE_TITLE, this.sessionLabelOf(sessionId));
    this.put(QaqhState.ACTIVE_MODEL, this.sessionModelOf(sessionId));
    this.transcript.reset();
    this.rowsSource.attach(this.transcript);
    this.setStatus();
    this.applySeat(undefined);
    this.statusText('建立监视流…');
    this.cursorStore.prime().then(() => {
      if (this.monitor !== undefined) {
        this.monitor.start(sessionId);
      }
    });
  }

  exitSession(): void {
    this.teardownMonitor();
    this.statusText('已返回会话列表');
    this.refreshList();
  }

  private teardownMonitor(): void {
    if (this.timelineStream !== undefined) {
      this.timelineStream.stop();
      this.timelineStream = undefined;
    }
    this.canLoadOlder(false);
    this.olderCursor = -1;
    if (this.monitor !== undefined) {
      this.monitor.stop();
      this.monitor = undefined;
    }
    this.interactionCenter = undefined;
    this.cursorStore = undefined;
    this.monitorClient = undefined;
    this.interactionBodies.clear();
    this.livePending = [];
    // 实时卡片清场，但聚合的远程卡片保留（跨会话审批中心不随退出会话清空）。
    this.rebuildCards();
    this.transcript.reset();
    this.rowsSource.attach(this.transcript);
    this.setStatus();
    this.put(QaqhState.ACTIVE_SESSION, '');
    this.put(QaqhState.ACTIVE_TITLE, '');
    this.put(QaqhState.ACTIVE_MODEL, '');
    this.put(QaqhState.TURN_ACTIVE, false);
    this.turnLiveShown = false;
    // stop() 收两条实况窗（审批 + 回合），审批提醒走通知不受影响。
    this.liveView.stop();
  }

  // ---------- 监视回调 ----------

  private onBootstrap(snapshot: RingingV2Bootstrap): void {
    this.statusText(`已连接（revision ${snapshot.controlState.revision}）`);
    if (snapshot.controlState.driver !== undefined) {
      this.applySeat(snapshot.controlState.driver.holder);
    }
    this.loadTranscript();
    if (this.interactionCenter !== undefined) {
      this.interactionCenter.setSessionId(snapshot.sessionId);
      this.interactionCenter.ingestBootstrap(snapshot);
    }
  }

  /**
   * 席位提示：conversation 频道是 driver-gated，桌面端持席时手机发消息会被
   * `not_driver` 拒。先说明比静默重试友好（认领仍由 submitConversation 按需做）。
   */
  private applySeat(holder: string | undefined): void {
    if (holder === undefined || holder.length === 0) {
      this.put(QaqhState.SEAT_TEXT, '驱动席空闲：可直接输入');
      return;
    }
    const shown: string = holder.length > 12 ? `${holder.substring(0, 12)}…` : holder;
    this.put(QaqhState.SEAT_TEXT, `驱动席由 ${shown} 持有`);
  }

  private onEnvelope(envelope: RingingV2EventEnvelope, payload: ProjectionPayload): void {
    if (this.interactionCenter !== undefined) {
      this.interactionCenter.ingestEnvelope(envelope, payload);
    }
    if (payload.driverChanged !== undefined) {
      this.applySeat(payload.driverChanged.holder);
    }
    const drift: string = payload.unrecognizedControlKind.length > 0
      ? payload.unrecognizedControlKind : payload.unrecognizedTimelineKind;
    if (drift.length > 0) {
      // 漂移要看得见，但不再断流（曾经一个 driver_changed 把整条监视流打死）。
      this.statusText(`未识别的事件变体：${drift}（已忽略，流未断）`);
    }
  }

  private onReset(reset: RingingV2ResetRequired): void {
    this.transcript.reset();
    this.rowsSource.attach(this.transcript);
    this.setStatus();
    this.put(QaqhState.TURN_ACTIVE, false);
    this.statusText(`快照重置（${reset.reason}），重建中…`);
  }

  private onStatus(status: string): void {
    if (status === MonitorStatus.LIVE) {
      this.statusText('事件流已连接');
    } else if (status === MonitorStatus.BOOTSTRAPPING) {
      this.statusText('拉取快照…');
    } else if (status === MonitorStatus.RENEGOTIATING) {
      this.statusText('租约失效，重新协商…');
      // 正文流与监视器共用一个 client：client 一出 open 态，它自己那条重连定时器
      // 到点就会撞 requireOpen。先解武装，下一次 bootstrap 负责重建
      // （onBootstrap → loadTranscript → startTimelineStream）。
      if (this.timelineStream !== undefined) {
        this.timelineStream.stop();
        this.timelineStream = undefined;
      }
    } else if (status === MonitorStatus.STOPPED) {
      this.statusText('已停止');
    }
  }

  private onProtocolError(error: ProtocolError): void {
    this.statusText(`协议错误: ${error.message}`);
  }

  private canLoadOlder(value: boolean): void {
    this.put(QaqhState.CAN_LOAD_OLDER, value);
  }

  // ---------- 对话输入（conversation 频道） ----------

  sendInput(text: string, onAccepted: () => void): void {
    const trimmed: string = text.trim();
    if (trimmed.length === 0 || this.boolValue(QaqhState.SENDING)) {
      return;
    }
    this.put(QaqhState.SENDING, true);
    this.submitConversation(ConversationCommands.sendMessage(trimmed), () => {
      // 输入文本归页面局部态：accepted 回执后由页面自己清空。
      onAccepted();
    }).then((): void => {
      this.put(QaqhState.SENDING, false);
    });
  }

  cancelTurn(): void {
    if (this.boolValue(QaqhState.SENDING)) {
      return;
    }
    this.put(QaqhState.SENDING, true);
    this.submitConversation(ConversationCommands.cancel(''), () => {
      this.statusText('已发送停止命令');
    }).then((): void => {
      this.put(QaqhState.SENDING, false);
    });
  }

  /**
   * conversation 频道命令提交（send/cancel 共用，driver-gated）：
   * 席位空闲时直接受理；被 `not_driver` 拒 → 认领驱动席后重试（≤3 轮）；
   * `driver_busy` 如实上报，不抢席。epoch 不随命令携带（v1 语义）。
   */
  private async submitConversation(command: RingingCommand,
    onSuccess: () => void): Promise<void> {
    const client = this.monitorClient;
    const monitor = this.monitor;
    if (client === undefined || monitor === undefined) {
      return;
    }
    const sessionId: string = monitor.sessionIdValue();
    const attempts: number = 3;
    for (let i = 0; i < attempts; i++) {
      // 每次重试都换新 command_id：not_driver 的拒绝回执按 id 记忆，复用 id
      // 会让重试撞到 existing=rejected 而不是真正重新执行。
      const envelope: RingingV2CommandEnvelope = RingingV2CommandEnvelope.create(
        newCommandId(), this.monitorInstanceId, client.sessionHeader(), sessionId,
        command);
      let ack: RingingV2CommandAck;
      try {
        ack = await client.sendCommand(envelope);
      } catch (error) {
        this.statusText(`发送失败: ${(error as Error).message}`);
        return;
      }
      if (ack.status === 'accepted') {
        onSuccess();
        this.statusText('已发送，等待回合开始…');
        return;
      }
      if (ack.code !== 'not_driver') {
        this.statusText(`发送被拒: ${ack.code ?? ack.message ?? 'unknown'}`);
        return;
      }
      try {
        const claim = await client.driverClaim(sessionId);
        if (!claim.accepted) {
          this.statusText('桌面端正持有该会话的驱动席，无法从本机输入');
          return;
        }
      } catch (error) {
        this.statusText(`获取驱动席失败: ${(error as Error).message}`);
        return;
      }
    }
    this.statusText('驱动席认领未及时生效，请重试');
  }

  // ---------- 审批（监视会话：实时流） ----------

  private onPendingChanged(pending: PendingInteractionView[]): void {
    this.livePending = pending;
    for (const item of pending) {
      this.ensureInteractionBody(item);
    }
    this.rebuildCards();
    const first: PendingInteractionView | undefined =
      pending.length > 0 ? pending[0] : undefined;
    const summary: string = first !== undefined
      ? approvalSummary(first, this.interactionBodies.get(first.interactionId)) : '';
    this.liveView.updatePendingCount(pending.length, summary);
  }

  /**
   * CARDS = 实时流（监视会话）+ 聚合轮询（其它运行中会话）的合并卡片列表。
   * live 卡片在前（用户正在看的会话优先），remote 卡片带会话徽标。
   */
  private rebuildCards(): void {
    const cards: ApprovalCardView[] = [];
    for (const item of this.livePending) {
      cards.push(new ApprovalCardView(item, this.interactionBodies.get(item.interactionId)));
    }
    this.remotePending.forEach((item: PendingInteractionView) => {
      cards.push(new ApprovalCardView(item, this.interactionBodies.get(item.interactionId),
        this.sessionLabelOf(item.sessionId)));
    });
    this.put(QaqhState.CARDS, cards);
  }

  /** 会话徽标文案：G2 展示口径（title → cwd 尾段 → 短 id）。 */
  private sessionLabelOf(sessionId: string): string {
    for (const entry of this.listEntries) {
      if (entry.sessionId === sessionId) {
        return entry.displayTitle();
      }
    }
    return sessionId.substring(0, 8);
  }

  /** 会话模型名（详情顶栏副标识；列表尚未返回或已下线时为空串）。 */
  private sessionModelOf(sessionId: string): string {
    for (const entry of this.listEntries) {
      if (entry.sessionId === sessionId && entry.model !== undefined) {
        return entry.model;
      }
    }
    return '';
  }

  private cardTitle(item: PendingInteractionView,
    body: InteractionBody | undefined): string {
    if (item.kind === 'permission' && body !== undefined && body.permission !== undefined) {
      return `权限请求：${body.permission.toolName}（风险 ${body.permission.risk}）`;
    }
    if (item.kind === 'plan' && body !== undefined && body.plan !== undefined) {
      return `计划审核（${body.plan.reviewType}）`;
    }
    if (item.kind === 'ask' && body !== undefined && body.ask !== undefined) {
      return `提问（${body.ask.questions.length} 个问题）`;
    }
    return `交互请求（${item.kind}）`;
  }

  private publishNotice(item: PendingInteractionView): void {
    const body: InteractionBody | undefined =
      this.interactionBodies.get(item.interactionId);
    this.notifier.publishApproval(item, approvalSummary(item, body),
      this.cardTitle(item, body));
  }

  private cancelNotice(interactionId: string): void {
    // 通知 id 只依赖 interactionId，撤下无需 pending 中的原对象。
    const ghost = new PendingInteractionView(interactionId, '', '', '', undefined, 0);
    this.notifier.cancelApproval(ghost);
  }

  respond(item: PendingInteractionView, approved: boolean): void {
    if (this.interactionCenter === undefined) {
      return;
    }
    if (approved) {
      // 批准类动作过本地门禁（生物→PIN→直通）；拒绝不设门禁。
      this.authenticator.authenticate('批准前身份验证')
        .then(() => {
          this.doRespond(item, approved);
        })
        .catch((error: Error) => {
          this.statusText(`鉴权未通过: ${error.message}`);
        });
      return;
    }
    this.doRespond(item, approved);
  }

  private doRespond(item: PendingInteractionView, approved: boolean): void {
    if (item.remote) {
      this.respondRemote(item, approved ? ApprovalDecision.APPROVE : ApprovalDecision.REJECT);
      return;
    }
    const center = this.interactionCenter;
    if (center === undefined) {
      return;
    }
    if (item.kind === 'permission') {
      center.respondPermission(item, approved, false);
    } else if (item.kind === 'plan') {
      center.respondPlan(item, approved, '', false);
    }
  }

  answerAsk(item: PendingInteractionView, answers: AskAnswer[]): void {
    if (item.remote) {
      this.respondRemoteAsk(item, answers, false);
      return;
    }
    if (this.interactionCenter === undefined) {
      return;
    }
    this.interactionCenter.respondAsk(item, answers);
  }

  dismiss(item: PendingInteractionView): void {
    if (item.remote) {
      this.respondRemoteAsk(item, [], true);
      return;
    }
    if (this.interactionCenter === undefined) {
      return;
    }
    this.interactionCenter.dismissAsk(item);
  }

  /**
   * 远程（非监视会话）审批应答。路由按身份分叉，**两条路都以条目自带的
   * sessionId 为准**（防串频的根本约束）：
   * - device：challenge 应答端点——challenge 与会话绑定、一次性消费，
   *   票错会话被服务端 approval_scope_violation 拒绝；
   * - admin（手填 token）：canonical 命令通道，envelope.sessionId = 条目会话。
   */
  private respondRemote(item: PendingInteractionView, decision: string): void {
    const client = this.approvalClient;
    if (client === undefined || client.stateValue() !== RingingClientState.OPEN) {
      this.statusText('连接不可用，无法应答其它会话的审批');
      return;
    }
    if (this.usesDeviceIdentity()) {
      client.approvalsRespond(item.sessionId, item.wireId, decision, undefined)
        .then(() => this.onRemoteResponded(item))
        .catch((error: Error) => {
          this.statusText(`应答失败（${this.sessionLabelOf(item.sessionId)}）: ${error.message}`);
        });
      return;
    }
    let command: RingingCommand;
    if (item.kind === 'permission') {
      command = ToolCommands.toolPermissionRespond(item.wireId,
        decision === ApprovalDecision.APPROVE || decision === ApprovalDecision.TRUST, false);
    } else {
      command = ControlCommands.planReviewRespond(item.wireId,
        decision === ApprovalDecision.APPROVE, '', false);
    }
    this.sendRemoteCommand(client, item, command);
  }

  /** 远程 ask：submit（带答案）与 dismiss 两路。 */
  private respondRemoteAsk(item: PendingInteractionView, answers: AskAnswer[],
    dismiss: boolean): void {
    const client = this.approvalClient;
    if (client === undefined || client.stateValue() !== RingingClientState.OPEN) {
      this.statusText('连接不可用，无法应答其它会话的审批');
      return;
    }
    if (this.usesDeviceIdentity()) {
      if (dismiss) {
        client.approvalsRespond(item.sessionId, item.wireId, ApprovalDecision.DISMISS,
          undefined).then(() => this.onRemoteResponded(item))
          .catch((error: Error) => {
            this.statusText(`应答失败（${this.sessionLabelOf(item.sessionId)}）: ${error.message}`);
          });
        return;
      }
      const wireAnswers: Array<Object> = [];
      for (const answer of answers) {
        wireAnswers.push(answer.toWire());
      }
      const payload: Record<string, Object> = { 'answers': wireAnswers };
      client.approvalsRespond(item.sessionId, item.wireId, ApprovalDecision.SUBMIT, payload)
        .then(() => this.onRemoteResponded(item))
        .catch((error: Error) => {
          this.statusText(`应答失败（${this.sessionLabelOf(item.sessionId)}）: ${error.message}`);
        });
      return;
    }
    const command: RingingCommand = dismiss
      ? ControlCommands.interactionAskDismiss(item.wireId)
      : ControlCommands.interactionAskRespond(item.wireId, answers);
    this.sendRemoteCommand(client, item, command);
  }

  /** admin 身份的远程应答走命令通道：envelope.sessionId = 条目会话。 */
  private sendRemoteCommand(client: RingingClient, item: PendingInteractionView,
    command: RingingCommand): void {
    const envelope: RingingV2CommandEnvelope = RingingV2CommandEnvelope.create(
      newCommandId(), this.approvalInstanceId, client.sessionHeader(), item.sessionId,
      command);
    client.sendCommand(envelope).then(() => {
      this.onRemoteResponded(item);
    }).catch((error: Error) => {
      this.statusText(`应答失败（${this.sessionLabelOf(item.sessionId)}）: ${error.message}`);
    });
  }

  /** 远程应答成功：本地立刻摘卡 + 抑制该会话一个轮询窗口（防投影落地闪回）。 */
  private onRemoteResponded(item: PendingInteractionView): void {
    this.sessionSuppressedUntil.set(item.sessionId, Date.now() + RESPOND_SUPPRESS_MS);
    this.remotePending.delete(item.interactionId);
    this.cancelNotice(item.interactionId);
    this.rebuildCards();
    this.statusText(`已应答（${this.sessionLabelOf(item.sessionId)}）`);
  }

  // ---------- 审批聚合轮询（M12：其它运行中会话） ----------

  /**
   * session.list 每轮照会聚合目标：running 会话进集合（device 身份先 attach——
   * /approvals 对设备要求租约归属该会话），退出的会话连同其远程卡片清掉。
   * 当前监视会话**不进**集合：它的审批由 InteractionCenter 实时维护。
   *
   * 归档/临时（子代理）会话整条跳过：它们不该被手机去轮询审批，也不该在用户
   * 看不见的会话上挂授权卡。调用方传全量或已过滤集都成立（此处谓词是准绳）。
   */
  private syncApprovalTargets(entries: RingingSessionListEntry[]): void {
    const client = this.approvalClient;
    if (client === undefined) {
      return;
    }
    const active: string = this.text(QaqhState.ACTIVE_SESSION);
    const wanted: Set<string> = new Set();
    for (const entry of entries) {
      if (entry.isListable() && entry.running && entry.sessionId !== active) {
        wanted.add(entry.sessionId);
      }
    }
    // 清退：不再运行 / 转为监视中的会话。
    const retired: string[] = [];
    this.approvalTargets.forEach((sid: string) => {
      if (!wanted.has(sid)) {
        retired.push(sid);
      }
    });
    for (const sid of retired) {
      this.approvalTargets.delete(sid);
      this.dropRemoteOfSession(sid);
    }
    const ensureOpen: Promise<void> = client.stateValue() === RingingClientState.OPEN
      ? Promise.resolve()
      : client.open().then((): void => {
        // 重开 = 新 client_session_id，旧 attach 全部作废（M6 契约）。
        this.approvalTargets.clear();
      });
    ensureOpen.then(() => {
      if (this.approvalClient === undefined) {
        return;
      }
      const attaches: Promise<void>[] = [];
      wanted.forEach((sid: string) => {
        if (this.approvalTargets.has(sid)) {
          return;
        }
        if (!this.usesDeviceIdentity()) {
          // admin 无归属要求，直接可轮询。
          this.approvalTargets.add(sid);
          return;
        }
        attaches.push(client.attachSession(sid).then((): void => {
          this.approvalTargets.add(sid);
        }).catch((): void => {
          // attach 失败（会话刚结束等）：本轮跳过，下轮 session.list 重新决策。
        }));
      });
      Promise.all(attaches).then(() => this.startApprovalLoop());
    }).catch((error: Error) => {
      void error; // 聚合面连不上不打扰主流程；照常重排，下轮再试。
      this.startApprovalLoop();
    });
  }

  private startApprovalLoop(): void {
    if (!this.isConnected() || this.approvalClient === undefined) {
      return;
    }
    if (this.approvalPollBusy) {
      // 一轮在飞：它会自己在收尾时重排下一轮，这里不重复排。
      return;
    }
    this.approvalPoller.stop();
    this.approvalPoller.start(APPROVAL_POLL_MS, () => this.pollApprovals());
  }

  /** 一轮聚合：串行打各目标会话的 /approvals（单飞，不与上一轮重叠）。 */
  private pollApprovals(): void {
    if (this.approvalPollBusy || !this.isConnected() || this.approvalClient === undefined) {
      return;
    }
    const client = this.approvalClient;
    if (client.stateValue() !== RingingClientState.OPEN) {
      // 聚合租约丢了：走 sync 重开 + 重放 attach（targets 随新租约清空）。
      this.syncApprovalTargets(this.listEntries);
      return;
    }
    const active: string = this.text(QaqhState.ACTIVE_SESSION);
    const now: number = Date.now();
    const targets: string[] = [];
    this.approvalTargets.forEach((sid: string) => {
      if (sid === active) {
        return;
      }
      const until: number | undefined = this.sessionSuppressedUntil.get(sid);
      if (until !== undefined && until > now) {
        return;
      }
      targets.push(sid);
    });
    if (targets.length === 0) {
      this.startApprovalLoop();
      return;
    }
    this.approvalPollBusy = true;
    let chain: Promise<void> = Promise.resolve();
    for (const sid of targets) {
      chain = chain.then(() => {
        return client.approvalsList(sid).then((snapshot) => {
          this.ingestApprovalSnapshot(sid, snapshot);
        }).catch((error: Error) => {
          void error; // 单会话失败不拖垮整轮（租约过期等由下轮重试）。
        });
      });
    }
    chain.then(() => {
      this.approvalPollBusy = false;
      this.startApprovalLoop();
    });
  }

  /** 快照 → 远程条目：整体替换该会话的旧条目（resolved/expired 自然消失）。 */
  private ingestApprovalSnapshot(sessionId: string,
    snapshot: RingingApprovalsSnapshot): void {
    const prefix: string = `${sessionId}#`;
    const previous: Set<string> = new Set();
    this.remotePending.forEach((_: PendingInteractionView, key: string) => {
      if (key.startsWith(prefix)) {
        previous.add(key);
      }
    });
    const arrived: PendingInteractionView[] = [];
    for (const item of snapshot.items) {
      const key: string = `${sessionId}#${item.respondId}`;
      if (!previous.has(key)) {
        arrived.push(new PendingInteractionView(key, '', '', approvalViewKind(item.kind),
          item.details, 0, sessionId, item.respondId, true));
      }
    }
    const departed: string[] = [];
    previous.forEach((key: string) => {
      if (!arrived.some((view: PendingInteractionView) => view.interactionId === key)) {
        departed.push(key);
      }
    });
    for (const key of departed) {
      this.remotePending.delete(key);
      this.cancelNotice(key);
    }
    for (const view of arrived) {
      this.remotePending.set(view.interactionId, view);
    }
    if (arrived.length > 0 || departed.length > 0) {
      this.rebuildCards();
    }
    for (const view of arrived) {
      this.ensureRemoteBody(view);
    }
  }

  /** 远程条目正文：details 已是 interaction body 形状，补 kind 鉴别键后复用解析。 */
  private ensureRemoteBody(item: PendingInteractionView): void {
    if (this.interactionBodies.has(item.interactionId) || item.request === undefined) {
      this.publishNotice(item);
      return;
    }
    const merged: Record<string, Object> = { 'kind': item.kind };
    const source = item.request as Record<string, Object>;
    for (const key of Object.keys(source)) {
      const value: Object | undefined = source[key];
      if (value !== undefined) {
        merged[key] = value;
      }
    }
    try {
      this.interactionBodies.set(item.interactionId, InteractionBody.parse(JSON.stringify(merged)));
    } catch (error) {
      void error; // 正文畸形：卡片按「暂不支持的交互形态」降级。
    }
    this.rebuildCards();
    this.publishNotice(item);
  }

  private dropRemoteOfSession(sessionId: string): void {
    const prefix: string = `${sessionId}#`;
    const doomed: string[] = [];
    this.remotePending.forEach((_: PendingInteractionView, key: string) => {
      if (key.startsWith(prefix)) {
        doomed.push(key);
      }
    });
    for (const key of doomed) {
      this.remotePending.delete(key);
      this.cancelNotice(key);
    }
    if (doomed.length > 0) {
      this.rebuildCards();
    }
  }

  /** 拉取/解析交互正文（inline 直取；ref 走 content 端点）。 */
  private ensureInteractionBody(item: PendingInteractionView): void {
    if (this.interactionBodies.has(item.interactionId)) {
      return;
    }
    const request = item.request;
    if (request === undefined) {
      this.publishNotice(item);
      return;
    }
    if (request instanceof ContentValueInline) {
      this.interactionBodies.set(item.interactionId,
        InteractionBody.parse(request.text));
      this.rebuildCards();
      this.publishNotice(item);
      return;
    }
    if (request instanceof ContentValueRef && this.monitor !== undefined) {
      const refId: string = request.contentRef;
      this.monitor.fetchContent(refId).then((content: ContentFetch) => {
        this.interactionBodies.set(item.interactionId,
          InteractionBody.parse(content.body));
        this.rebuildCards();
        this.publishNotice(item);
      }).catch((error: Error) => {
        void error; // 拉取失败保留「正文拉取中…」占位，不做重试风暴。
      });
      return;
    }
    this.publishNotice(item);
  }

  // ---------- 正文（Timeline 通道） ----------

  /**
   * 进会话先取一页快照把历史 seed 出来，再从快照的 `watermark` 起订增量。
   * 正文与历史只在 `/timeline/events`（M7 真机定性），投影流管审批与驱动席。
   */
  private loadTranscript(): void {
    const client = this.monitorClient;
    const sessionId: string = this.text(QaqhState.ACTIVE_SESSION);
    if (client === undefined || sessionId.length === 0 || this.timelineLoading) {
      return;
    }
    this.timelineLoading = true;
    client.timelineSnapshot(sessionId, TRANSCRIPT_PAGE_LIMIT)
      .then((page: TimelineSnapshotResponse) => {
        if (sessionId !== this.text(QaqhState.ACTIVE_SESSION)) {
          return; // 会话已切走，旧页直接丢弃
        }
        this.transcript.seed(page.turns);
        this.olderCursor = page.oldestIndex();
        this.canLoadOlder(page.hasMore);
        this.flushNow();
        this.statusText(page.hasMore || page.truncatedBefore
          ? `已载入最近 ${page.turns.length}/${page.totalTurns} 个回合（更早的在归档里）`
          : `已载入 ${page.turns.length} 个回合`);
        this.startTimelineStream(page.watermark, page.serverEpoch);
      })
      .catch((error: Error) => {
        this.statusText(`正文载入失败: ${error.message}`);
      })
      .finally(() => {
        this.timelineLoading = false;
      });
  }

  /**
   * 每次（重新）协商都要**重建**正文流：旧流的 client_session_id 随旧租约一起
   * 作废，只重设水位会让它静默冻在吊销前的那条连接上。
   */
  private startTimelineStream(watermark: number, epoch: string): void {
    const client = this.monitorClient;
    const sessionId: string = this.text(QaqhState.ACTIVE_SESSION);
    if (client === undefined || sessionId.length === 0) {
      return;
    }
    const stale: TimelineStream | undefined = this.timelineStream;
    if (stale !== undefined) {
      stale.stop();
      this.timelineStream = undefined;
    }
    const created: TimelineStream = new TimelineStream(sessionId,
      new HttpStreamConnection(this.trust()), new SystemLeaseTimer(),
      (): StreamEndpoint => new StreamEndpoint(client.baseUrlValue(),
        client.sessionHeadersValue()),
      new LambdaTimelineListener(
        (entry: TimelineEntry) => this.onTimelineEntry(entry),
        (expectedSeq: number, actualSeq: number) => {
          this.statusText(`正文序列空洞（期望 ${expectedSeq}，实到 ${actualSeq}），重取快照…`);
          this.loadTranscript();
        },
        (text: string) => {
          this.statusText(text);
        }),
      watermark, epoch);
    this.timelineStream = created;
    created.start();
  }

  private onTimelineEntry(entry: TimelineEntry): void {
    // O1：增量只动模型（字符串追加 + 脏标记）；setState 由 FLUSH_MS 节拍合并。
    this.transcript.applyEntry(entry);
    const drift: string = this.transcript.unrecognizedEventValue();
    if (drift.length > 0) {
      this.statusText(`未识别的正文事件：${drift}（已忽略，流未断）`);
    }
    this.scheduleFlush();
  }

  private scheduleFlush(): void {
    if (this.flushScheduled) {
      return;
    }
    this.flushScheduled = true;
    setTimeout((): void => {
      this.flushScheduled = false;
      this.flushNow();
    }, FLUSH_MS);
  }

  private flushNow(): void {
    this.setStatus();
    const turnActive: boolean = this.transcript.turnActiveValue();
    this.put(QaqhState.TURN_ACTIVE, turnActive);
    // 实况窗「电脑正在干活」胶囊：只在状态翻转时触碰（流式期间 flush 很频）。
    if (turnActive !== this.turnLiveShown) {
      this.turnLiveShown = turnActive;
      void this.liveView.updateTurnActive(turnActive,
        turnActive ? '回合进行中，点按查看' : '');
    }
  }

  /** 更早的历史：`before_index` 深翻页，接到已渲条目前面。 */
  loadOlderTurns(): void {
    const client = this.monitorClient;
    if (client === undefined || this.timelineLoading || this.olderCursor < 0) {
      return;
    }
    this.timelineLoading = true;
    client.timelineSnapshot(this.text(QaqhState.ACTIVE_SESSION), TRANSCRIPT_PAGE_LIMIT,
      this.olderCursor)
      .then((page: TimelineSnapshotResponse) => {
        this.transcript.prependOlder(page.turns);
        this.flushNow();
        this.olderCursor = page.hasMore ? page.oldestIndex() : -1;
        this.canLoadOlder(page.hasMore);
      })
      .catch((error: Error) => {
        this.statusText(`更早历史载入失败: ${error.message}`);
      })
      .finally(() => {
        this.timelineLoading = false;
      });
  }

  toggleRow(rowId: string): void {
    this.transcript.toggleExpanded(rowId);
    // 展开/折叠立即生效（用户动作不该等下一个 flush 窗口）。
    this.rowsSource.sync();
  }

  // ---------- daemon 配置面（BYOK 六字段 + profile，服务面 RPC） ----------

  /** 最近一次 config.load 的权威快照：保存时只把**改动过**的字段放进补丁。 */
  private configSnapshot: RingingConfigDto | undefined;

  private cfgStatus(text: string): void {
    this.put(QaqhState.CFG_STATUS, text);
  }

  /**
   * `config.load`：读 daemon 配置进 AppStorage（设置页渲染）。
   * `force=false` 时已加载过就跳过（aboutToAppear 幂等）；连接成功后强制刷新。
   */
  loadDaemonConfig(force: boolean): void {
    if (!force && this.boolValue(QaqhState.CFG_LOADED)) {
      return;
    }
    const client = this.listClient;
    if (client === undefined || client.stateValue() !== RingingClientState.OPEN) {
      this.cfgStatus('先连接 daemon 才能读取配置');
      return;
    }
    client.configLoad().then((dto: RingingConfigDto) => {
      this.configSnapshot = dto;
      this.put(QaqhState.CFG_MODEL, dto.model);
      this.put(QaqhState.CFG_BASE_URL, dto.baseUrl);
      this.put(QaqhState.CFG_WIRE, dto.wire);
      this.put(QaqhState.CFG_MAX_TOKENS, String(dto.maxTokens));
      this.put(QaqhState.CFG_CONTEXT_LENGTH, String(dto.contextLength));
      this.put(QaqhState.CFG_EFFORT, dto.reasoningEffort);
      // 掩码语义：'****' = 已配置；密钥本体永不出 daemon。
      this.put(QaqhState.CFG_API_KEY_LABEL,
        dto.apiKey.length > 0 ? `已配置（${dto.apiKey}）` : '未配置');
      this.put(QaqhState.CFG_NEW_API_KEY, '');
      this.put(QaqhState.CFG_PROFILES, dto.profiles);
      this.put(QaqhState.CFG_ACTIVE_PROFILE, dto.activeProfile);
      this.put(QaqhState.CFG_SELECTED_PROFILE, dto.activeProfile);
      this.put(QaqhState.CFG_LOADED, true);
      this.cfgStatus(`已读取（当前档案 ${dto.activeProfile}，wire ${dto.wire}）`);
    }).catch((error: Error) => {
      this.cfgStatus(`读取失败: ${error.message}`);
    });
  }

  /**
   * `config.save`：把设置页里**与快照不同**的字段合成 Merge Patch 发上去。
   * 数字字段留空 = 不动；apiKey 只在输入了新值时发送（掩码/空串 = 保持现值）。
   */
  saveDaemonConfig(): void {
    if (this.boolValue(QaqhState.CFG_SAVING)) {
      return;
    }
    const client = this.listClient;
    const snapshot = this.configSnapshot;
    if (client === undefined || snapshot === undefined) {
      this.cfgStatus('先读取配置再保存');
      return;
    }
    const patch: RingingConfigPatch = new RingingConfigPatch();
    let changed: boolean = false;
    const model: string = this.text(QaqhState.CFG_MODEL).trim();
    if (model.length > 0 && model !== snapshot.model) {
      patch.model = model;
      changed = true;
    }
    const endpoint: string = this.text(QaqhState.CFG_BASE_URL).trim();
    if (endpoint.length > 0 && endpoint !== snapshot.baseUrl) {
      patch.baseUrl = endpoint;
      changed = true;
    }
    const wire: string = this.text(QaqhState.CFG_WIRE);
    if (ConfigWire.isValid(wire) && wire !== snapshot.wire) {
      patch.wire = wire;
      changed = true;
    }
    const effort: string = this.text(QaqhState.CFG_EFFORT);
    if (effort.length > 0 && effort !== snapshot.reasoningEffort) {
      patch.reasoningEffort = effort;
      changed = true;
    }
    const maxTokens: number = this.numberField(QaqhState.CFG_MAX_TOKENS);
    if (maxTokens > 0 && maxTokens !== snapshot.maxTokens) {
      patch.maxTokens = maxTokens;
      changed = true;
    }
    const contextLength: number = this.numberField(QaqhState.CFG_CONTEXT_LENGTH);
    if (contextLength > 0 && contextLength !== snapshot.contextLength) {
      patch.contextLength = contextLength;
      changed = true;
    }
    const newKey: string = this.text(QaqhState.CFG_NEW_API_KEY).trim();
    if (newKey.length > 0) {
      patch.apiKey = newKey;
      changed = true;
    }
    if (!changed) {
      this.cfgStatus('没有改动');
      return;
    }
    this.put(QaqhState.CFG_SAVING, true);
    client.configSave(patch).then(() => {
      this.cfgStatus('已保存，重新读取权威值…');
      this.loadDaemonConfig(true);
    }).catch((error: Error) => {
      this.cfgStatus(`保存失败: ${error.message}`);
    }).finally(() => {
      this.put(QaqhState.CFG_SAVING, false);
    });
  }

  /** `profile.apply`：切档案 = 切端点（wire/compat/contextLength 一起换）。 */
  applyDaemonProfile(): void {
    const client = this.listClient;
    const name: string = this.text(QaqhState.CFG_SELECTED_PROFILE);
    if (client === undefined || name.length === 0) {
      this.cfgStatus('先选择要应用的档案');
      return;
    }
    client.applyProfile(name).then(() => {
      this.cfgStatus(`已切换到档案 ${name}，重新读取…`);
      this.loadDaemonConfig(true);
    }).catch((error: Error) => {
      this.cfgStatus(`切换失败: ${error.message}`);
    });
  }

  /** `profile.save_current`：把 daemon 当前配置存成一份具名档案。 */
  saveDaemonProfile(name: string): void {
    const client = this.listClient;
    const trimmed: string = name.trim();
    if (client === undefined || trimmed.length === 0) {
      this.cfgStatus('输入档案名后再保存');
      return;
    }
    client.saveCurrentProfile(trimmed).then(() => {
      this.cfgStatus(`当前配置已存为档案 ${trimmed}`);
      this.loadDaemonConfig(true);
    }).catch((error: Error) => {
      this.cfgStatus(`存档案失败: ${error.message}`);
    });
  }

  /** 数字输入框解析：空串 = 0 = 不动；非法数字也归 0（页面不做半截校验）。 */
  private numberField(key: string): number {
    const raw: string = this.text(key).trim();
    if (raw.length === 0) {
      return 0;
    }
    const value: number = parseInt(raw, 10);
    return Number.isNaN(value) ? 0 : value;
  }

  /** 深链聚焦消费（回写清空防重复触发；高亮由 ApprovalPanel 保留）。 */
  consumeFocus(): void {
    this.focusInteraction = '';
    this.focusAction = '';
  }
}
