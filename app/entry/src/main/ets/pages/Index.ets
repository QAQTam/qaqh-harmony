/**
 * 主页面（M9-2 移动端外壳）：三 tab + 悬浮胶囊 tabBar。
 *
 * 定位从「监视器」转为移动端前端：
 * - 会话 / 总览 / 设置 三个一级面（Navigation 路由在 ConversationTab 内部，
 *   平板 Split 双栏、手机 Stack 单栏）；
 * - tabBar 抄华为应用市场形态：居中悬浮胶囊 + 毛玻璃 + SymbolGlyph 双态图标
 *   （选中 filled）+ 待审批红点角标，悬浮于底部安全区之上；
 * - Tabs 的 barHeight 收 0，胶囊用 Stack 叠层自绘（通栏 bar 做不出悬浮形态）；
 * - 业务全在 model/AppModel（状态经 AppStorage 广播），本文件只剩壳与节拍。
 */

import { common } from '@kit.AbilityKit';
import { curves } from '@kit.ArkUI';
import { AppModel, QaqhState } from '../model/AppModel';
import { ApprovalCardView } from '../view/ApprovalPanel';
import { ConversationTab } from '../view/ConversationTab';
import { Onboarding } from '../view/Onboarding';
import { OverviewTab } from '../view/OverviewTab';
import { SettingsTab } from '../view/SettingsTab';

@Entry
@Component
struct Index {
  @StorageLink(QaqhState.TAB) currentIndex: number = 0;
  @StorageLink(QaqhState.CARDS) cards: ApprovalCardView[] = [];
  @StorageLink(QaqhState.SAFE_TOP) safeTop: number = 0;
  @StorageLink(QaqhState.SAFE_BOTTOM) safeBottom: number = 0;
  /** 开屏引导门：无配对凭证时整壳换成 Onboarding（默认 true，凭证就绪后翻转）。 */
  @StorageLink(QaqhState.ONBOARD) onboard: boolean = true;
  private controller: TabsController = new TabsController();

  aboutToAppear(): void {
    AppModel.instance().init(getContext(this) as common.UIAbilityContext);
  }

  build() {
    if (this.onboard) {
      this.onboardingGate()
    } else {
      this.mainShell()
    }
  }

  @Builder
  onboardingGate() {
    Onboarding()
  }

  @Builder
  mainShell() {
    Stack({ alignContent: Alignment.Bottom }) {
      Tabs({ barPosition: BarPosition.End, index: this.currentIndex,
        controller: this.controller }) {
        TabContent() {
          ConversationTab()
        }
        .tabBar('')

        TabContent() {
          OverviewTab()
        }
        .tabBar('')

        TabContent() {
          SettingsTab()
        }
        .tabBar('')
      }
      .barHeight(0)
      .barOverlap(false)
      .scrollable(false)
      .animationDuration(240)
      .onChange((index: number) => {
        this.currentIndex = index;
      })
      .width('100%')
      .height('100%')

      this.capsuleBar()
    }
    .padding({ top: this.safeTop })
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
  }

  @Builder
  capsuleBar() {
    Row({ space: 4 }) {
      this.capsuleItem(0, '会话',
        $r('sys.symbol.ellipsis_message'), $r('sys.symbol.ellipsis_message_fill'))
      this.capsuleItem(1, '总览',
        $r('sys.symbol.square_grid_2x2'), $r('sys.symbol.square_grid_2x2'))
      this.capsuleItem(2, '设置',
        $r('sys.symbol.gearshape'), $r('sys.symbol.gearshape_fill'))
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .borderRadius(32)
    .backgroundColor($r('sys.color.ohos_id_color_bottom_tab_bg_blur'))
    .backdropBlur(36)
    .border({ width: 1, color: $r('sys.color.ohos_id_color_list_separator') })
    .shadow({ radius: 18, color: $r('sys.color.ohos_id_shadow_default_md'),
      offsetX: 0, offsetY: 4 })
    // 沉浸式：抬到导航条上方（EntryAbility 回灌的真实 inset）。
    .margin({ bottom: this.safeBottom + 14 })
  }

  @Builder
  capsuleItem(index: number, label: string, icon: Resource, activeIcon: Resource) {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        SymbolGlyph(this.currentIndex === index ? activeIcon : icon)
          .fontSize(23)
          .fontColor([this.currentIndex === index
            ? $r('sys.color.ohos_id_color_bottom_tab_text_on')
            : $r('sys.color.ohos_id_color_bottom_tab_text_off')])
          .symbolEffect(new BounceSymbolEffect(EffectScope.WHOLE,
            EffectDirection.UP), this.currentIndex === index)
        if (index === 0 && this.cards.length > 0) {
          Text(`${this.cards.length}`)
            .fontSize(9)
            .fontColor($r('sys.color.ohos_id_color_text_primary_contrary'))
            .backgroundColor($r('sys.color.ohos_id_color_badge_red'))
            .borderRadius(8)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .offset({ x: 10, y: -4 })
        }
      }

      Text(label)
        .fontSize(10)
        .fontWeight(this.currentIndex === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentIndex === index
          ? $r('sys.color.ohos_id_color_bottom_tab_text_on')
          : $r('sys.color.ohos_id_color_bottom_tab_text_off'))
    }
    .justifyContent(FlexAlign.Center)
    .width(72)
    .height(48)
    .borderRadius(26)
    // 选中项软底：强调色 8% 叠加，在毛玻璃胶囊上读作高亮（深浅色皆可）。
    .backgroundColor(this.currentIndex === index ? '#140A59F7' : Color.Transparent)
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      if (this.currentIndex !== index) {
        // 胶囊切换也走系统弹簧（与应用市场点选手感一致）。
        this.getUIContext().animateTo(
          { duration: 260, curve: curves.springMotion(0.42, 0.9) },
          (): void => {
            this.currentIndex = index;
            this.controller.changeIndex(index);
          });
      }
    })
  }
}
