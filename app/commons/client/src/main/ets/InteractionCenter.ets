/**
 * 交互中心（M3 授权闭环的核心）。
 *
 * 职责：
 * 1. 维护 pending 交互集合：bootstrap 快照 + `interaction_requested` /
 *    `interaction_resolved` / `interaction_expired` 三种 control delta。
 *    （first-answer-wins：任何来源的 resolved——包括桌面端——都移除 pending。）
 * 2. 三类应答命令：`tool_permission_respond`（tool 频道，tool_call_id =
 *    交互的 call_id）/ `interaction_ask_respond` + `interaction_ask_dismiss` /
 *    `plan_review_respond`（control 频道）。
 * 3. 可靠确认：命令被 ACK accepted 后登记 `command_id`，直到出现
 *    `causation_id == command_id` 的事件才视为终态；ACK 传输丢失时回退
 *    `GET /commands/{id}` 查状态（accepted/running 继续等事件，
 *    succeeded → 已生效，rejected/failed → 上报失败）。
 */

import { AskAnswer, CommandReceiptExisting, ControlCommands, ProjectionPayload,
  RingingCommand, RingingV2Bootstrap, RingingV2CommandAck, RingingV2CommandEnvelope,
  RingingV2EventEnvelope, RingingV2PendingInteraction, ToolCommands, newCommandId }
  from '@qaqh/protocol';
import { RingingClient } from './RingingClient';
import { TransportError } from './transport/Transport';

/** UI 视角的待处理交互。
 *
 * M12 起支持两个来源：
 * - live（remote=false）：本中心经监视流维护的当前会话交互；
 * - remote（remote=true）：审批聚合轮询（/approvals）发现的**其它会话**条目，
 *   `sessionId` 是不可变绑定（应答永远走条目自带的会话，防串频），
 *   `wireId` 是应答凭据（device=challenge_id / admin=canonical id）。
 *   `interactionId` 是展示唯一键（remote 条目为 `sessionId#wireId`）。
 */
export class PendingInteractionView {
  readonly interactionId: string;
  readonly callId: string;
  readonly turnId: string;
  readonly kind: string;
  readonly request: object | undefined;
  readonly revision: number;
  readonly sessionId: string;
  readonly wireId: string;
  readonly remote: boolean;

  constructor(interactionId: string, callId: string, turnId: string, kind: string,
    request: object | undefined, revision: number, sessionId: string = '',
    wireId: string = '', remote: boolean = false) {
    this.interactionId = interactionId;
    this.callId = callId;
    this.turnId = turnId;
    this.kind = kind;
    this.request = request;
    this.revision = revision;
    this.sessionId = sessionId;
    this.wireId = wireId;
    this.remote = remote;
  }
}

function viewOf(interaction: RingingV2PendingInteraction,
  sessionId: string): PendingInteractionView {
  return new PendingInteractionView(interaction.interactionId, interaction.callId,
    interaction.turnId, interaction.kind,
    interaction.request as Object, 0, sessionId);
}

export interface InteractionCenterListener {
  onPendingChanged(pending: PendingInteractionView[]): void;
  /** 交互终态（我方命令 causation 确认、桌面端先答、或 ACK existing 回执）。 */
  onInteractionResolved(interactionId: string, detail: string): void;
  onRespondFailed(interactionId: string, detail: string): void;
}

export class InteractionCenter {
  private readonly client: RingingClient;
  private readonly listener: InteractionCenterListener;
  private readonly pending: Map<string, PendingInteractionView> = new Map();
  /** command_id → interaction_id：等待 causation 确认的我方命令。 */
  private readonly awaiting: Map<string, string> = new Map();
  private sessionId: string = '';

  constructor(client: RingingClient, listener: InteractionCenterListener) {
    this.client = client;
    this.listener = listener;
  }

  setSessionId(sessionId: string): void {
    this.sessionId = sessionId;
  }

  pendingValue(): PendingInteractionView[] {
    const out: PendingInteractionView[] = [];
    this.pending.forEach((view: PendingInteractionView) => {
      out.push(view);
    });
    return out;
  }

  /** bootstrap 快照里的挂起交互（订阅建立时调用一次）。 */
  ingestBootstrap(snapshot: RingingV2Bootstrap): void {
    this.pending.clear();
    for (const interaction of snapshot.controlState.interactions) {
      this.pending.set(interaction.interactionId,
        viewOf(interaction, snapshot.sessionId));
    }
    this.listener.onPendingChanged(this.pendingValue());
  }

  /** 每个流事件都过这里：先核对 causation 确认，再吃 delta。 */
  ingestEnvelope(envelope: RingingV2EventEnvelope, payload: ProjectionPayload): void {
    if (envelope.causationId !== undefined) {
      const interactionId: string | undefined = this.awaiting.get(envelope.causationId);
      if (interactionId !== undefined) {
        this.awaiting.delete(envelope.causationId);
        this.pending.delete(interactionId);
        this.listener.onInteractionResolved(interactionId,
          'confirmed by causation ' + envelope.causationId);
        this.listener.onPendingChanged(this.pendingValue());
        return;
      }
    }
    if (payload.interactionRequested !== undefined) {
      const delta = payload.interactionRequested;
      this.pending.set(delta.interactionId, new PendingInteractionView(
        delta.interactionId, delta.callId ?? '', '', delta.kind,
        delta.request as Object, delta.revision, this.sessionId));
      this.listener.onPendingChanged(this.pendingValue());
      return;
    }
    if (payload.interactionResolved !== undefined) {
      const interactionId: string = payload.interactionResolved.interactionId;
      if (this.pending.delete(interactionId)) {
        this.listener.onInteractionResolved(interactionId, 'resolved externally');
        this.listener.onPendingChanged(this.pendingValue());
      }
      return;
    }
    if (payload.interactionExpired !== undefined) {
      if (this.pending.delete(payload.interactionExpired.interactionId)) {
        this.listener.onPendingChanged(this.pendingValue());
      }
    }
  }

  async respondPermission(view: PendingInteractionView, approved: boolean,
    trustFolder: boolean): Promise<void> {
    await this.submit(view,
      ToolCommands.toolPermissionRespond(view.callId, approved, trustFolder),
      `permission ${approved ? 'allow' : 'deny'}`);
  }

  async respondPlan(view: PendingInteractionView, approved: boolean, message: string,
    autonomous: boolean): Promise<void> {
    await this.submit(view,
      ControlCommands.planReviewRespond(view.interactionId, approved, message, autonomous),
      `plan ${approved ? 'approved' : 'rejected'}`);
  }

  async respondAsk(view: PendingInteractionView, answers: AskAnswer[]): Promise<void> {
    await this.submit(view, ControlCommands.interactionAskRespond(view.interactionId, answers),
      'ask answered');
  }

  async dismissAsk(view: PendingInteractionView): Promise<void> {
    await this.submit(view, ControlCommands.interactionAskDismiss(view.interactionId),
      'ask dismissed');
  }

  /**
   * 命令提交 + ACK/状态回退。
   * TODO(M3 对拍): 未带 expected_revision——revision-safe 语义由 envelope
   * 守卫承载，首轮不做乐观并发，冲突走 rejected + existing 回执。
   */
  private async submit(view: PendingInteractionView, command: RingingCommand,
    describe: string): Promise<void> {
    const commandId: string = newCommandId();
    const envelope: RingingV2CommandEnvelope = RingingV2CommandEnvelope.create(
      commandId, 'harmony-center', this.client.sessionHeader(), this.sessionId, command);
    let ack: RingingV2CommandAck;
    try {
      ack = await this.client.sendCommand(envelope);
    } catch (error) {
      if (error instanceof TransportError) {
        // ACK 丢失：查询命令状态决定下一步（同一 command_id 幂等）。
        await this.resolveByStatus(view, commandId, describe);
        return;
      }
      this.listener.onRespondFailed(view.interactionId, (error as Error).message);
      return;
    }
    if (ack.status === 'accepted') {
      this.awaiting.set(ack.commandId, view.interactionId);
      return;
    }
    // rejected：existing 回执里可能已经是别人答完的终态。
    if (ack.existing !== undefined) {
      const existing = ack.existing as CommandReceiptExisting;
      if (existing.result !== undefined) {
        this.pending.delete(view.interactionId);
        this.listener.onInteractionResolved(view.interactionId,
          `already ${existing.state}`);
        this.listener.onPendingChanged(this.pendingValue());
        return;
      }
    }
    this.listener.onRespondFailed(view.interactionId,
      `${describe} rejected: ${ack.code ?? ack.message ?? 'unknown'}`);
  }

  private async resolveByStatus(view: PendingInteractionView, commandId: string,
    describe: string): Promise<void> {
    let state: string;
    try {
      const status = await this.client.commandStatus(commandId);
      state = status.state;
    } catch (error) {
      this.listener.onRespondFailed(view.interactionId,
        `${describe} ack lost and status query failed: ${(error as Error).message}`);
      return;
    }
    if (state === 'succeeded') {
      this.pending.delete(view.interactionId);
      this.listener.onInteractionResolved(view.interactionId, 'resolved via status query');
      this.listener.onPendingChanged(this.pendingValue());
    } else if (state === 'accepted' || state === 'running') {
      this.awaiting.set(commandId, view.interactionId);
    } else {
      this.listener.onRespondFailed(view.interactionId, `${describe} terminal state: ${state}`);
    }
  }
}
