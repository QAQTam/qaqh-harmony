/**
 * 会话详情（M9.1）：全宽消息流 + 贴底 composer + 授权中心弹窗。
 *
 * 布局决策（用户拍板）：
 * - 移除右侧信息栏——授权改屏幕中心弹窗（遮罩压暗、正文可见），
 *   关闭后留「N 项待授权」浮标重开；计划不再单独占栏，由消息流里
 *   最后一条 todo 卡活渲染（TranscriptModel.lastTodoRowId 语义）；
 * - 正文列限宽 860vp 居中（移动端阅读舒适宽度，大屏不拉成一条直线）；
 * - 左侧 session.list 可折叠：navBarWidth 收 0（M9.1），折叠钮在顶栏。
 * M14 Phase 2：顶栏改悬浮毛玻璃（材质配方与底部胶囊一致），正文从其下
 * 滚动穿过；顶栏内容 = 返回/折叠 + G2 标题 + 模型等宽徽标 + 状态。
 */

import { AskAnswer } from '@qaqh/protocol';
import { PendingInteractionView } from '@qaqh/client';
import { curves } from '@kit.ArkUI';
import { AppModel } from '../model/AppModel';
import { QaqhState } from '../model/QaqhState';
import { ApprovalCardView, ApprovalDialog } from './ApprovalPanel';
import { TimelineView } from './TimelineView';
import { PILL_RADIUS } from './UiKit';
import { MONO_FAMILY } from '../theme/QaqhTheme';

@Component
export struct SessionDetailView {
  /** 悬浮胶囊占位（EntryAbility 按真实安全区回灌，默认 88vp）。 */
  @StorageLink(QaqhState.CAP_SPACE) capSpace: number = 88;
  @StorageLink(QaqhState.SAFE_TOP) safeTop: number = 0;
  pathStack: NavPathStack = new NavPathStack();
  @StorageLink(QaqhState.STATUS) statusText: string = '';
  @StorageLink(QaqhState.TICK) @Watch('onTick') tick: number = 0;
  @StorageLink(QaqhState.ACTIVE_SESSION) activeSession: string = '';
  @StorageLink(QaqhState.ACTIVE_TITLE) activeTitle: string = '';
  @StorageLink(QaqhState.ACTIVE_MODEL) activeModel: string = '';
  @StorageLink(QaqhState.CARDS) @Watch('onCardsChanged') cards: ApprovalCardView[] = [];
  @StorageLink(QaqhState.SENDING) sending: boolean = false;
  @StorageLink(QaqhState.TURN_ACTIVE) turnActive: boolean = false;
  @StorageLink(QaqhState.SEAT_TEXT) seatText: string = '';
  @StorageLink(QaqhState.CAN_LOAD_OLDER) canLoadOlder: boolean = false;
  @StorageLink(QaqhState.NAV_VISIBLE) navVisible: boolean = true;
  @StorageLink(QaqhState.SPLIT) split: boolean = false;
  @StorageLink(QaqhState.FOCUS_INTERACTION) @Watch('onFocusChanged')
    focusInteraction: string = '';
  @State private inputText: string = '';
  @State private viewTick: number = 0;
  @State private pillVisible: boolean = false;
  private dialogVisible: boolean = false;
  private prevCardCount: number = 0;
  private dialogCtrl: CustomDialogController = new CustomDialogController({
    builder: ApprovalDialog({
      onRespond: (item: PendingInteractionView, approved: boolean) =>
        this.model().respond(item, approved),
      onAnswerAsk: (item: PendingInteractionView, answers: AskAnswer[]) =>
        this.model().answerAsk(item, answers),
      onDismiss: (item: PendingInteractionView) => this.model().dismiss(item),
      onDefer: () => this.deferDialog(),
      onFocusConsumed: () => {
        this.model().consumeFocus();
        this.focusInteraction = '';
      }
    }),
    alignment: DialogAlignment.Center,
    autoCancel: false,
    customStyle: true,
    maskColor: 'rgba(0,0,0,0.40)'
  });

  private model(): AppModel {
    return AppModel.instance();
  }

  onTick(): void {
    this.viewTick = this.tick;
  }

  onCardsChanged(): void {
    const count: number = this.cards.length;
    if (count === 0) {
      if (this.dialogVisible) {
        this.dialogVisible = false;
        this.dialogCtrl.close();
      }
      this.pillVisible = false;
    } else if (count > this.prevCardCount) {
      // 新请求到达才自动弹出；已被「稍后处理」压下去的不骚扰。
      this.openDialog();
    }
    this.prevCardCount = count;
  }

  onFocusChanged(): void {
    // 通知深链：直接拉起弹窗并高亮对应卡片（ApprovalDialog 内部消费 focus）。
    if (this.focusInteraction.length > 0) {
      this.openDialog();
    }
  }

  private openDialog(): void {
    this.pillVisible = false;
    if (!this.dialogVisible) {
      this.dialogVisible = true;
      this.dialogCtrl.open();
    }
  }

  private deferDialog(): void {
    this.dialogVisible = false;
    this.dialogCtrl.close();
    if (this.cards.length > 0) {
      this.pillVisible = true;
    }
  }

  private send(): void {
    const text: string = this.inputText;
    this.model().sendInput(text, () => {
      this.inputText = '';
    });
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // 内容层与顶栏叠层：正文从毛玻璃顶栏下滚动穿过（M14 Phase 2）。
      Stack({ alignContent: Alignment.Top }) {
        Column() {
          Column() {
            if (this.canLoadOlder) {
              Button('加载更早的回合')
                .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .fontSize(12)
                .height(30)
                .borderRadius(PILL_RADIUS)
                .margin({ bottom: 4 })
                .onClick(() => {
                  this.model().loadOlderTurns();
                })
            }
            TimelineView({
              dataSource: this.model().rowsSource,
              model: this.model().transcript,
              tick: this.viewTick,
              onToggle: (rowId: string) => this.model().toggleRow(rowId)
            })
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ top: this.safeTop + 56 })
          .alignItems(HorizontalAlign.Center)

          if (this.seatText.length > 0) {
            Text(this.seatText)
              .fontSize(11)
              .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
              .margin({ left: 16, bottom: 2 })
              .width('100%')
          }

          // composer 浮岛：输入 + 操作收进一张圆角浮卡，与列表/设置页的卡片同语言。
          Row({ space: 8 }) {
            TextInput({ text: this.inputText,
              placeholder: this.turnActive ? '回合进行中，输入将排队…' : '输入消息…' })
              .fontSize(14)
              .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
              .borderRadius(PILL_RADIUS)
              .height(40)
              .layoutWeight(1)
              .enabled(!this.sending)
              .onChange((value: string) => {
                this.inputText = value;
              })
              .onSubmit((): void => this.send())
            if (this.turnActive) {
              Button() {
                Row({ space: 4 }) {
                  SymbolGlyph($r('sys.symbol.pause_circle'))
                    .fontSize(16)
                    .fontColor([$r('sys.color.ohos_id_color_warning')])
                  Text('停止')
                    .fontSize(13)
                    .fontColor($r('sys.color.ohos_id_color_text_primary'))
                }
              }
              .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
              .borderRadius(PILL_RADIUS)
              .height(40)
              .enabled(!this.sending)
              .onClick(() => {
                this.model().cancelTurn();
              })
            }
            Button() {
              Row({ space: 4 }) {
                SymbolGlyph($r('sys.symbol.paperplane_fill'))
                  .fontSize(15)
                  .fontColor([Color.White])
                Text('发送')
                  .fontSize(13)
                  .fontColor(Color.White)
              }
            }
            .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
            .borderRadius(PILL_RADIUS)
            .height(40)
            .enabled(!this.sending && this.inputText.trim().length > 0)
            .onClick(() => {
              this.send();
            })
          }
          .padding({ left: 6, right: 6, top: 6, bottom: this.capSpace })
          .borderRadius(26)
          .backgroundColor($r('sys.color.ohos_id_color_background'))
          .shadow({ radius: 12, color: $r('sys.color.ohos_id_shadow_default_xs'),
            offsetX: 0, offsetY: 2 })
          .margin({ left: 12, right: 12, top: 6 })
          .constraintSize({ maxWidth: 860 })
          .width('100%')
        }
        .width('100%')
        .height('100%')

        // 悬浮毛玻璃顶栏：材质配方与底部胶囊一致（blur bg token + backdropBlur），
        // 底缘发丝线分隔，正文滚动下穿时呈毛玻璃。
        Row({ space: 10 }) {
          Button() {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize(15)
                .fontColor([$r('sys.color.ohos_id_color_text_primary')])
              Text('返回')
                .fontSize(13)
                .fontColor($r('sys.color.ohos_id_color_text_primary'))
            }
          }
          .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
          .borderRadius(PILL_RADIUS)
          .height(34)
          .onClick(() => {
            // 自绘返回与系统返回同语义：收监视流 + 恢复列表抽屉 + 弹栈。
            this.model().exitSession();
            this.navVisible = true;
            this.pathStack.pop();
          })

          // 侧栏折叠钮：只在分栏形态出现（Stack 下折叠无意义）。
          if (this.split) {
            SymbolGlyph($r('sys.symbol.rectangle_lefthalf_inset_filled'))
              .fontSize(20)
              .fontColor([this.navVisible
                ? $r('sys.color.ohos_id_color_text_primary_activated')
                : $r('sys.color.ohos_id_color_text_tertiary')])
              .onClick(() => {
                this.getUIContext().animateTo(
                  { duration: 260, curve: curves.springMotion(0.4, 0.9) },
                  (): void => {
                    this.navVisible = !this.navVisible;
                  });
              })
          }

          // 顶栏标题化（M14）：G2 展示标题为主（title → cwd 尾段 → 短 id），
          // 模型名等宽小徽标，右端状态文本——调试工具感让位给产品感。
          Text(this.activeTitle)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.activeModel.length > 0) {
            Text(this.activeModel)
              .fontFamily(MONO_FAMILY)
              .fontSize(11)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .padding({ left: 10, right: 10, top: 3, bottom: 3 })
              .borderRadius(PILL_RADIUS)
              .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 220 })
          }
          Blank()
          Text(this.statusText)
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .constraintSize({ maxWidth: 360 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 12, right: 16, top: this.safeTop + 8, bottom: 8 })
        .backgroundColor($r('sys.color.ohos_id_color_bottom_tab_bg_blur'))
        .backdropBlur(36)
        .border({ width: { bottom: 0.75 },
          color: { bottom: $r('sys.color.ohos_id_color_list_separator') } })
      }
      .width('100%')
      .height('100%')

      // 「稍后处理」后的重开浮标：贴 composer 上方右侧，带角标数。
      if (this.pillVisible && this.cards.length > 0) {
        Button() {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
              .fontSize(15)
              .fontColor([$r('sys.color.ohos_id_color_warning')])
            Text(`${this.cards.length} 项待授权`)
              .fontSize(13)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
          }
        }
        .backgroundColor($r('sys.color.ohos_id_color_card_bg'))
        .borderRadius(20)
        .border({ width: 1, color: $r('sys.color.ohos_id_color_warning') })
        .shadow({ radius: 12, color: $r('sys.color.ohos_id_shadow_default_md'),
          offsetX: 0, offsetY: 3 })
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .margin({ right: 16, bottom: this.capSpace + 64 })
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick(() => {
          this.openDialog();
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
