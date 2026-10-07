/**
 * UiKit（M10 UI 打磨）：壳层界面的统一形态基元。
 *
 * 为什么单开一个文件：卡片圆角/内边距/阴影、区块标题、输入框与按钮的
 * 尺寸此前散在各视图里逐处手写（default_l / 手抽数字混用），形态漂移
 * 就是这么来的。收敛成三个基元 + 一组常量，各视图只引用不再自定：
 * - `Card`：内容卡（统一圆角 20 / 内边距 16 / 发丝线分层〔M14 阴影白名单：
 *   阴影只留给真悬浮物〕/ 起始对齐 / hover 反馈）；
 * - `SectionHeader`：卡内区块标题（小号 secondary 字，可选图标）；
 * - `PrimaryButton` / `GhostButton`：主次两种按钮（统一高度/胶囊圆角/字号），
 *   消灭「强调色实底 + button token 圆角 + 默认高度」的手写组合漂移。
 *
 * 颜色一律用系统 token（深浅色自适应）；正文字渲染（TimelineView 气泡）
 * 不在此收口，保持 M8 的阅读宽度契约。
 */

/** 内容卡统一圆角（vp）。 */
export const CARD_RADIUS: number = 20;
/** 胶囊元素（徽标/小按钮）统一圆角：任意宽高下都是全圆。 */
export const PILL_RADIUS: number = 999;
/** 表单输入统一高度。 */
export const INPUT_HEIGHT: number = 44;
/** 主/次按钮统一高度。 */
export const BUTTON_HEIGHT: number = 40;

@Builder
function cardEmpty(): void {
}

@Component
export struct Card {
  @BuilderParam content: () => void = cardEmpty;

  build() {
    Column() {
      this.content()
    }
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .borderRadius(CARD_RADIUS)
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    // 阴影白名单（M14）：阴影只留给真悬浮物（composer/胶囊/弹窗/浮标），
    // 内容卡用发丝线分层，深浅色自适应。
    .border({ width: 1, color: $r('sys.color.ohos_id_color_list_separator') })
    .hoverEffect(HoverEffect.Highlight)
    .width('100%')
  }
}

@Component
export struct SectionHeader {
  @Prop title: string = '';
  /** 可选前导图标；不传就是纯文字标题。 */
  @Prop icon: Resource | undefined = undefined;

  build() {
    Row({ space: 6 }) {
      if (this.icon !== undefined) {
        SymbolGlyph(this.icon)
          .fontSize(14)
          .fontColor([$r('sys.color.ohos_id_color_text_secondary')])
      }
      Text(this.title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
    }
  }
}

@Component
export struct PrimaryButton {
  @Prop label: string = '';
  @Prop active: boolean = true;
  /** 在 Row 里占满剩余宽度（自定义组件不支持外部链通用属性，走 prop 收口）。 */
  @Prop weight: number = 0;
  onAction: () => void = () => void 0;

  build() {
    Button(this.label)
      .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
      .fontColor(Color.White)
      .fontSize(14)
      .height(BUTTON_HEIGHT)
      .borderRadius(PILL_RADIUS)
      .enabled(this.active)
      .clickEffect({ level: ClickEffectLevel.LIGHT })
      .width('100%')
      .layoutWeight(this.weight)
      .onClick(() => {
        this.onAction();
      })
  }
}

@Component
export struct GhostButton {
  @Prop label: string = '';
  @Prop active: boolean = true;
  @Prop weight: number = 0;
  onAction: () => void = () => void 0;

  build() {
    Button(this.label)
      .backgroundColor($r('sys.color.ohos_id_color_button_normal'))
      .fontColor($r('sys.color.ohos_id_color_text_primary'))
      .fontSize(14)
      .height(BUTTON_HEIGHT)
      .borderRadius(PILL_RADIUS)
      .enabled(this.active)
      .clickEffect({ level: ClickEffectLevel.LIGHT })
      .width('100%')
      .layoutWeight(this.weight)
      .onClick(() => {
        this.onAction();
      })
  }
}
