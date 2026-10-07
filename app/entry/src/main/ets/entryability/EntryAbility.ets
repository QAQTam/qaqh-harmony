/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display, window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

/** 悬浮胶囊净高 60 + 距底余量 16 + 安全区下方再留 12：内容页据此留 padding-bottom。 */
const CAPSULE_SPACE_BASE: number = 88;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    this.routeFocus(want);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.routeFocus(want);
  }

  /** 通知深链回路由：把目标交互广播给页面（AppStorage）。 */
  private routeFocus(want: Want): void {
    const parameters: Record<string, Object> | undefined =
      want.parameters as Record<string, Object>;
    if (parameters === undefined) {
      return;
    }
    const interactionId: Object | undefined = parameters['interaction_id'];
    if (typeof interactionId === 'string' && interactionId.length > 0) {
      AppStorage.setOrCreate('qaqhFocusInteraction', interactionId);
      const action: Object | undefined = parameters['qaqh_action'];
      if (typeof action === 'string' && action.length > 0) {
        AppStorage.setOrCreate('qaqhFocusAction', action);
      }
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    this.registerCustomFonts(windowStage);
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
    this.makeImmersive(windowStage);
  }

  /**
   * 沉浸式：窗口铺满（含底部导航条区域，消灭"小白条"），把系统安全区高度
   * （vp）写进 AppStorage——顶部栏加 padding、悬浮胶囊按真实 inset 抬升，
   * 转屏/折叠经 avoidAreaChange 实时回灌。
   */
  private makeImmersive(windowStage: window.WindowStage): void {
    windowStage.getMainWindow().then((win: window.Window) => {
      win.setWindowLayoutFullScreen(true);
      this.publishAvoidArea(win);
      win.on('avoidAreaChange', () => {
        this.publishAvoidArea(win);
      });
    }).catch((error: Error) => {
      hilog.error(DOMAIN, 'testTag', 'immersive setup failed: %{public}s', error.message);
    });
  }

  private publishAvoidArea(win: window.Window): void {
    const density: number = display.getDefaultDisplaySync().densityPixels;
    const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const safeTop: number = area.topRect.height / density;
    const safeBottom: number = area.bottomRect.height / density;
    AppStorage.setOrCreate('qaqhSafeTop', safeTop);
    AppStorage.setOrCreate('qaqhSafeBottom', safeBottom);
    AppStorage.setOrCreate('qaqhCapSpace', CAPSULE_SPACE_BASE + safeBottom);
  }

  /**
   * 自定义字体注册（M13）：Cascadia Mono（SIL OFL 1.1，许可文本随字体一起
   * 打包在 rawfile/fonts/）承载全部等宽消费点——工具输出/错误、路径列表、
   * 长文流式降级视图、id/探针读数。中文字形不在覆盖范围，缺字按 glyph 回落
   * 系统字体，中英混排无豆腐块。注册失败只记日志：fontFamily 消费点带
   * `monospace` 二级回退，不阻塞启动。
   */
  private registerCustomFonts(windowStage: window.WindowStage): void {
    try {
      const font = windowStage.getMainWindowSync().getUIContext().getFont();
      font.registerFont({
        familyName: 'CascadiaMono',
        familySrc: $rawfile('fonts/CascadiaMono-Regular.ttf')
      });
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'registerFont failed: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}