/**
 * daemon 访问材料持久化：设备凭证 + 传输信任。
 *
 * device_token 明文只来自 `POST /pair` 那一次响应（daemon 只存摘要），所以本地
 * 这份就是唯一凭据：换机/清除数据 = 重新配对。吊销走 Admin 面
 * `POST /ringing/v2/devices/{id}/revoke`，之后本凭证一律 401。
 *
 * 凭证分两处存（M10 安全升级）：
 * - **device_token 走 Asset Store Kit 关键资产**（系统级加密、按锁屏等级访问控制，
 *   不随普通备份导出）；alias `qaqh.deviceToken`。
 * - 其余非敏感字段（deviceId/scope/baseUrl/证书 PEM）仍走 preferences 沙箱。
 * - **迁移**：老版本把 token 写在 preferences——loadDevice 时发现残留即搬入
 *   关键资产并删掉明文键，一次完成。
 *
 * 证书 PEM 也存 preferences：LAN daemon 的自签证书是配对时的信任锚，SAN 含
 * 服务端 IP，之后每次连接都用它走标准主机名校验（不靠 skipVerify）。
 */

import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';

export class PairedDevice {
  readonly deviceId: string;
  readonly deviceToken: string;
  readonly scope: string;
  /** 配对时的 daemon 地址：换地址即视为另一台 daemon，凭证不复用。 */
  readonly baseUrl: string;

  constructor(deviceId: string, deviceToken: string, scope: string, baseUrl: string) {
    this.deviceId = deviceId;
    this.deviceToken = deviceToken;
    this.scope = scope;
    this.baseUrl = baseUrl;
  }
}

/** 传输信任：自签证书 PEM（空 = 系统 CA）与调试用的跳过校验开关。 */
export class TrustSettings {
  readonly caCertPem: string;
  readonly skipVerify: boolean;

  constructor(caCertPem: string, skipVerify: boolean) {
    this.caCertPem = caCertPem;
    this.skipVerify = skipVerify;
  }

  static defaults(): TrustSettings {
    return new TrustSettings('', false);
  }
}

export class DaemonAccessStore {
  private static readonly STORE_NAME: string = 'qaqh_access';
  private static readonly KEY_DEVICE_ID: string = 'device_id';
  /** 旧明文键：迁移到关键资产后即删除，只保留名字用于清理。 */
  private static readonly KEY_DEVICE_TOKEN_LEGACY: string = 'device_token';
  private static readonly KEY_SCOPE: string = 'scope';
  private static readonly KEY_BASE_URL: string = 'base_url';
  private static readonly KEY_CA_PEM: string = 'ca_cert_pem';
  private static readonly KEY_SKIP_VERIFY: string = 'skip_verify';
  /** 关键资产 alias（值本身是 UTF-8 字节，不是明文键名）。 */
  private static readonly TOKEN_ALIAS: string = 'qaqh.deviceToken';

  private readonly context: common.UIAbilityContext;
  private store: preferences.Preferences | undefined;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /** 使用前预热（load 走同步缓存实例）。 */
  async prime(): Promise<void> {
    this.store = await preferences.getPreferences(this.context,
      { name: DaemonAccessStore.STORE_NAME });
  }

  loadDevice(): PairedDevice | undefined {
    const deviceId: string = this.read(DaemonAccessStore.KEY_DEVICE_ID);
    const deviceToken: string = this.loadToken();
    if (deviceId.length === 0 || deviceToken.length === 0) {
      return undefined;
    }
    return new PairedDevice(deviceId, deviceToken,
      this.read(DaemonAccessStore.KEY_SCOPE), this.read(DaemonAccessStore.KEY_BASE_URL));
  }

  saveDevice(device: PairedDevice): void {
    this.write(DaemonAccessStore.KEY_DEVICE_ID, device.deviceId);
    this.write(DaemonAccessStore.KEY_SCOPE, device.scope);
    this.write(DaemonAccessStore.KEY_BASE_URL, device.baseUrl);
    this.storeToken(device.deviceToken);
    this.flush();
  }

  loadTrust(): TrustSettings {
    return new TrustSettings(this.read(DaemonAccessStore.KEY_CA_PEM),
      this.read(DaemonAccessStore.KEY_SKIP_VERIFY) === 'true');
  }

  saveTrust(trust: TrustSettings): void {
    this.write(DaemonAccessStore.KEY_CA_PEM, trust.caCertPem);
    this.write(DaemonAccessStore.KEY_SKIP_VERIFY, trust.skipVerify ? 'true' : 'false');
    this.flush();
  }

  /** 清除设备凭证（保留证书信任：重配对常是同一台 daemon）。 */
  clearDevice(): void {
    if (this.store === undefined) {
      return;
    }
    this.store.deleteSync(DaemonAccessStore.KEY_DEVICE_ID);
    this.store.deleteSync(DaemonAccessStore.KEY_SCOPE);
    this.store.deleteSync(DaemonAccessStore.KEY_BASE_URL);
    this.flush();
    try {
      const query: asset.AssetMap = DaemonAccessStore.tokenQuery();
      asset.removeSync(query);
    } catch (error) {
      // 资产不存在（从未配对/已清过）按幂等处理。
    }
  }

  /**
   * 读 token：优先关键资产；发现 preferences 里的**旧明文残留**就搬进关键资产
   * 并删掉明文键（一次性迁移，之后明文不再落 preferences）。
   */
  private loadToken(): string {
    const legacy: string = this.read(DaemonAccessStore.KEY_DEVICE_TOKEN_LEGACY);
    if (legacy.length > 0) {
      this.storeToken(legacy);
      this.store?.deleteSync(DaemonAccessStore.KEY_DEVICE_TOKEN_LEGACY);
      this.flush();
      return legacy;
    }
    try {
      const results: asset.AssetMap[] = asset.querySync(DaemonAccessStore.tokenQuery());
      if (results.length === 0) {
        return '';
      }
      const secret: asset.Value | undefined = results[0].get(asset.Tag.SECRET);
      if (secret instanceof Uint8Array) {
        return DaemonAccessStore.decodeUtf8(secret);
      }
      return '';
    } catch (error) {
      // 关键资产不存在（未配对/被系统清除）= 无凭证。
      return '';
    }
  }

  /** 写 token 到关键资产：先 add，已存在（重配对）再 update。 */
  private storeToken(token: string): void {
    const attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attrs.set(asset.Tag.ALIAS,
      DaemonAccessStore.encodeUtf8(DaemonAccessStore.TOKEN_ALIAS));
    attrs.set(asset.Tag.SECRET, DaemonAccessStore.encodeUtf8(token));
    // 首次解锁后即可用：开机自动重连需要的最低访问等级。
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    try {
      asset.addSync(attrs);
    } catch (error) {
      // 已存在（重配对换 token）：update 的载荷不能带 ALIAS（不可更新字段，
      // 真机实测报 Unsupported tag）——查询用 aliasQuery，载荷只放 SECRET。
      const patch: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      patch.set(asset.Tag.SECRET, DaemonAccessStore.encodeUtf8(token));
      asset.updateSync(DaemonAccessStore.aliasQuery(), patch);
    }
  }

  private static aliasQuery(): asset.AssetMap {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS,
      DaemonAccessStore.encodeUtf8(DaemonAccessStore.TOKEN_ALIAS));
    return query;
  }

  private static tokenQuery(): asset.AssetMap {
    const query: asset.AssetMap = DaemonAccessStore.aliasQuery();
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    return query;
  }

  private static encodeUtf8(text: string): Uint8Array {
    return new util.TextEncoder().encodeInto(text);
  }

  private static decodeUtf8(bytes: Uint8Array): string {
    return util.TextDecoder.create('utf-8').decodeToString(bytes);
  }

  private read(key: string): string {
    if (this.store === undefined) {
      return '';
    }
    return this.store.getSync(key, '') as string;
  }

  private write(key: string, value: string): void {
    if (this.store === undefined) {
      return;
    }
    this.store.putSync(key, value);
  }

  private flush(): void {
    if (this.store !== undefined) {
      this.store.flush();
    }
  }
}
