/**
 * 开屏引导（M14）：无已配对凭证时替代主壳的第一屏。
 *
 * 交互设计（用户拍板「扫码鉴权在开屏处」）：
 * - 首选扫码配对（桌面端「设备配对」二维码，一步换长期设备凭证）；
 * - 兜底手动：地址 + Admin token（与设置页同一套 AppModel 路径）；
 * - 「跳过」出口：不配对也能进主壳（会话页空态会引导去设置）；
 * - 配对成功即 finishOnboarding()：收本屏 + 直接 connect()。
 */

import { common } from '@kit.AbilityKit';
import { AppModel } from '../model/AppModel';
import { QaqhState } from '../model/QaqhState';
import { GhostButton, PrimaryButton, INPUT_HEIGHT, PILL_RADIUS } from './UiKit';

@Component
export struct Onboarding {
  @StorageLink(QaqhState.STATUS) statusText: string = '';
  @StorageLink(QaqhState.PAIRING) pairing: boolean = false;
  @StorageLink(QaqhState.BASE_URL) baseUrl: string = '';
  @StorageLink(QaqhState.TOKEN) adminToken: string = '';
  @StorageLink(QaqhState.SAFE_TOP) safeTop: number = 0;

  private model(): AppModel {
    return AppModel.instance();
  }

  build() {
    // 宽屏居中：620vp 内容列浮在画布正中（平板分屏/全屏都成立）。
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 14 }) {
      Blank().layoutWeight(1)

      SymbolGlyph($r('sys.symbol.ellipsis_message_fill'))
        .fontSize(56)
        .fontColor([$r('sys.color.ohos_id_color_emphasize')])
      Text('QAQ-Harness')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
      Text('扫码配对电脑端 daemon，手机即驾驶舱')
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))

      Blank().layoutWeight(1)

      PrimaryButton({ label: this.pairing ? '配对中…' : '扫码配对',
        active: !this.pairing, weight: 1,
        onAction: (): void => this.model().pairViaScan() })
      Text('扫桌面端「设备配对」页生成的二维码（120 秒有效）')
        .fontSize(11)
        .fontColor($r('sys.color.ohos_id_color_text_tertiary'))

      Row({ space: 10 }) {
        Divider().layoutWeight(1)
          .color($r('sys.color.ohos_id_color_list_separator'))
        Text('或手动配对')
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
        Divider().layoutWeight(1)
          .color($r('sys.color.ohos_id_color_list_separator'))
      }
      .width('100%')

      TextInput({ text: this.baseUrl, placeholder: 'daemon 地址（https://host:port）' })
        .fontSize(14)
        .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
        .borderRadius(PILL_RADIUS)
        .height(INPUT_HEIGHT)
        .width('100%')
        .onChange((value: string) => {
          this.baseUrl = value;
        })
      TextInput({ text: this.adminToken, placeholder: 'Admin token（一次性，配对后即换设备凭证）' })
        .fontSize(14)
        .type(InputType.Password)
        .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
        .borderRadius(PILL_RADIUS)
        .height(INPUT_HEIGHT)
        .width('100%')
        .onChange((value: string) => {
          this.adminToken = value;
        })
      GhostButton({ label: '手动配对', active: !this.pairing, weight: 1,
        onAction: (): void => this.model().pairDevice() })

      if (this.statusText.length > 0) {
        Text(this.statusText)
          .fontSize(12)
          .fontColor($r('sys.color.ohos_id_color_text_secondary'))
          .constraintSize({ maxWidth: 620 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .alignSelf(ItemAlign.Center)
      }

      Text('跳过，稍后在设置里配置')
        .fontSize(12)
        .fontColor($r('sys.color.ohos_id_color_text_hyperlink'))
        .padding(10)
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick(() => {
          this.model().skipOnboarding();
        })
    }
    .padding({ left: 28, right: 28, top: this.safeTop + 24, bottom: 32 })
    .constraintSize({ maxWidth: 620 })
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_sub_background'))
  }
}
