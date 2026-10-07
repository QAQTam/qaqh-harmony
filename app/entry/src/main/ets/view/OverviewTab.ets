/**
 * 总览 tab（M9-2）：跨会话活跃度与待办的聚合面——移动端前端的「首页仪表盘」。
 *
 * 数据来源：session.list 轮询 + 审批聚合（M12）——CARDS = 监视会话实时流 +
 * 其它运行中会话的 /approvals 轮询，「待审批」统计与列表是真聚合口径。
 *
 * M10 形态：统计卡图标加同色浅底圆片、行列表加分隔线，卡片/标题统一走 UiKit。
 */

import { RingingSessionListEntry } from '@qaqh/protocol';
import { AppModel, QaqhState } from '../model/AppModel';
import { ApprovalCardView } from './ApprovalPanel';
import { CARD_RADIUS, Card, GhostButton, SectionHeader } from './UiKit';
import { MONO_FAMILY } from '../theme/QaqhTheme';

@Component
export struct OverviewTab {
  /** 悬浮胶囊占位（EntryAbility 按真实安全区回灌，默认 88vp）。 */
  @StorageLink(QaqhState.CAP_SPACE) capSpace: number = 88;
  @StorageLink(QaqhState.CONNECTED) connected: boolean = false;
  @StorageLink(QaqhState.STATUS) statusText: string = '';
  @StorageLink(QaqhState.BASE_URL) baseUrl: string = '';
  @StorageLink(QaqhState.PAIRED_LABEL) pairedLabel: string = '';
  @StorageLink(QaqhState.SESSION_ENTRIES) entries: RingingSessionListEntry[] = [];
  @StorageLink(QaqhState.CARDS) cards: ApprovalCardView[] = [];
  @StorageLink(QaqhState.ACTIVE_SESSION) activeSession: string = '';
  @StorageLink(QaqhState.TURN_ACTIVE) turnActive: boolean = false;
  @StorageLink(QaqhState.TAB) tab: number = 0;

  private runningCount(): number {
    let n: number = 0;
    for (const entry of this.entries) {
      if (entry.running) {
        n++;
      }
    }
    return n;
  }

  private cardTitle(card: ApprovalCardView): string {
    if (card.view.kind === 'permission') {
      return card.body !== undefined && card.body.permission !== undefined
        ? `权限请求：${card.body.permission.toolName}` : '权限请求';
    }
    if (card.view.kind === 'plan') {
      return '计划审核';
    }
    if (card.view.kind === 'ask') {
      return card.body !== undefined && card.body.ask !== undefined
        ? `提问（${card.body.ask.questions.length} 个问题）` : '提问';
    }
    return `交互请求（${card.view.kind}）`;
  }

  private cardTone(card: ApprovalCardView): Resource {
    if (card.view.kind === 'permission') {
      return $r('sys.color.ohos_id_color_warning');
    }
    return $r('sys.color.ohos_id_color_emphasize');
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text('总览')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .margin({ top: 12, bottom: 2, left: 4 })
          .alignSelf(ItemAlign.Start)

        // 连接状态卡
        Card() {
          Column({ space: 8 }) {
            Row({ space: 8 }) {
              SymbolGlyph(this.connected
                ? $r('sys.symbol.wifi') : $r('sys.symbol.xmark_circle'))
                .fontSize(17)
                .fontColor([this.connected
                  ? $r('sys.color.ohos_id_color_connected')
                  : $r('sys.color.ohos_id_color_warning')])
              Text(this.connected ? '已连接 daemon' : '未连接')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.ohos_id_color_text_primary'))
              Blank()
              Text(this.baseUrl)
                .fontSize(11)
                .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')

            Text(this.statusText)
              .fontSize(12)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .width('100%')
            if (this.pairedLabel.length > 0) {
              Text(this.pairedLabel)
                .fontSize(11)
                .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
                .width('100%')
            }
          }
          .width('100%')
        }

        // 会话统计
        Row({ space: 12 }) {
          this.statCard('会话', `${this.entries.length}`, $r('sys.symbol.list_bullet'))
          this.statCard('运行中', `${this.runningCount()}`, $r('sys.symbol.play_fill'))
          this.statCard('待审批', `${this.cards.length}`,
            $r('sys.symbol.exclamationmark_triangle'))
        }
        .width('100%')

        // 待审批（M12 真聚合：实时流 + 其它运行中会话的 /approvals 轮询），
        // 点击进对应会话——监视流接管后审批弹窗自动弹出。
        if (this.cards.length > 0) {
          Card() {
            Column({ space: 4 }) {
              SectionHeader({ title: '待处理授权' })
              ForEach(this.cards, (card: ApprovalCardView, index: number) => {
                Row({ space: 10 }) {
                  SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
                    .fontSize(14)
                    .fontColor([this.cardTone(card)])
                  Column({ space: 2 }) {
                    Text(this.cardTitle(card))
                      .fontSize(13)
                      .fontColor($r('sys.color.ohos_id_color_text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    if (card.sessionLabel.length > 0) {
                      Text(`来自会话 · ${card.sessionLabel}`)
                        .fontSize(11)
                        .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(13)
                    .fontColor([$r('sys.color.ohos_id_color_text_tertiary')])
                }
                .width('100%')
                .padding({ top: 9, bottom: 9 })
                .border({ width: { top: index > 0 ? 0.5 : 0 },
                  color: $r('sys.color.ohos_id_color_list_separator') })
                .clickEffect({ level: ClickEffectLevel.LIGHT })
                .onClick(() => {
                  const target: string = card.view.sessionId.length > 0
                    ? card.view.sessionId : this.activeSession;
                  if (target.length > 0) {
                    AppModel.instance().enterSession(target);
                  }
                  this.tab = 0;
                })
              }, (card: ApprovalCardView) => card.view.interactionId)
            }
            .width('100%')
          }
        }

        // 当前会话
        if (this.activeSession.length > 0) {
          Card() {
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                if (this.turnActive) {
                  LoadingProgress()
                    .width(14)
                    .height(14)
                    .color($r('sys.color.ohos_id_color_emphasize'))
                }
                Text(this.turnActive ? '回合进行中' : '会话监视中')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('sys.color.ohos_id_color_text_primary'))
                Blank()
                GhostButton({
                  label: '回到会话',
                  onAction: (): void => {
                    this.tab = 0;
                  }
                })
              }
              .width('100%')

              Text(this.activeSession)
                .fontSize(11)
                .fontFamily(MONO_FAMILY)
                .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
                .width('100%')
            }
            .width('100%')
          }
        }

        // 运行中的会话（点击进对应会话）
        if (this.runningCount() > 0) {
          Card() {
            Column({ space: 4 }) {
              SectionHeader({ title: '运行中的会话' })
              ForEach(this.entries.filter((entry: RingingSessionListEntry): boolean =>
                entry.running), (entry: RingingSessionListEntry, index: number) => {
                Row({ space: 10 }) {
                  LoadingProgress()
                    .width(13)
                    .height(13)
                    .color($r('sys.color.ohos_id_color_emphasize'))
                  Text(entry.displayTitle())
                    .fontSize(13)
                    .fontColor($r('sys.color.ohos_id_color_text_primary'))
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`轮次 ${entry.turnCount}`)
                    .fontSize(11)
                    .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(13)
                    .fontColor([$r('sys.color.ohos_id_color_text_tertiary')])
                }
                .width('100%')
                .padding({ top: 9, bottom: 9 })
                .border({ width: { top: index > 0 ? 0.5 : 0 },
                  color: $r('sys.color.ohos_id_color_list_separator') })
                .clickEffect({ level: ClickEffectLevel.LIGHT })
                .onClick(() => {
                  AppModel.instance().enterSession(entry.sessionId);
                  this.tab = 0;
                })
              }, (entry: RingingSessionListEntry) => entry.sessionId)
            }
            .width('100%')
          }
        }
      }
      .padding({ left: 16, right: 16, bottom: this.capSpace + 12 })
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .width('100%')
    .height('100%')
  }

  @Builder
  statCard(label: string, value: string, icon: Resource) {
    Column({ space: 6 }) {
      // 图标同色浅底圆片：给数字一个视觉锚点（强调色 10% 叠加，深浅色皆可读）。
      Stack() {
        Circle()
          .width(34)
          .height(34)
          .fill('#140A59F7')
        SymbolGlyph(icon)
          .fontSize(16)
          .fontColor([$r('sys.color.ohos_id_color_emphasize')])
      }

      Text(value)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
      Text(label)
        .fontSize(11)
        .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
    }
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
    .padding({ top: 16, bottom: 16 })
    .borderRadius(CARD_RADIUS)
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    .border({ width: 1, color: $r('sys.color.ohos_id_color_list_separator') })
    .hoverEffect(HoverEffect.Highlight)
  }
}
