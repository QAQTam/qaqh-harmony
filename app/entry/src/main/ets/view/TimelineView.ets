/**
 * 正文渲染视图（M8.1 视觉打磨）：LazyForEach + @Observed 行视图模型 +
 * HarmonyOS 设计原语。
 *
 * - 颜色/文字层级迁移到 `sys.color.ohos_id_*`（深色模式自适应），业务语义
 *   色（运行/成功/失败）集中在 QaqhTheme；
 * - 图标换 HarmonyOS Symbol（SymbolGlyph，4042 枚系统图标库随字重缩放）；
 * - 动效按鸿蒙运动规范：条目进场 opacity+位移（EaseOut 180ms），
 *   展开/折叠走 springMotion，列表边缘回弹 EdgeEffect.Spring；
 * - Markdown 用共享 MarkdownController（低饱和高亮 + 懒渲染 + 代码块自动折叠）。
 */

import { TranscriptModel, TranscriptRowKind, TodoItemStatus, TodoItemView } from '@qaqh/client';
import { LengthMetrics } from '@kit.ArkUI';
import { Markdown } from '@luvi/lv-markdown-in';
import { RowVm, RowsDataSource } from './TranscriptVm';
import { qaqhMarkdown, qaqhSpring, toneColor, toneBackground, toneLabel,
  QAQH_EXPAND_MS, QAQH_ITEM_ENTER_MS, MONO_FAMILY } from '../theme/QaqhTheme';

/** 工具类别 → HarmonyOS Symbol（本机 SDK sys.symbol 表核对过存在性）。 */
function toolSymbol(name: string): Resource {
  if (name === 'bash' || name === 'exec' || name === 'shell' || name === 'pwsh' ||
    name === 'powershell' || name === 'command') {
    return $r('sys.symbol.play_fill');
  }
  if (name === 'read' || name === 'read_file') {
    return $r('sys.symbol.doc_text');
  }
  if (name === 'edit' || name === 'write' || name === 'create' || name === 'patch') {
    return $r('sys.symbol.square_and_pencil');
  }
  if (name === 'grep' || name === 'search') {
    return $r('sys.symbol.magnifyingglass');
  }
  if (name === 'glob' || name === 'list') {
    return $r('sys.symbol.line_3_horizontal');
  }
  if (name === 'web_fetch' || name === 'fetch') {
    return $r('sys.symbol.cloud');
  }
  if (name.startsWith('todo')) {
    return $r('sys.symbol.list_checkmask');
  }
  return $r('sys.symbol.circle');
}

/** 卡片进场转场：淡入 + 10vp 上浮（新条目出现在底部时的跟随感）。 */
function itemEnter(): TransitionEffect {
  return TransitionEffect.OPACITY
    .animation({ duration: QAQH_ITEM_ENTER_MS, curve: Curve.EaseOut })
    .combine(TransitionEffect.translate({ y: 10 }));
}

/** 展开/折叠转场：淡入淡出 + 裁切高度，spring 收尾。 */
function expandTransition(): TransitionEffect {
  return TransitionEffect.OPACITY
    .animation({ duration: QAQH_EXPAND_MS, curve: qaqhSpring() })
    .combine(TransitionEffect.scale({ x: 1, y: 0.96 }));
}

@Component
export struct TimelineView {
  /** 引用注入（非 @Prop：数据源与模型是行为对象，不做深拷贝）。 */
  dataSource: RowsDataSource = new RowsDataSource();
  model: TranscriptModel | undefined = undefined;
  /** Index 的节流节拍：每次 flush +1，触发视图同步。 */
  @Prop @Watch('onTick') tick: number = 0;
  scroller: Scroller = new Scroller();
  /** 展开/折叠回调（Index 桥到 TranscriptModel.toggleExpanded）。 */
  onToggle: (rowId: string) => void = (rowId: string) => void rowId;
  private atBottom: boolean = true;

  aboutToAppear(): void {
    // 重挂载兜底：tick @Prop 初始化不触发 @Watch，不先 sync 一次会渲成空表。
    this.dataSource.sync();
  }

  onTick(): void {
    const reloaded: boolean = this.dataSource.sync();
    if (reloaded && this.atBottom) {
      this.scroller.scrollEdge(Edge.Bottom);
    }
  }

  build() {
    List({ scroller: this.scroller, space: 6 }) {
      LazyForEach(this.dataSource, (row: RowVm) => {
        ListItem() {
          if (row.kind === TranscriptRowKind.USER) {
            UserBubble({ vm: row })
          } else if (row.kind === TranscriptRowKind.TEXT ||
            row.kind === TranscriptRowKind.NOTICE) {
            AssistantText({ vm: row })
          } else if (row.kind === TranscriptRowKind.THINKING) {
            ThinkingCard({ vm: row, onToggle: this.onToggle })
          } else if (row.kind === TranscriptRowKind.TOOL) {
            ToolCard({ vm: row, onToggle: this.onToggle })
          } else if (row.kind === TranscriptRowKind.TOOL_GROUP) {
            ToolGroupCard({ vm: row, onToggle: this.onToggle })
          } else if (row.kind === TranscriptRowKind.TODO) {
            TodoCard({ vm: row, onToggle: this.onToggle })
          } else {
            MarkerRow({ vm: row })
          }
        }
        .transition(itemEnter())
      }, (row: RowVm) => row.rowId)
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Auto)
    .alignListItem(ListItemAlign.Start)
    .cachedCount(8)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .onScrollIndex((first: number, last: number) => {
      const total: number = this.dataSource.totalCount();
      this.atBottom = total === 0 || last >= total - 2;
    })
  }
}

@Component
struct UserBubble {
  @ObjectLink vm: RowVm;

  build() {
    // 用户消息右对齐气泡。注意：ohos_id_color_primary 是前景黑（深浅反转对），
    // 气泡底色必须用强调色 emphasize（真·系统蓝），文字配 contrary 白。
    Row() {
      Text(this.vm.text)
        .fontSize(15)
        .fontColor(Color.White)
        .lineSpacing(LengthMetrics.vp(5))
        .maxLines(8)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .justifyContent(FlexAlign.End)
    .padding({ left: 14, right: 14, top: 9, bottom: 9 })
    .borderRadius({ topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 4 })
    .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
    .width('94%')
  }
}

@Component
struct AssistantText {
  @ObjectLink vm: RowVm;

  build() {
    if (this.vm.kind === TranscriptRowKind.NOTICE) {
      Text(this.vm.text)
        .fontSize(14)
        .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
        .fontStyle(FontStyle.Italic)
        .lineSpacing(LengthMetrics.vp(6))
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .width('94%')
    } else if (!this.vm.sealed && this.vm.liveOversize) {
      // M13 长文流式降级：等宽 Text 只贴尾部窗口，Markdown Worker 不吃增量——
      // 否则每 150ms flush 全文重 parse，正文越大 CPU 越陡。sealed 后回到
      // 下方 Markdown 一次性全文排版。
      Column({ space: 2 }) {
        Text('长文流式预览 · 完成后自动排版')
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          .padding({ left: 14, right: 14, top: 4 })
          .width('94%')
        Text(this.vm.displayText)
          .fontSize(14)
          .fontFamily(MONO_FAMILY)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .lineSpacing(LengthMetrics.vp(4))
          .padding({ left: 14, right: 14, bottom: 6 })
          .width('94%')
      }
      .width('94%')
    } else {
      // Markdown 渲染（lv-markdown-in + 共享主题控制器）：解析在 Worker、
      // 代码块高亮，@Prop text 更新即增量重渲——逐字流式由 FLUSH_MS 节拍喂给它。
      Markdown({ text: this.vm.text, controller: qaqhMarkdown() })
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .width('94%')
    }
  }
}

@Component
struct ThinkingCard {
  @ObjectLink vm: RowVm;
  onToggle: (rowId: string) => void = (rowId: string) => void rowId;

  build() {
    Column() {
      if (!this.vm.sealed) {
        // 流式期：默认折叠成 3 行滚动窗口（取尾，新行把旧行顶出画面）。
        Row({ space: 8 }) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color($r('sys.color.ohos_id_color_text_tertiary'))
          Text('思考中')
            .fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .fontWeight(FontWeight.Medium)
        }
        .margin({ bottom: 4 })

        if (this.vm.displayText.length > 0) {
          Text(this.vm.displayText)
            .fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
            .lineSpacing(LengthMetrics.vp(4))
            .width('100%')
        }
      } else if (!this.vm.expanded) {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.lightbulb_1'))
            .fontSize(14)
            .fontColor([$r('sys.color.ohos_id_color_text_tertiary')])
          Text(`已思考 · ${this.vm.lineCount} 行`)
            .fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          Text('展开')
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
        }
        .width('100%')
      } else {
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.lightbulb_1'))
            .fontSize(14)
            .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
          Text('思考全文')
            .fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .fontWeight(FontWeight.Medium)
          Blank()
          Text('收起')
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
        }
        .width('100%')
        .margin({ bottom: 4 })

        Scroll() {
          Text(this.vm.text)
            .fontSize(13)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
            .lineSpacing(LengthMetrics.vp(4))
            .width('100%')
        }
        .constraintSize({ maxHeight: 260 })
        .scrollBar(BarState.Auto)
        .align(Alignment.TopStart)
        .transition(expandTransition())
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
    .width('94%')
    .onClick(() => {
      this.onToggle(this.vm.rowId);
    })
  }
}

@Component
struct ToolCard {
  @ObjectLink vm: RowVm;
  onToggle: (rowId: string) => void = (rowId: string) => void rowId;

  build() {
    Column() {
      Row({ space: 8 }) {
        SymbolGlyph(toolSymbol(this.vm.toolName))
          .fontSize(15)
          .fontColor([toneColor(this.vm.tone)])
        Text(this.headerText())
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.vm.tone === 'running') {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(toneColor('running'))
        }
        Text(toneLabel(this.vm.tone))
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
          .backgroundColor(toneColor(this.vm.tone))
      }
      .width('100%')

      if (this.vm.errorText.length > 0) {
        Text(this.vm.errorText)
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_warning'))
          .maxLines(this.vm.expanded ? 12 : 2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })
          .width('100%')
      }

      if (this.vm.bodyText.length > 0) {
        Text(this.vm.bodyText)
          .fontSize(12)
          .fontFamily(MONO_FAMILY)
          .fontColor(this.vm.expanded ? $r('sys.color.ohos_id_color_text_primary')
            : $r('sys.color.ohos_id_color_text_secondary'))
          .maxLines(this.vm.expanded ? 60 : 3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
          .borderRadius($r('sys.float.ohos_id_corner_radius_default_s'))
          .width('100%')
          .transition(expandTransition())
      }

      if (this.vm.hiddenLines > 0 || this.vm.expanded) {
        Text(this.vm.expanded ? '收起' : `… +${this.vm.hiddenLines} 行（点击展开）`)
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          .margin({ top: 4 })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius($r('sys.float.ohos_id_corner_radius_default_l'))
    .border({ width: this.vm.tone === 'ok' ? 0 : 1,
      color: this.vm.tone === 'ok' ? Color.Transparent : toneColor(this.vm.tone) })
    .backgroundColor(toneBackground(this.vm.tone))
    .width('94%')
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      this.onToggle(this.vm.rowId);
    })
  }

  private headerText(): string {
    const running: boolean = this.vm.tone === 'running';
    if (this.vm.target.length > 0) {
      return `${toolVerbOf(this.vm.toolName)} ${this.vm.target}${running ? ' 中…' : ''}`;
    }
    return running ? `${toolVerbOf(this.vm.toolName)} 运行中…` : toolVerbOf(this.vm.toolName);
  }
}

function toolVerbOf(name: string): string {
  if (name === 'bash' || name === 'exec' || name === 'shell' || name === 'pwsh' ||
    name === 'powershell' || name === 'command') {
    return '执行';
  }
  if (name === 'edit') {
    return '编辑';
  }
  if (name === 'write' || name === 'create' || name === 'patch') {
    return '写入';
  }
  if (name === 'read' || name === 'read_file') {
    return '读取';
  }
  if (name === 'grep' || name === 'search') {
    return '搜索';
  }
  if (name === 'glob' || name === 'list') {
    return '列出';
  }
  if (name === 'web_fetch' || name === 'fetch') {
    return '抓取';
  }
  if (name === 'todo_write') {
    return '更新计划';
  }
  if (name === 'todo_update') {
    return '推进待办';
  }
  if (name === 'todo_list') {
    return '列出待办';
  }
  const parts: string[] = name.split(/[_\-.]/);
  const words: string[] = [];
  for (const part of parts) {
    if (part.length > 0) {
      words.push(part.charAt(0).toUpperCase() + part.substring(1));
    }
  }
  return words.join(' ');
}

@Component
struct ToolGroupCard {
  @ObjectLink vm: RowVm;
  onToggle: (rowId: string) => void = (rowId: string) => void rowId;

  build() {
    Column() {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(15)
          .fontColor([toneColor('ok')])
        Text(`${this.vm.groupVerb}了 ${this.vm.memberTargets.length} ${this.vm.groupNoun}`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
        Text('点击展开')
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
      }
      .width('100%')

      Column({ space: 2 }) {
        ForEach(this.previewTargets(), (target: string) => {
          Text(target)
            .fontSize(12)
            .fontFamily(MONO_FAMILY)
            .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }, (target: string, index: number) => `${index}_${target}`)
        if (this.hiddenCount() > 0) {
          Text(`… 还有 ${this.hiddenCount()} 条`)
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 6 })
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius($r('sys.float.ohos_id_corner_radius_default_l'))
    .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
    .width('94%')
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      this.onToggle(this.vm.rowId);
    })
  }

  private hiddenCount(): number {
    return Math.max(0, this.vm.memberTargets.length - 6);
  }

  private previewTargets(): string[] {
    return this.vm.memberTargets.slice(0, 6);
  }
}

@Component
struct TodoCard {
  @ObjectLink vm: RowVm;
  onToggle: (rowId: string) => void = (rowId: string) => void rowId;

  build() {
    Column() {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.list_checkmask'))
          .fontSize(15)
          .fontColor([toneColor('ok')])
        Text(`更新计划 · ${this.vm.todoDone}/${this.vm.todoItems.length} 完成`)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
        Blank()
        Text(this.vm.expanded ? '收起' : '展开')
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
      }
      .width('100%')

      Column({ space: 3 }) {
        ForEach(this.previewItems(), (item: TodoItemView) => {
          TodoItemLine({ item: item })
        }, (item: TodoItemView, index: number) => `${index}_${item.id}_${item.status}`)
        if (this.vm.todoItems.length > 3 && !this.vm.expanded) {
          Text(`… 还有 ${this.vm.todoItems.length - 3} 项（点击展开）`)
            .fontSize(11)
            .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 6 })
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius($r('sys.float.ohos_id_corner_radius_default_l'))
    .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
    .width('94%')
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      this.onToggle(this.vm.rowId);
    })
  }

  private previewItems(): TodoItemView[] {
    return this.vm.expanded ? this.vm.todoItems : this.vm.todoItems.slice(0, 3);
  }
}

@Component
struct TodoItemLine {
  item: TodoItemView = new TodoItemView('', '', TodoItemStatus.PENDING, '');

  build() {
    Row({ space: 6 }) {
      Text(statusGlyph(this.item.status))
        .fontSize(12)
        .fontColor(statusColor(this.item.status))
      Text(this.item.title)
        .fontSize(12)
        .fontColor(this.item.status === TodoItemStatus.COMPLETED
          ? $r('sys.color.ohos_id_color_text_tertiary')
          : $r('sys.color.ohos_id_color_text_primary'))
        .decoration({
          type: this.item.status === TodoItemStatus.COMPLETED ?
            TextDecorationType.LineThrough : TextDecorationType.None,
          color: $r('sys.color.ohos_id_color_text_tertiary')
        })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
  }
}

function statusGlyph(status: string): string {
  if (status === TodoItemStatus.IN_PROGRESS) {
    return '◐';
  }
  if (status === TodoItemStatus.COMPLETED) {
    return '✓';
  }
  if (status === 'cancelled') {
    return '✕';
  }
  return '○';
}

function statusColor(status: string): ResourceColor {
  if (status === TodoItemStatus.IN_PROGRESS) {
    return toneColor('running');
  }
  if (status === TodoItemStatus.COMPLETED) {
    return toneColor('ok');
  }
  return $r('sys.color.ohos_id_color_text_tertiary');
}

@Component
struct MarkerRow {
  @ObjectLink vm: RowVm;

  build() {
    Text(this.vm.text)
      .fontSize(12)
      .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
      .textAlign(TextAlign.Center)
      .width('100%')
      .margin({ top: 6, bottom: 6 })
  }
}
