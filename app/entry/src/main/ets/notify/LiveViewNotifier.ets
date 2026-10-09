/**
 * 实况窗（API 26 增量，M5；M15 重做）：前台运行时在状态栏/通知面板挂实况条目，
 * 点按深链回 app。
 *
 * 24/26 双端策略（handoff M4）：@kit.LiveViewKit since 26.0.0，API 24 设备上
 * 静态 import 会崩——因此全模块走 动态 import + canIUse(syscap) 运行时守卫，
 * 不可用时所有调用静默降级（常规通知由 ApprovalNotifier 承担，不受影响）。
 *
 * M15 两件事：
 *
 * 1) 语义从「回合窗」换成「Todo 进度窗」。回合（电脑正在干活）没有可展示的
 *    进度，而 todo 面板有 done/total —— 它才是实况窗该承载的东西（Goal 模式
 *    的检查点将来同样落在这条通道上，届时只是换一组 total/done 来源）。
 * 2) 旧请求体根本出不来胶囊，逐项对齐 liveViewManager 的契约：
 *    - `capsule.type` 原先传 0，而 CapsuleType 只有 1/2/3（TEXT/TIMER/
 *      PROGRESS），0 不是合法值；
 *    - `capsule.status` 是**必填**（1=显示 / -1=结束），原先从未传；
 *    - `title` 只在 TextCapsule 上成立，进度胶囊（ProgressCapsule）没有这个
 *      字段，只有 max/progress/content，故进度窗改用 `progress`+`max` 出
 *      「3/7」比值形态；
 *    - 卡片侧补 `primary.layoutData` 的进度可视化模板（LAYOUT_TYPE_PROGRESS
 *      = 3，progress 值域 0-100），锁屏/通知中心才有进度条而不是一行字。
 *
 * 并存规则改了：**进度窗不再给审批窗让位**。实况窗是 DATA_TRANSFER 长时任务
 * 的进度载体（长时任务要求「更新进度的通知类型必须为实况窗」，且首次更新后
 * 每 10 分钟必须再更新一次，否则系统撤掉长时任务、进程冻结、胶囊停在旧值），
 * 收掉它等于自断保活。两窗各挂各的，通知中心最多容纳 24 条实况。
 *
 * 失败不再全静默：实况窗创建有三道独立门槛（AGC 实况窗权益、设置里的应用
 * 实况窗开关、应用在前台），原先 catch 里连 err.code 都不落，「系统拒了」和
 * 「根本没触发」在日志上完全同形，无法归因。现在预检 + 落码。
 *
 * 实现说明：kit 类型不做静态引用（编译期类型查询别名被 ArkTS 禁用），用本地
 * 结构接口 + as 转换对齐 liveViewManager 的最小调用面。
 */

import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const HILOG_DOMAIN: number = 0x0;
const HILOG_TAG: string = 'QaqhLiveView';

/** liveViewManager 最小调用面（结构性对齐 @hms.core.liveview.liveViewManager）。 */
interface LiveViewManagerLike {
  isLiveViewEnabled(): Promise<boolean>;
  startLiveView(view: object): Promise<object>;
  updateLiveView(view: object): Promise<object>;
  stopLiveView(view: object): Promise<object>;
}

/** 实况窗稳定 id（同一 id 重发即更新；不同 id 各自成窗）。 */
const PENDING_VIEW_ID: number = 0x1D60;
const TODO_VIEW_ID: number = 0x1D61;

/** CapsuleType：TEXT=1 / TIMER=2 / PROGRESS=3（没有 0）。 */
const CAPSULE_TYPE_TEXT: number = 1;
const CAPSULE_TYPE_PROGRESS: number = 3;
/** LayoutType.LAYOUT_TYPE_PROGRESS。 */
const LAYOUT_TYPE_PROGRESS: number = 3;
/** CapsuleData.status：1=展示，-1=结束。 */
const CAPSULE_SHOWN: number = 1;

/** 胶囊底色（ARGB）。文档不推荐纯黑/纯白/#FFF1F3F5，取品牌蓝。 */
const CAPSULE_BG: string = '#FF2E6BE6';
/** 胶囊图标：resources/rawfile 下的文件名。 */
const CAPSULE_ICON: string = 'capsule_qaqh.png';

/** 一次调用的全部展示入参已定，kit 侧只需知道是哪个窗。 */
enum LiveViewSlot {
  PENDING = 0,
  TODO = 1
}

export class LiveViewNotifier {
  private available: boolean | undefined;
  private readonly bundleName: string;
  private readonly abilityName: string;

  // 两条更新通道的状态源（reconcile 的输入；update 系列只改状态，不直接碰 kit）。
  private pendingCount: number = 0;
  private pendingDetail: string = '';
  private todoTotal: number = 0;
  private todoDone: number = 0;
  private todoCurrent: string = '';
  // 每个 view 的在场标记、独立递增 sequence，与「上次真正推出去的内容」。
  private pendingShown: boolean = false;
  private pendingSequence: number = 0;
  private pendingPushed: string = '';
  private todoShown: boolean = false;
  private todoSequence: number = 0;
  private todoPushed: string = '';

  constructor(bundleName: string, abilityName: string) {
    this.bundleName = bundleName;
    this.abilityName = abilityName;
  }

  /** 待审批数变化入口：count>0 创建/更新审批窗；=0 收起。 */
  async updatePendingCount(count: number, detail: string): Promise<void> {
    this.pendingCount = count;
    this.pendingDetail = detail;
    await this.reconcile();
  }

  /**
   * Todo 进度入口：total<=0 收起进度窗。
   *
   * 由 todo 面板版本变化驱动，**不要**由流式 flush 直接驱动——出 token 不代表
   * 有进度，长时间不出 token 也不代表没进度，只有面板变才是进度变。
   */
  async updateTodoProgress(total: number, done: number, current: string): Promise<void> {
    this.todoTotal = total;
    this.todoDone = done;
    this.todoCurrent = current;
    await this.reconcile();
  }

  /** 全部收起（断开/退出会话/登出）：清两条状态源再对账。 */
  async stop(): Promise<void> {
    this.pendingCount = 0;
    this.pendingDetail = '';
    this.todoTotal = 0;
    this.todoDone = 0;
    this.todoCurrent = '';
    await this.reconcile();
  }

  /** 对账：把两条状态源落到 kit 的 start/update/stop 上。 */
  private async reconcile(): Promise<void> {
    const manager: LiveViewManagerLike | undefined = await this.resolveManager();
    if (manager === undefined) {
      return;
    }
    await this.applyPending(manager);
    await this.applyTodo(manager);
  }

  private async applyPending(manager: LiveViewManagerLike): Promise<void> {
    if (this.pendingCount <= 0) {
      await this.teardown(manager, LiveViewSlot.PENDING);
      return;
    }
    const detail: string = this.pendingDetail.length > 0
      ? this.pendingDetail : `${this.pendingCount} 项操作等待审批`;
    const fingerprint: string = `${this.pendingCount}|${detail}`;
    if (this.pendingShown && fingerprint === this.pendingPushed) {
      return;
    }
    const view: object = await this.buildPendingView(detail);
    if (await this.push(manager, LiveViewSlot.PENDING, view)) {
      this.pendingPushed = fingerprint;
    }
  }

  private async applyTodo(manager: LiveViewManagerLike): Promise<void> {
    if (this.todoTotal <= 0) {
      await this.teardown(manager, LiveViewSlot.TODO);
      return;
    }
    const done: number = this.todoDone > this.todoTotal ? this.todoTotal : this.todoDone;
    const percent: number = Math.floor(done * 100 / this.todoTotal);
    const current: string = this.todoCurrent.length > 0
      ? this.todoCurrent : `${done}/${this.todoTotal} 已完成`;
    const fingerprint: string = `${this.todoTotal}|${done}|${current}`;
    if (this.todoShown && fingerprint === this.todoPushed) {
      return;
    }
    const view: object = await this.buildTodoView(done, percent, current);
    if (await this.push(manager, LiveViewSlot.TODO, view)) {
      this.todoPushed = fingerprint;
    }
  }

  /** 收窗：不在场就什么都不做（幂等，避免空转 sequence）。 */
  private async teardown(manager: LiveViewManagerLike, slot: LiveViewSlot): Promise<void> {
    const shown: boolean = slot === LiveViewSlot.PENDING ? this.pendingShown : this.todoShown;
    if (!shown) {
      return;
    }
    const view: Record<string, Object> = {
      'id': slot === LiveViewSlot.PENDING ? PENDING_VIEW_ID : TODO_VIEW_ID,
      'event': 'PROGRESS'
    };
    view['sequence'] = this.nextSequence(slot);
    await this.invoke(manager, 'stop', view, slot);
    this.setShown(slot, false);
  }

  /** 推窗：首次 start、其后 update；成功才认在场。 */
  private async push(manager: LiveViewManagerLike, slot: LiveViewSlot,
    view: object): Promise<boolean> {
    const shown: boolean = slot === LiveViewSlot.PENDING ? this.pendingShown : this.todoShown;
    const ok: boolean = await this.invoke(manager, shown ? 'update' : 'start', view, slot);
    if (ok && !shown) {
      this.setShown(slot, true);
    }
    return ok;
  }

  /** 唯一真正 await kit 的地方：任何失败落一条带 code 的日志，不抛。 */
  private async invoke(manager: LiveViewManagerLike, method: string,
    view: object, slot: LiveViewSlot): Promise<boolean> {
    try {
      if (method === 'start') {
        await manager.startLiveView(view);
      } else if (method === 'update') {
        await manager.updateLiveView(view);
      } else {
        await manager.stopLiveView(view);
      }
      return true;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      hilog.warn(HILOG_DOMAIN, HILOG_TAG,
        'liveView %{public}s id=%{public}d 失败 code=%{public}d msg=%{public}s',
        method, slot === LiveViewSlot.PENDING ? PENDING_VIEW_ID : TODO_VIEW_ID,
        err.code, err.message);
      return false;
    }
  }

  private setShown(slot: LiveViewSlot, shown: boolean): void {
    if (slot === LiveViewSlot.PENDING) {
      this.pendingShown = shown;
      if (!shown) {
        this.pendingPushed = '';
      }
    } else {
      this.todoShown = shown;
      if (!shown) {
        this.todoPushed = '';
      }
    }
  }

  private nextSequence(slot: LiveViewSlot): number {
    if (slot === LiveViewSlot.PENDING) {
      this.pendingSequence++;
      return this.pendingSequence;
    }
    this.todoSequence++;
    return this.todoSequence;
  }

  /** syscap 探测 + 实况窗开关预检 + 动态 import；任一不满足即 undefined（调用方降级）。 */
  private async resolveManager(): Promise<LiveViewManagerLike | undefined> {
    if (this.available === undefined) {
      let manager: LiveViewManagerLike | undefined = undefined;
      try {
        if (canIUse('SystemCapability.LiveView.LiveViewService')) {
          const mod: Record<string, Object> =
            await import('@kit.LiveViewKit') as Record<string, Object>;
          manager = mod['liveViewManager'] as LiveViewManagerLike;
        }
      } catch (error) {
        hilog.warn(HILOG_DOMAIN, HILOG_TAG, 'LiveViewKit 不可用：%{public}s',
          (error as Error).message);
        manager = undefined;
      }
      if (manager === undefined) {
        this.available = false;
      } else {
        // 设置 > 应用和元服务 > 应用名 > 实况窗：关着就创建不出来，先查一次。
        try {
          this.available = await manager.isLiveViewEnabled();
        } catch (error) {
          this.available = false;
        }
        if (!this.available) {
          hilog.warn(HILOG_DOMAIN, HILOG_TAG, '实况窗开关未打开（或被权益拦截）');
        }
      }
    }
    if (!this.available) {
      return undefined;
    }
    const mod: Record<string, Object> =
      await import('@kit.LiveViewKit') as Record<string, Object>;
    return mod['liveViewManager'] as LiveViewManagerLike;
  }

  private async buildPendingView(detail: string): Promise<object> {
    const view: Record<string, Object> = this.skeleton(LiveViewSlot.PENDING);
    const primary: Record<string, Object> = {
      'title': 'QAQ-Harness 审批',
      'content': this.richContent(detail),
      'keepTime': 0
    };
    const action: WantAgent | undefined = await this.clickAction();
    if (action !== undefined) {
      primary['clickAction'] = action as Object;
    }
    const capsule: Record<string, Object> = this.capsuleBase(CAPSULE_TYPE_TEXT);
    capsule['title'] = `${this.pendingCount} 项待审批`;
    capsule['content'] = this.clip(detail);
    const data: Record<string, Object> = { 'primary': primary, 'capsule': capsule };
    view['liveViewData'] = data;
    return view;
  }

  private async buildTodoView(done: number, percent: number, current: string): Promise<object> {
    const view: Record<string, Object> = this.skeleton(LiveViewSlot.TODO);
    const layout: Record<string, Object> = {
      'type': LAYOUT_TYPE_PROGRESS,
      'progress': percent
    };
    const primary: Record<string, Object> = {
      'title': `QAQ-Harness ${done}/${this.todoTotal}`,
      'content': this.richContent(current),
      'keepTime': 0,
      'layoutData': layout
    };
    const action: WantAgent | undefined = await this.clickAction();
    if (action !== undefined) {
      primary['clickAction'] = action as Object;
    }
    const capsule: Record<string, Object> = this.capsuleBase(CAPSULE_TYPE_PROGRESS);
    capsule['progress'] = done;
    capsule['max'] = this.todoTotal;
    capsule['content'] = this.clip(current);
    const data: Record<string, Object> = { 'primary': primary, 'capsule': capsule };
    view['liveViewData'] = data;
    return view;
  }

  /** 两窗共用的外层字段（id / event / sequence / 静默 / 生命周期）。 */
  private skeleton(slot: LiveViewSlot): Record<string, Object> {
    const view: Record<string, Object> = {
      'id': slot === LiveViewSlot.PENDING ? PENDING_VIEW_ID : TODO_VIEW_ID,
      'event': 'PROGRESS',
      'isMute': true,
      // LifeCycleMode.STOP_BY_APP：实况窗不随进程结束自动消失，必须显式 stop。
      'lifeCycleMode': 0
    };
    view['sequence'] = this.nextSequence(slot);
    return view;
  }

  /** CapsuleData 基类的必填 + 通用字段。 */
  private capsuleBase(type: number): Record<string, Object> {
    const capsule: Record<string, Object> = {
      'type': type,
      'status': CAPSULE_SHOWN,
      'icon': CAPSULE_ICON,
      'backgroundColor': CAPSULE_BG
    };
    return capsule;
  }

  /** PrimaryData.content：数组内 text 不得为空串或纯空格。 */
  private richContent(text: string): Array<Record<string, Object>> {
    const item: Record<string, Object> = { 'text': text.length > 0 ? text : ' ' };
    return [item];
  }

  /** 胶囊副文本上限 128 字符，但状态栏那点宽度 24 字就到头了。 */
  private clip(text: string): string {
    const trimmed: string = text.length > 24 ? `${text.substring(0, 24)}…` : text;
    return trimmed.length > 0 ? trimmed : '进行中';
  }

  private async clickAction(): Promise<WantAgent | undefined> {
    try {
      return await wantAgent.getWantAgent({
        wants: [{
          deviceId: '',
          bundleName: this.bundleName,
          abilityName: this.abilityName,
          parameters: {}
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
    } catch (error) {
      return undefined;
    }
  }
}
