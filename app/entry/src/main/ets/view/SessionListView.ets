/**
 * 会话列表视图（展示组件）：session.list 轮询结果的可视化。
 *
 * 每张卡片 = 一个 daemon 会话：模型、运行状态徽标、消息/轮次计数、最近摘要、
 * 更新时间。点击进入会话监视页；顶部提供 创建会话（session_create）与断开。
 * 数据源已在 AppModel 侧过 visibleSessions（归档/子代理临时会话不进本列表）。
 *
 * M10 形态：卡片列表左右对称（List 统一 16 边距，卡片满宽）、状态徽标胶囊化、
 * 按钮走 UiKit 基元。
 */

import { RingingSessionListEntry } from '@qaqh/protocol';
import { QaqhState } from '../model/QaqhState';
import { Card, GhostButton, PILL_RADIUS, PrimaryButton } from './UiKit';

/** updated_at 兼容秒/毫秒两种量纲，格式化为本地时间。 */
export function formatUpdatedAt(updatedAt: number): string {
  if (updatedAt <= 0) {
    return '';
  }
  const ms: number = updatedAt > 1e12 ? updatedAt : updatedAt * 1000;
  const date = new Date(ms);
  const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
    `${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

@Component
export struct SessionListView {
  @Prop entries: RingingSessionListEntry[] = [];
  @Prop statusText: string = '';
  @Prop creating: boolean = false;
  /** 设备身份：session.list 只列本端已归属的会话，需要手动 attach 入口。 */
  @Prop deviceMode: boolean = false;
  /** 当前监视中的会话 = 列表选中态（AppStorage 单源，AppModel 写）。 */
  @StorageLink(QaqhState.ACTIVE_SESSION) activeId: string = '';
  @State attachInput: string = '';
  onSelect: (sessionId: string) => void = (sessionId: string) => void sessionId;
  onCreateSession: () => void = () => void 0;
  onDisconnect: () => void = () => void 0;
  onAttachSession: (sessionId: string) => void = (sessionId: string) => void sessionId;

  build() {
    Column() {
      Row({ space: 10 }) {
        PrimaryButton({
          label: this.creating ? '创建中…' : '创建会话',
          active: !this.creating,
          weight: 1,
          onAction: (): void => {
            this.onCreateSession();
          }
        })
        GhostButton({
          label: '断开',
          weight: 1,
          onAction: (): void => {
            this.onDisconnect();
          }
        })
      }
      .margin({ left: 16, right: 16, bottom: 12 })
      .width('100%')

      if (this.entries.length === 0) {
        Column({ space: 10 }) {
          SymbolGlyph($r('sys.symbol.ellipsis_message'))
            .fontSize(44)
            .fontColor([$r('sys.color.ohos_id_color_text_tertiary')])
          Text(this.creating ? '会话创建中…' : '暂无可见会话')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          Text(this.deviceMode
            ? '设备身份只能看到自己归属（attach/创建）过的会话；桌面端已有的会话请在下面填 id 归属'
            : '桌面端打开一个会话，或点上方「创建会话」')
            .fontSize(12)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
            .textAlign(TextAlign.Center)

          if (this.deviceMode) {
            Row({ space: 8 }) {
              TextInput({ text: this.attachInput, placeholder: '会话 id（session_id）' })
                .fontSize(12)
                .height(40)
                .borderRadius(PILL_RADIUS)
                .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
                .layoutWeight(1)
                .onChange((value: string) => {
                  this.attachInput = value;
                })
              Button('归属')
                .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
                .fontColor(Color.White)
                .fontSize(13)
                .height(40)
                .borderRadius(PILL_RADIUS)
                .onClick(() => {
                  const sessionId: string = this.attachInput.trim();
                  if (sessionId.length > 0) {
                    this.onAttachSession(sessionId);
                    this.attachInput = '';
                  }
                })
            }
            .margin({ top: 12 })
            .width('80%')
          }
        }
        .padding({ left: 24, right: 24 })
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.entries, (entry: RingingSessionListEntry) => {
            ListItem() {
              this.sessionCard(entry)
            }
          }, (entry: RingingSessionListEntry) => entry.sessionId)
        }
        .layoutWeight(1)
        .padding({ left: 16, right: 16 })
        .width('100%')
        .scrollBar(BarState.Auto)
        .alignListItem(ListItemAlign.Start)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
  }

  @Builder
  sessionCard(entry: RingingSessionListEntry) {
    Column() {
      Row({ space: 8 }) {
        Text(entry.running ? '运行中' : '空闲')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(entry.running
            ? $r('sys.color.ohos_id_color_emphasize')
            : $r('sys.color.ohos_id_color_text_tertiary'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(PILL_RADIUS)
          .backgroundColor(entry.running
            ? '#1A3861FF'
            : $r('sys.color.ohos_id_color_button_normal'))
        // 标题按后端 G2 口径（title → cwd 尾段 → 短 id）；模型名挪去副行。
        Text(entry.displayTitle())
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([$r('sys.color.ohos_id_color_text_tertiary')])
      }
      .width('100%')

      if (entry.model !== undefined && entry.model.length > 0) {
        Text(entry.model)
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
          .width('100%')
      }

      if (entry.lastSummary !== undefined && entry.lastSummary.length > 0) {
        Text(entry.lastSummary)
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })
          .width('100%')
      }

      Row() {
        Text(`消息 ${entry.messageCount} · 轮次 ${entry.turnCount}`)
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
        Blank()
        Text(formatUpdatedAt(entry.updatedAt))
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .borderRadius(20)
    // 选中态（M14）：当前监视会话 = 强调色 8% 底 + 描边（与胶囊选中同配方，
    // 深浅色皆可）；未选中 = 发丝线卡面（阴影白名单收口，阴影不进内容卡）。
    .backgroundColor(this.activeId === entry.sessionId
      ? '#140A59F7'
      : $r('sys.color.ohos_id_color_background'))
    .border(this.activeId === entry.sessionId
      ? { width: 1.5, color: $r('sys.color.ohos_id_color_emphasize') }
      : { width: 1, color: $r('sys.color.ohos_id_color_list_separator') })
    .hoverEffect(HoverEffect.Highlight)
    .width('100%')
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      this.onSelect(entry.sessionId);
    })
  }
}
