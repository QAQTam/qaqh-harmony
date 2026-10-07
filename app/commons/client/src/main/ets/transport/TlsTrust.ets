/**
 * HTTPS 信任配置（daemon 非回环 bind 已强制 TLS）。
 *
 * 后端 LAN 模式用持久化自签证书（`<数据根>/tls/cert.pem`），SAN 含服务端 IP，
 * 所以标准校验链是可行的主路径：把证书 PEM 交给 `caData`，主机名/链路照常校验。
 * `skipVerify` 只是调试兜底——它会连 MITM 一起跳过，UI 必须标注风险。
 */

import { http } from '@kit.NetworkKit';

export class TlsTrust {
  /** 服务端证书 PEM（自签时即信任锚）；空串表示不追加自定义 CA。 */
  readonly caCertPem: string;
  /** true = `remoteValidation:'skip'`，跳过服务端身份校验（仅调试）。 */
  readonly skipVerify: boolean;

  constructor(caCertPem: string, skipVerify: boolean) {
    this.caCertPem = caCertPem;
    this.skipVerify = skipVerify;
  }

  static none(): TlsTrust {
    return new TlsTrust('', false);
  }

  /** http 与 requestInStream 共用 HttpRequestOptions，故一处应用。 */
  applyTo(options: http.HttpRequestOptions): void {
    if (this.caCertPem.length > 0) {
      options.caData = this.caCertPem;
    }
    if (this.skipVerify) {
      options.remoteValidation = 'skip';
    }
  }
}
