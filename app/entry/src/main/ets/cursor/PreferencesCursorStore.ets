/**
 * preferences 实现的 cursor 持久化（真机）。每个 seed 一把 key；
 * 值为 CursorToken 的不透明字符串（v2.<base64url>）。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { CursorToken } from '@qaqh/protocol';
import { CursorStore } from '@qaqh/client';

export class PreferencesCursorStore implements CursorStore {
  private readonly context: common.UIAbilityContext;
  private readonly seed: string;
  private store: preferences.Preferences | undefined;

  constructor(context: common.UIAbilityContext, seed: string) {
    this.context = context;
    this.seed = seed;
  }

  /** 连接前预热 preferences 实例，保证 load() 能读到历史 cursor。 */
  async prime(): Promise<void> {
    this.store = await preferences.getPreferences(this.context, { name: 'qaqh_cursor' });
  }

  load(): CursorToken | undefined {
    // load 在订阅建立路径上同步消费：读已预热的缓存实例。
    if (this.store === undefined) {
      return undefined;
    }
    const raw: string = this.store.getSync(`cursor_${this.seed}`, '') as string;
    if (raw.length === 0) {
      return undefined;
    }
    try {
      return CursorToken.fromOpaque(raw);
    } catch (error) {
      return undefined;
    }
  }

  save(token: CursorToken): void {
    if (this.store === undefined) {
      return;
    }
    this.store.putSync(`cursor_${this.seed}`, token.asString());
    this.store.flush();
  }

  clear(): void {
    if (this.store === undefined) {
      return;
    }
    this.store.deleteSync(`cursor_${this.seed}`);
    this.store.flush();
  }
}
