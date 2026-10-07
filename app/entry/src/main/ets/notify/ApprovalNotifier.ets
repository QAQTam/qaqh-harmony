/**
 * 审批通知（M4）：`interaction_requested` 到达时发 SERVICE_INFORMATION 横幅
 * 通知（横幅/锁屏/铃声全开），LONG_TEXT 承载审批摘要，actionButtons 提供
 * 「允许/拒绝」快捷入口（经 wantAgent 拉起 app 并携带预选参数——真正的应答
 * 仍须在 app 内过 Authenticator 门禁，通知按钮只是深链）。
 *
 * API 24 能力边界（本机 SDK 已核实）：实况窗/胶囊通知是系统应用专属
 * （NotificationSystemLiveViewContent / Live View Kit 26 线），三方不可用；
 * 常规通知 + actionButtons 是本档设备的最强提醒形态。
 */

import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PendingInteractionView } from '@qaqh/client';
import { InteractionBody } from '@qaqh/protocol';

const NOTIFICATION_ID_BASE: number = 0x0A11;

export class ApprovalNotifier {
  private slotReady: boolean = false;
  private readonly bundleName: string;
  private readonly abilityName: string;

  constructor(bundleName: string, abilityName: string) {
    this.bundleName = bundleName;
    this.abilityName = abilityName;
  }

  /** 渠道创建（幂等）：SERVICE_INFORMATION = 横幅+锁屏+铃声。 */
  async ensureSlot(): Promise<void> {
    if (this.slotReady) {
      return;
    }
    try {
      await notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION);
      this.slotReady = true;
    } catch (error) {
      // 已存在等场景按可用处理，publish 时再失败会抛出真实错误。
      this.slotReady = true;
    }
  }

  /** 发布审批提醒。bodyText 为已解析的正文摘要；返回通知 id（interactionId 派生）。 */
  async publishApproval(view: PendingInteractionView, bodyText: string,
    title: string): Promise<void> {
    await this.ensureSlot();
    const deepLink: WantAgent | undefined = await this.deepLinkAgent(view, '');
    const allowLink: WantAgent | undefined = await this.deepLinkAgent(view, 'approve');
    const denyLink: WantAgent | undefined = await this.deepLinkAgent(view, 'deny');
    let request: notificationManager.NotificationRequest = {
      id: this.notificationId(view),
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_LONG_TEXT,
        longText: {
          title: title,
          text: bodyText.length > 0 ? bodyText : title,
          expandedTitle: title,
          briefText: bodyText.length > 0 ? bodyText.substring(0, 40) : title,
          longText: bodyText,
        }
      },
      wantAgent: deepLink !== undefined ? deepLink : undefined,
      actionButtons: allowLink !== undefined && denyLink !== undefined ? [
        { title: '允许', wantAgent: allowLink },
        { title: '拒绝', wantAgent: denyLink }
      ] : undefined,
      autoDeletedTime: new Date().getTime() + 10 * 60 * 1000
    };
    await notificationManager.publish(request);
  }

  /** 交互已生效/过期时撤下通知。 */
  cancelApproval(view: PendingInteractionView): void {
    notificationManager.cancel(this.notificationId(view))
      .catch((error: BusinessError) => {
        void error; // 通知不存在等场景忽略。
      });
  }

  private notificationId(view: PendingInteractionView): number {
    // 稳定派生：同一交互重发即更新而非堆积。
    let hash: number = 0;
    for (let i = 0; i < view.interactionId.length; i++) {
      hash = (hash * 31 + view.interactionId.charCodeAt(i)) & 0x7fffffff;
    }
    return NOTIFICATION_ID_BASE + (hash % 0x1000000);
  }

  private async deepLinkAgent(view: PendingInteractionView,
    action: string): Promise<WantAgent | undefined> {
    try {
      return await wantAgent.getWantAgent({
        wants: [{
          deviceId: '',
          bundleName: this.bundleName,
          abilityName: this.abilityName,
          parameters: {
            'interaction_id': view.interactionId,
            'interaction_kind': view.kind,
            'qaqh_action': action
          }
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

/** 从 InteractionBody 提炼通知摘要（纯函数，deviceTypes 无关）。 */
export function approvalSummary(view: PendingInteractionView,
  body: InteractionBody | undefined): string {
  if (body === undefined) {
    return `交互 ${view.interactionId}（${view.kind}）等待处理`;
  }
  if (body.permission !== undefined) {
    const lines: string[] = [`工具 ${body.permission.toolName}`];
    if (body.permission.actionSummary !== undefined) {
      lines.push(body.permission.actionSummary);
    }
    if (body.permission.paths.length > 0) {
      lines.push(`路径: ${body.permission.paths.join(', ')}`);
    }
    if (body.permission.consequence.length > 0) {
      lines.push(body.permission.consequence);
    }
    return lines.join('\n');
  }
  if (body.plan !== undefined) {
    return body.plan.planContent.length > 0
      ? body.plan.planContent : `计划审核（${body.plan.reviewType}）`;
  }
  if (body.ask !== undefined && body.ask.questions.length > 0) {
    return body.ask.questions.map((question) => question.question).join('\n');
  }
  return `交互 ${view.interactionId}（${view.kind}）等待处理`;
}
