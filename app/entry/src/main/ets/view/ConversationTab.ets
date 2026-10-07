/**
 * 会话 tab（M9-2）：Navigation 路由容器——平板 Split 双栏（左列表右详情）、
 * 手机 Stack 单栏（push 覆盖），一套代码两端正确。
 *
 * 未连接时是引导空态（去设置），不再把配置表单当开机第一屏——
 * 移动端前端的层级：连接是设置页的事，会话才是主面。
 */

import { RingingSessionListEntry } from '@qaqh/protocol';
import { AppModel, QaqhState } from '../model/AppModel';
import { SessionListView } from './SessionListView';
import { SessionDetailView } from './SessionDetailView';

@Component
export struct ConversationTab {
  /** 悬浮胶囊占位（EntryAbility 按真实安全区回灌，默认 88vp）。 */
  @StorageLink(QaqhState.CAP_SPACE) capSpace: number = 88;
  @StorageLink(QaqhState.CONNECTED) connected: boolean = false;
  @StorageLink(QaqhState.SESSION_ENTRIES) entries: RingingSessionListEntry[] = [];
  @StorageLink(QaqhState.STATUS) statusText: string = '';
  @StorageLink(QaqhState.CREATING) creating: boolean = false;
  @StorageLink(QaqhState.TAB) tab: number = 0;
  /** 左栏 session.list 抽屉开关（AppStorage 单源：详情顶栏的折叠钮写同一个键）。 */
  @StorageLink(QaqhState.NAV_VISIBLE) navVisible: boolean = true;
  /** 分栏判定：横屏且 ≥840vp 才 Split；竖屏平板/手机一律 Stack（Auto 的 600vp 断点会把竖屏切半，右半全白）。 */
  @StorageLink(QaqhState.SPLIT) split: boolean = false;
  /** 当前监视中的会话（选中态与防重入判定的单源）。 */
  @StorageLink(QaqhState.ACTIVE_SESSION) activeId: string = '';
  private pathStack: NavPathStack = new NavPathStack();

  build() {
    Navigation(this.pathStack) {
      Column() {
        if (!this.connected) {
          Column({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.ellipsis_message'))
              .fontSize(44)
              .fontColor([$r('sys.color.ohos_id_color_text_tertiary')])
            Text('还没有连接 daemon')
              .fontSize(16)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
            Text('到「设置」填地址并连接，配对过的设备会自动重连')
              .fontSize(12)
              .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
              .textAlign(TextAlign.Center)
            Button('去设置')
              .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
              .fontColor(Color.White)
              .borderRadius($r('sys.float.ohos_id_corner_radius_button'))
              .margin({ top: 6 })
              .onClick(() => {
                this.tab = 2;
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          SessionListView({
            entries: this.entries,
            statusText: this.statusText,
            creating: this.creating,
            deviceMode: AppModel.instance().usesDeviceIdentity(),
            onSelect: (sessionId: string) => this.openSession(sessionId),
            onCreateSession: () => AppModel.instance().createSession(),
            onAttachSession: (sessionId: string) =>
              AppModel.instance().attachKnownSession(sessionId),
            onDisconnect: () => {
              this.pathStack.clear();
              AppModel.instance().disconnect();
            }
          })
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.capSpace })
    }
    .mode(this.split ? NavigationMode.Split : NavigationMode.Stack)
    .hideTitleBar(true)
    // 折叠走宽度收 0（hideNavBar 会触发目的页重排，连带 onHidden 误杀监视流）。
    .navBarWidthRange(this.split && !this.navVisible ? [0, 0] : [320, 420])
    .navBarWidth(this.split && !this.navVisible ? 0 : 360)
    .navDestination(this.routeMap)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // 分栏判定看宽高比：竖屏平板（885x1400+vp）走 Auto 会被切成"左列表右空白"。
      const w: number = Number(newValue.width);
      const h: number = Number(newValue.height);
      const next: boolean = w >= 840 && w > h * 1.15;
      if (next !== this.split) {
        this.split = next;
      }
      if (!next) {
        // 退回单栏时收起折叠态：Stack 下 navBar 就是列表页，折叠无意义且会白屏。
        this.navVisible = true;
      }
    })
    .width('100%')
    .height('100%')
  }

  private openSession(sessionId: string): void {
    const names: string[] = this.pathStack.getAllPathName();
    const onDetail: boolean =
      names.length > 0 && names[names.length - 1] === 'session';
    if (onDetail && sessionId === this.activeId) {
      // 已在该会话详情：重按不重入（不重复 push、不重建监视流）。
      return;
    }
    AppModel.instance().enterSession(sessionId);
    if (!onDetail) {
      this.pathStack.pushPathByName('session', undefined);
    }
    // 栈顶已是详情但换了会话：detail 全量读 AppStorage，enterSession 换流后原位刷新，无需 push。
  }

  @Builder
  routeMap(name: string) {
    if (name === 'session') {
      NavDestination() {
        SessionDetailView({ pathStack: this.pathStack })
      }
      .hideTitleBar(true)
      .onBackPressed(() => {
        // 系统返回手势/返回键：收监视流、恢复列表抽屉后照常弹栈（return false）。
        // 不用 onHidden——Navigation 重排也会触发它，会误杀在用的监视流。
        AppModel.instance().exitSession();
        this.navVisible = true;
        return false;
      })
    }
  }
}
