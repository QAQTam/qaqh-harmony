/**
 * 授权卡片（M9.1 中心弹窗版）：待处理授权按 权限/计划/提问 三形态渲染
 * - permission：风险/类别徽标 + 工具名 + 执行/原因/后果分区 + 路径全列表
 *   可滚（TUI 教训：截断路径会让人误判影响面）+ 允许/拒绝大按钮；
 * - ask：问题分页（多题一屏一题，答完自动翻页），选项整行点选（折行不截断，
 *   TUI 的 SelectionRowDisplay::Wrapped 教训），自定义输入，**全部答完才提交**
 *   （first-answer-wins：每题单独提交会丢掉其它题的答案）；
 * - plan：计划正文滚动区 + 批准/拒绝。
 * 批准类动作仍过 Authenticator 门禁（Index 侧守门，这里只回调）。
 */

import { PendingInteractionView } from '@qaqh/client';
import { AskAnswer, InteractionBody } from '@qaqh/protocol';
import { Markdown } from '@luvi/lv-markdown-in';
import { curves } from '@kit.ArkUI';
import { qaqhMarkdown, toneColor, MONO_FAMILY } from '../theme/QaqhTheme';
import { QaqhState } from '../model/QaqhState';

/** 面板渲染模型：卡片直接持有结构化正文（不再拍平成一坨字符串）。
 * `sessionLabel` 是来源会话徽标（M12 聚合卡片必带；实时卡片为空）——
 * 防串频的展示面约束：用户看到的每张卡都必须能分清来自哪个会话。 */
export class ApprovalCardView {
  readonly view: PendingInteractionView;
  readonly body: InteractionBody | undefined;
  readonly sessionLabel: string;

  constructor(view: PendingInteractionView, body: InteractionBody | undefined,
    sessionLabel: string = '') {
    this.view = view;
    this.body = body;
    this.sessionLabel = sessionLabel;
  }
}
/**
 * 授权中心弹窗（M9.1）：待处理授权按 权限/计划/提问 三形态卡片在屏幕中心弹出，
 * 遮罩压暗但正文可见可滚——对齐 TUI「卡片悬浮而非清屏弹窗」的三家共识。
 *
 * - 卡片直接持有结构化正文（ApprovalCardView.body），语义沿用 M8：
 *   permission=风险/类别徽标+路径全列表可滚；ask=问题分页+整行单选+
 *   全部答完一次提交（first-answer-wins）；plan=Markdown 正文+批准/拒绝。
 * - 批准类动作的 Authenticator 门禁在回调方（SessionDetailView→AppModel）守门。
 * - 深链预选：EntryAbility 广播 qaqhFocusInteraction → 本组件高亮对应卡片。
 * - 关闭（稍后处理）不撤应答：pending 还在，页面浮标可重开。
 */


/** 弹窗渲染的卡片列表数据源仍是 AppStorage（@StorageLink 直连，无 props 链）。 */
@CustomDialog
export struct ApprovalDialog {
  controller: CustomDialogController;
  @StorageLink(QaqhState.CARDS) cards: ApprovalCardView[] = [];
  @StorageLink(QaqhState.FOCUS_INTERACTION) @Watch('onFocusChanged')
    focusInteraction: string = '';
  @StorageLink(QaqhState.FOCUS_ACTION) focusAction: string = '';
  @State highlightedId: string = '';
  private scroller: Scroller = new Scroller();
  onRespond: (view: PendingInteractionView, approved: boolean) => void =
    (view: PendingInteractionView, approved: boolean) => void view;
  onAnswerAsk: (view: PendingInteractionView, answers: AskAnswer[]) => void =
    (view: PendingInteractionView, answers: AskAnswer[]) => void view;
  onDismiss: (view: PendingInteractionView) => void =
    (view: PendingInteractionView) => void view;
  /** 稍后处理：关弹窗、留 pending（页面浮标重开）。 */
  onDefer: () => void = () => void 0;
  onFocusConsumed: () => void = () => void 0;

  onFocusChanged(): void {
    if (this.focusInteraction.length === 0) {
      return;
    }
    this.highlightedId = this.focusInteraction;
    const index: number = this.findIndex(this.focusInteraction);
    if (index >= 0) {
      this.scroller.scrollToIndex(index, true);
    }
    this.onFocusConsumed();
  }

  private findIndex(interactionId: string): number {
    for (let i = 0; i < this.cards.length; i++) {
      if (this.cards[i].view.interactionId === interactionId) {
        return i;
      }
    }
    return -1;
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
          .fontSize(16)
          .fontColor([$r('sys.color.ohos_id_color_warning')])
        Text(`待处理授权 · ${this.cards.length}`)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
        Blank()
        SymbolGlyph($r('sys.symbol.xmark_circle'))
          .fontSize(18)
          .fontColor([$r('sys.color.ohos_id_color_text_tertiary')])
          .onClick(() => {
            this.onDefer();
          })
      }
      .width('100%')

      if (this.highlightedId.length > 0) {
        Text(`通知入口预选：${this.focusAction === 'approve' ? '允许' :
          (this.focusAction === 'deny' ? '拒绝' : '查看')}——请在卡片上确认`)
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_warning'))
          .width('100%')
      }

      List({ scroller: this.scroller, space: 10 }) {
        ForEach(this.cards, (card: ApprovalCardView) => {
          ListItem() {
            this.approvalCard(card)
          }
          .transition(TransitionEffect.OPACITY
            .animation({ duration: 200, curve: Curve.EaseOut })
            .combine(TransitionEffect.translate({ y: 8 })))
        }, (card: ApprovalCardView) => card.view.interactionId)
      }
      .width('100%')
      .constraintSize({ maxHeight: 520 })
      .scrollBar(BarState.Auto)
      .alignListItem(ListItemAlign.Start)
    }
    .padding(18)
    .width('86%')
    .constraintSize({ maxWidth: 620 })
    .borderRadius($r('sys.float.ohos_id_corner_radius_default_xl'))
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    .shadow({ radius: 24, color: $r('sys.color.ohos_id_shadow_floating_md'),
      offsetX: 0, offsetY: 8 })
  }

  @Builder
  approvalCard(card: ApprovalCardView) {
    Column() {
      if (card.view.remote && card.sessionLabel.length > 0) {
        // 来源会话徽标：聚合卡片必有，先看清是哪个会话再决定批不批。
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.square_grid_2x2'))
            .fontSize(12)
            .fontColor([$r('sys.color.ohos_id_color_text_tertiary')])
          Text(`来自会话 · ${card.sessionLabel}`)
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
        .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
      }
      if (card.view.kind === 'permission') {
        PermissionCardBody({
          card: card,
          onRespond: this.onRespond
        })
      } else if (card.view.kind === 'plan') {
        PlanCardBody({
          card: card,
          onRespond: this.onRespond
        })
      } else if (card.view.kind === 'ask') {
        AskCardBody({
          card: card,
          onAnswerAsk: this.onAnswerAsk,
          onDismiss: this.onDismiss
        })
      } else {
        Column() {
          Text(`交互请求（${card.view.kind}）`)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
          Text(card.body === undefined ? '正文拉取中…' : '（暂不支持的交互形态）')
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .margin({ top: 6 })
          Button('关闭')
            .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .margin({ top: 8 })
            .onClick(() => {
              this.onDismiss(card.view);
            })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .borderRadius($r('sys.float.ohos_id_corner_radius_default_l'))
    .border({
      width: card.view.interactionId === this.highlightedId ? 2 : 1,
      color: card.view.interactionId === this.highlightedId ? '#FF9800' :
        $r('sys.color.ohos_id_color_list_separator')
    })
    .backgroundColor(card.view.interactionId === this.highlightedId
      ? '#FFF3D6' : $r('sys.color.ohos_id_color_sub_background'))
    .width('100%')
  }
}

/** 风险/类别徽章（视觉语义与 TUI 的警示色一致）。 */
function riskLabel(risk: string): string {
  if (risk === 'high') {
    return '高风险';
  }
  if (risk === 'medium') {
    return '中风险';
  }
  return '低风险';
}

function riskColor(risk: string): string {
  if (risk === 'high') {
    return '#C62828';
  }
  if (risk === 'medium') {
    return '#EF6C00';
  }
  return '#2E7D32';
}

function categoryLabel(category: string): string {
  if (category === 'read') {
    return '只读';
  }
  if (category === 'write') {
    return '写入';
  }
  if (category === 'exec') {
    return '执行';
  }
  if (category === 'net') {
    return '联网';
  }
  return category;
}

@Component
struct PermissionCardBody {
  card: ApprovalCardView = new ApprovalCardView(
    new PendingInteractionView('', '', '', '', undefined, 0), undefined);
  onRespond: (view: PendingInteractionView, approved: boolean) => void =
    (view: PendingInteractionView, approved: boolean) => void view;

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
          .fontSize(16)
          .fontColor([riskColor(this.permission().risk)])
        Text(this.permission().toolName)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(riskLabel(this.permission().risk))
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
          .backgroundColor(riskColor(this.permission().risk))
        if (this.permission().category.length > 0) {
          Text(categoryLabel(this.permission().category))
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
            .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
        }
      }
      .width('100%')

      if (this.summary().length > 0) {
        Text(this.summary())
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .width('100%')
      }
      if (this.permission().reason.length > 0) {
        Text(`原因：${this.permission().reason}`)
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
      }
      if (this.permission().consequence.length > 0) {
        Text(`后果：${this.permission().consequence}`)
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .width('100%')
      }

      if (this.permission().paths.length > 0) {
        Column({ space: 2 }) {
          Text(`涉及路径（${this.permission().paths.length}）`)
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          Scroll() {
            Column({ space: 2 }) {
              ForEach(this.permission().paths, (path: string) => {
                Text(path)
                  .fontSize(11)
                  .fontFamily(MONO_FAMILY)
                  .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.MARQUEE })
                  .width('100%')
              }, (path: string, index: number) => `${index}_${path}`)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
          .constraintSize({ maxHeight: 110 })
          .scrollBar(BarState.Auto)
          .align(Alignment.TopStart)
        }
        .alignItems(HorizontalAlign.Start)
        .padding(8)
        .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
        .borderRadius($r('sys.float.ohos_id_corner_radius_default_m'))
        .width('100%')
      }

      Row({ space: 10 }) {
        Button('允许')
          .backgroundColor(toneColor('ok'))
          .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
          .borderRadius($r('sys.float.ohos_id_corner_radius_button'))
          .layoutWeight(1)
          .onClick(() => {
            this.onRespond(this.card.view, true);
          })
        Button('拒绝')
          .backgroundColor(toneColor('bad'))
          .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
          .borderRadius($r('sys.float.ohos_id_corner_radius_button'))
          .layoutWeight(1)
          .onClick(() => {
            this.onRespond(this.card.view, false);
          })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  private permission(): PermissionSnapshot {
    return permissionOf(this.card);
  }

  private summary(): string {
    const body: PermissionSnapshot = this.permission();
    return body.actionSummary.length > 0 ? body.actionSummary : '';
  }
}

/** permission 正文快照（body 缺失时给安全默认，避免渲染期反复判空）。 */
class PermissionSnapshot {
  readonly toolName: string;
  readonly actionSummary: string;
  readonly reason: string;
  readonly paths: string[];
  readonly category: string;
  readonly risk: string;
  readonly consequence: string;

  constructor(toolName: string, actionSummary: string, reason: string, paths: string[],
    category: string, risk: string, consequence: string) {
    this.toolName = toolName;
    this.actionSummary = actionSummary;
    this.reason = reason;
    this.paths = paths;
    this.category = category;
    this.risk = risk;
    this.consequence = consequence;
  }
}

function permissionOf(card: ApprovalCardView): PermissionSnapshot {
  const body = card.body !== undefined ? card.body.permission : undefined;
  if (body === undefined) {
    return new PermissionSnapshot('（正文拉取中）', '', '', [], '', 'low', '');
  }
  return new PermissionSnapshot(body.toolName, body.actionSummary ?? '', body.reason,
    body.paths, body.category, body.risk, body.consequence);
}

@Component
struct PlanCardBody {
  card: ApprovalCardView = new ApprovalCardView(
    new PendingInteractionView('', '', '', '', undefined, 0), undefined);
  onRespond: (view: PendingInteractionView, approved: boolean) => void =
    (view: PendingInteractionView, approved: boolean) => void view;

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.list_bullet_square'))
          .fontSize(15)
          .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
        Text('计划审核')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
        Blank()
        Text(reviewTypeLabel(this.reviewType()))
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
      }
      .width('100%')

      Scroll() {
        // 计划正文按 Markdown 渲（模型给的多半就是 markdown）。
        Markdown({ text: this.planContent(), controller: qaqhMarkdown() })
          .width('100%')
      }
      .constraintSize({ maxHeight: 220 })
      .scrollBar(BarState.Auto)
      .align(Alignment.TopStart)
      .padding(8)
      .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
      .borderRadius($r('sys.float.ohos_id_corner_radius_default_m'))
      .width('100%')

      Row({ space: 10 }) {
        Button('批准计划')
          .backgroundColor(toneColor('ok'))
          .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
          .borderRadius($r('sys.float.ohos_id_corner_radius_button'))
          .layoutWeight(1)
          .onClick(() => {
            this.onRespond(this.card.view, true);
          })
        Button('拒绝')
          .backgroundColor(toneColor('bad'))
          .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
          .borderRadius($r('sys.float.ohos_id_corner_radius_button'))
          .layoutWeight(1)
          .onClick(() => {
            this.onRespond(this.card.view, false);
          })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  private planContent(): string {
    const plan = this.card.body !== undefined ? this.card.body.plan : undefined;
    if (plan === undefined) {
      return this.card.body === undefined ? '正文拉取中…' : '（空计划）';
    }
    return plan.planContent.length > 0 ? plan.planContent : '（空计划）';
  }

  private reviewType(): string {
    const plan = this.card.body !== undefined ? this.card.body.plan : undefined;
    return plan !== undefined ? plan.reviewType : 'plan';
  }
}

function reviewTypeLabel(reviewType: string): string {
  if (reviewType === 'todo_activation') {
    return '启动计划';
  }
  return '方案评审';
}

@Component
struct AskCardBody {
  card: ApprovalCardView = new ApprovalCardView(
    new PendingInteractionView('', '', '', '', undefined, 0), undefined);
  onAnswerAsk: (view: PendingInteractionView, answers: AskAnswer[]) => void =
    (view: PendingInteractionView, answers: AskAnswer[]) => void view;
  onDismiss: (view: PendingInteractionView) => void =
    (view: PendingInteractionView) => void view;
  @State page: number = 0;
  @State answers: Record<string, string> = {};
  @State customDraft: string = '';

  build() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.questionmark_circle'))
          .fontSize(15)
          .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
        Text('提问')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
        Blank()
        if (this.questions().length > 1) {
          Row({ space: 2 }) {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(16)
              .fontColor([this.page > 0
                ? $r('sys.color.ohos_id_color_text_primary_activated')
                : $r('sys.color.ohos_id_color_text_tertiary')])
              .padding(6)
              .onClick(() => {
                if (this.page > 0) {
                  this.getUIContext().animateTo(
                    { duration: 200, curve: curves.springMotion(0.35, 0.8) },
                    (): void => {
                      this.page--;
                    });
                }
              })
            Text(`${this.page + 1}/${this.questions().length}`)
              .fontSize(12)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(16)
              .fontColor([this.page < this.questions().length - 1
                ? $r('sys.color.ohos_id_color_text_primary_activated')
                : $r('sys.color.ohos_id_color_text_tertiary')])
              .padding(6)
              .onClick(() => {
                if (this.page < this.questions().length - 1) {
                  this.getUIContext().animateTo(
                    { duration: 200, curve: curves.springMotion(0.35, 0.8) },
                    (): void => {
                      this.page++;
                    });
                }
              })
          }
        }
      }
      .width('100%')

      if (this.current() !== undefined) {
        Text(this.current()!.question)
          .fontSize(13)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .width('100%')

        Column({ space: 4 }) {
          ForEach(this.current()!.options, (option: string, index: number) => {
            Row({ space: 8 }) {
              SymbolGlyph(this.isSelected(this.current()!.id, option)
                ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
                .fontSize(15)
                .fontColor([this.isSelected(this.current()!.id, option)
                  ? $r('sys.color.ohos_id_color_text_primary_activated')
                  : $r('sys.color.ohos_id_color_text_tertiary')])
              Text(option)
                .fontSize(13)
                .fontColor(this.isSelected(this.current()!.id, option)
                  ? $r('sys.color.ohos_id_color_text_primary_activated')
                  : $r('sys.color.ohos_id_color_text_primary'))
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 10, bottom: 10 })
            .borderRadius($r('sys.float.ohos_id_corner_radius_default_m'))
            .backgroundColor(this.isSelected(this.current()!.id, option)
              ? '#1A3861FF'
              : $r('sys.color.ohos_id_color_list_card_bg'))
            .animation({ duration: 150, curve: Curve.EaseOut })
            .onClick(() => {
              this.pick(this.current()!.id, option);
            })
          }, (option: string, index: number) => `${index}_${option}`)

          if (this.current()!.allowCustom) {
            Row({ space: 8 }) {
              TextInput({ text: this.customDraft, placeholder: '自定义回答…' })
                .fontSize(12)
                .layoutWeight(1)
                .onChange((value: string) => {
                  this.customDraft = value;
                })
              Button('采用')
                .fontSize(12)
                .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
                .fontColor(Color.White)
                .onClick(() => {
                  if (this.customDraft.trim().length > 0 && this.current() !== undefined) {
                    this.pick(this.current()!.id, this.customDraft.trim());
                    this.customDraft = '';
                  }
                })
            }
            .width('100%')
          }
        }
        .width('100%')
      }

      Row({ space: 10 }) {
        Button('不作答')
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .fontSize(13)
          .borderRadius($r('sys.float.ohos_id_corner_radius_button'))
          .layoutWeight(1)
          .onClick(() => {
            this.onDismiss(this.card.view);
          })
        Button(this.canSubmit() ? '提交回答' : this.unansweredCountLabel())
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          .fontColor(Color.White)
          .fontSize(13)
          .borderRadius($r('sys.float.ohos_id_corner_radius_button'))
          .layoutWeight(2)
          .enabled(this.canSubmit())
          .onClick(() => {
            this.submit();
          })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  private questions(): AskQuestionSnapshot[] {
    return askQuestions(this.card);
  }

  private current(): AskQuestionSnapshot | undefined {
    const list: AskQuestionSnapshot[] = this.questions();
    if (list.length === 0 || this.page >= list.length) {
      return list.length > 0 ? list[list.length - 1] : undefined;
    }
    return list[this.page];
  }

  private isSelected(questionId: string, option: string): boolean {
    return this.answers[questionId] === option;
  }

  private pick(questionId: string, option: string): void {
    const next: Record<string, string> = {};
    const keys: string[] = Object.keys(this.answers);
    for (const key of keys) {
      next[key] = this.answers[key];
    }
    next[questionId] = option;
    this.answers = next;
    // 答完当前题自动翻到下一未答题（TUI 的 batch 语义，触屏更顺手）。
    const list: AskQuestionSnapshot[] = this.questions();
    if (this.page < list.length - 1) {
      this.page++;
    }
  }

  private answeredCount(): number {
    let n: number = 0;
    for (const question of this.questions()) {
      if (this.answers[question.id] !== undefined) {
        n++;
      }
    }
    return n;
  }

  private canSubmit(): boolean {
    const total: number = this.questions().length;
    return total > 0 && this.answeredCount() === total;
  }

  private unansweredCountLabel(): string {
    const left: number = this.questions().length - this.answeredCount();
    return `${left} 题未答`;
  }

  private submit(): void {
    const out: AskAnswer[] = [];
    for (const question of this.questions()) {
      const answer: string | undefined = this.answers[question.id];
      if (answer !== undefined) {
        out.push(new AskAnswer(question.id, answer));
      }
    }
    this.onAnswerAsk(this.card.view, out);
  }
}

/** ask 问题快照（body 缺失时为空数组，卡片显示拉取中占位）。 */
class AskQuestionSnapshot {
  readonly id: string;
  readonly question: string;
  readonly options: string[];
  readonly allowCustom: boolean;

  constructor(id: string, question: string, options: string[], allowCustom: boolean) {
    this.id = id;
    this.question = question;
    this.options = options;
    this.allowCustom = allowCustom;
  }
}

function askQuestions(card: ApprovalCardView): AskQuestionSnapshot[] {
  const out: AskQuestionSnapshot[] = [];
  const ask = card.body !== undefined ? card.body.ask : undefined;
  if (ask !== undefined) {
    for (const question of ask.questions) {
      out.push(new AskQuestionSnapshot(question.id, question.question,
        question.options, question.allowCustom));
    }
  }
  return out;
}
