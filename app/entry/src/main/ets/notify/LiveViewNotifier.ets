/**
 * 实况窗（API 26 增量，M5；M11 深化为双视图）：前台运行时在状态栏/通知面板
 * 挂实况条目，点按深链回 app。
 *
 * 24/26 双端策略（handoff M4）：@kit.LiveViewKit since 26.0.0，API 24 设备上
 * 静态 import 会崩——因此全模块走 动态 import + canIUse(syscap) 运行时守卫，
 * 不可用时所有调用静默降级（常规通知由 ApprovalNotifier 承担，不受影响）。
 *
 * 实现说明：kit 类型不做静态引用（编译期类型查询别名被 ArkTS 禁用），用本地
 * 结构接口 + as 转换对齐 liveViewManager 的最小调用面；scenario 用 PROGRESS
 * （进度展示，无需专项场景资质），sequence 逐次递增满足「更新版本号必须更大」。
 *
 * M11 双视图：同一 app 可同时持有多个实况窗（不同 id），这里管两张——
 * - 审批窗（pending）：N 项待审批，锁屏/状态栏的最高优先级条目；
 * - 回合窗（turn）：「电脑正在干活」常驻胶囊，回合开始出现、结束/断连自动收。
 * 并存规则：**审批窗在场时回合窗让位**（锁屏不同时挂两个胶囊）——两条更新
 * 通道各自 setState，统一在 reconcile() 里对账：审批处理完（count→0）而回合
 * 还在跑时，回合窗自动补位出现。
 */

import { wantAgent, WantAgent } from '@kit.AbilityKit';

/** liveViewManager 最小调用面（结构性对齐 @hms.core.liveview.liveViewManager）。 */
interface LiveViewManagerLike {
  startLiveView(view: object): Promise<object>;
  updateLiveView(view: object): Promise<object>;
  stopLiveView(view: object): Promise<object>;
}

/** 实况窗稳定 id（同一 id 重发即更新；不同 id 各自成窗）。 */
const PENDING_VIEW_ID: number = 0x1D60;
const TURN_VIEW_ID: number = 0x1D61;

export class LiveViewNotifier {
  private available: boolean | undefined;
  private readonly bundleName: string;
  private readonly abilityName: string;

  // 两条更新通道的状态源（reconcile 的输入；update 系列只改状态，不直接碰 kit）。
  private pendingCount: number = 0;
  private pendingDetail: string = '';
  private turnActive: boolean = false;
  private turnDetail: string = '';
  // 每个 view 的在场标记与独立递增 sequence。
  private pendingShown: boolean = false;
  private pendingSequence: number = 0;
  private turnShown: boolean = false;
  private turnSequence: number = 0;

  constructor(bundleName: string, abilityName: string) {
    this.bundleName = bundleName;
    this.abilityName = abilityName;
  }

  /** 待审批数变化入口：count>0 创建/更新审批窗；=0 收起（回合窗按需补位）。 */
  async updatePendingCount(count: number, detail: string): Promise<void> {
    this.pendingCount = count;
    this.pendingDetail = detail;
    await this.reconcile();
  }

  /** 回合进行中变化入口：true 常驻胶囊，false 收起（幂等，边沿由调用方判）。 */
  async updateTurnActive(active: boolean, detail: string): Promise<void> {
    this.turnActive = active;
    this.turnDetail = detail;
    await this.reconcile();
  }

  /** 全部收起（断开/退出会话/登出）：清两条状态源再对账。 */
  async stop(): Promise<void> {
    this.pendingCount = 0;
    this.pendingDetail = '';
    this.turnActive = false;
    this.turnDetail = '';
    await this.reconcile();
  }

  /** 对账：把两条状态源落到 kit 的 start/update/stop 上。任何失败静默降级。 */
  private async reconcile(): Promise<void> {
    const manager: LiveViewManagerLike | undefined = await this.resolveManager();
    if (manager === undefined) {
      return;
    }
    await this.applyPending(manager);
    await this.applyTurn(manager);
  }

  private async applyPending(manager: LiveViewManagerLike): Promise<void> {
    try {
      if (this.pendingCount > 0) {
        const detail: string = this.pendingDetail.length > 0
          ? this.pendingDetail : `${this.pendingCount} 项操作等待审批`;
        const view: object = await this.buildView(PENDING_VIEW_ID, 'QAQ-Harness 审批',
          detail, `${this.pendingCount} 项待审批`);
        if (this.pendingShown) {
          await manager.updateLiveView(view);
        } else {
          await manager.startLiveView(view);
          this.pendingShown = true;
        }
      } else if (this.pendingShown) {
        this.pendingShown = false;
        this.pendingSequence++;
        const view: Record<string, Object> =
          { 'id': PENDING_VIEW_ID, 'event': 'PROGRESS' };
        view['sequence'] = this.pendingSequence;
        await manager.stopLiveView(view);
      }
    } catch (error) {
      // 实况窗是增强体验：任何失败都静默，不影响常规通知链路。
      this.pendingShown = false;
    }
  }

  private async applyTurn(manager: LiveViewManagerLike): Promise<void> {
    try {
      const show: boolean = this.turnActive && this.pendingCount <= 0;
      if (show) {
        const detail: string = this.turnDetail.length > 0
          ? this.turnDetail : '回合进行中，点按查看';
        const view: object = await this.buildView(TURN_VIEW_ID, 'QAQ-Harness',
          detail, '电脑正在干活');
        if (this.turnShown) {
          await manager.updateLiveView(view);
        } else {
          await manager.startLiveView(view);
          this.turnShown = true;
        }
      } else if (this.turnShown) {
        this.turnShown = false;
        this.turnSequence++;
        const view: Record<string, Object> =
          { 'id': TURN_VIEW_ID, 'event': 'PROGRESS' };
        view['sequence'] = this.turnSequence;
        await manager.stopLiveView(view);
      }
    } catch (error) {
      this.turnShown = false;
    }
  }

  /** syscap 探测 + 动态 import；任一步不可用即返回 undefined（调用方降级）。 */
  private async resolveManager(): Promise<LiveViewManagerLike | undefined> {
    if (this.available === undefined) {
      try {
        if (canIUse('SystemCapability.LiveView.LiveViewService')) {
          const mod: Record<string, Object> =
            await import('@kit.LiveViewKit') as Record<string, Object>;
          const manager: Object | undefined = mod['liveViewManager'];
          this.available = manager !== undefined && manager !== null;
        } else {
          this.available = false;
        }
      } catch (error) {
        this.available = false;
      }
    }
    if (!this.available) {
      return undefined;
    }
    const mod: Record<string, Object> =
      await import('@kit.LiveViewKit') as Record<string, Object>;
    return mod['liveViewManager'] as LiveViewManagerLike;
  }

  private async buildView(viewId: number, title: string, contentText: string,
    capsuleTitle: string): Promise<object> {
    const sequence: number = viewId === PENDING_VIEW_ID
      ? ++this.pendingSequence : ++this.turnSequence;
    const clickAction: WantAgent | undefined = await wantAgent.getWantAgent({
      wants: [{
        deviceId: '',
        bundleName: this.bundleName,
        abilityName: this.abilityName,
        parameters: {}
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    }).catch((): WantAgent | undefined => undefined);
    const view: Record<string, Object> = {
      'id': viewId,
      'event': 'PROGRESS',
      'isMute': true,
      'lifeCycleMode': 0,
      'liveViewData': {
        'primary': {
          'title': title,
          'content': [{ 'text': contentText } as Record<string, Object>],
          'keepTime': 0,
          'clickAction': clickAction
        } as Record<string, Object>,
        'capsule': {
          'type': 0,
          'title': capsuleTitle,
          'content': contentText.length > 24
            ? `${contentText.substring(0, 24)}…` : contentText
        } as Record<string, Object>
      } as Record<string, Object>
    };
    if (sequence > 0) {
      view['sequence'] = sequence;
    }
    return view;
  }
}
