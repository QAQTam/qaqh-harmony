/**
 * 移动端 M0 设备配对（镜像 qaqh-ringing/src/v2/types.rs 的 RingingV2Pair* +
 * axum_impl/pairing.rs 的处理器）。
 *
 * 实测契约（scripts/wire-smoke.sh 对真 daemon 验过）：
 * - `POST /ringing/v2/pairing/tokens`（Admin Bearer）→ `{pairing_token,
 *   expires_in_ms:120000, tls_fp}`，令牌 = 2×ULID 拼接（52 字符），内存态、一次性；
 * - `POST /ringing/v2/pair`（**免 Bearer**，公开面）→ `{device_id, device_token,
 *   scope, daemon_version, protocol_version}`；重放 403 `pairing_used`，
 *   伪造 403 `pairing_invalid`，过期 403 `pairing_expired`；
 * - `device_token` 明文只出现这一次，注册表存摘要；此后一切请求只靠它。
 */

import { RINGING_V2_BASE_PATH, isSafeInteger } from './Constants';
import { ProtocolError, parseJson, requiredString, optionalString, requiredNumber,
  optionalNumber }
  from './Json';

/** 配对令牌签发路径（Admin 面）。 */
export function pairingTokensPath(): string {
  return `${RINGING_V2_BASE_PATH}/pairing/tokens`;
}

/** 换设备凭证路径（公开面，不要求 Bearer）。 */
export function pairPath(): string {
  return `${RINGING_V2_BASE_PATH}/pair`;
}

/** scope 档位（wire 值，Ord 递增：view < interact < admin）。 */
export class DeviceScope {
  static readonly VIEW: string = 'view';
  static readonly INTERACT: string = 'interact';
  static readonly ADMIN: string = 'admin';

  static isDeviceScope(value: string): boolean {
    return value === DeviceScope.VIEW || value === DeviceScope.INTERACT ||
      value === DeviceScope.ADMIN;
  }
}

/** `POST /pairing/tokens` 请求体。 */
export class RingingV2PairTokenRequest {
  readonly scopeGrant: string;
  readonly deviceName: string;
  readonly platform: string;

  constructor(scopeGrant: string, deviceName: string, platform: string) {
    this.scopeGrant = scopeGrant;
    this.deviceName = deviceName;
    this.platform = platform;
  }

  toWire(): Record<string, string> {
    return {
      'scope_grant': this.scopeGrant,
      'device_name': this.deviceName,
      'platform': this.platform
    };
  }
}

/** `POST /pairing/tokens` 响应。`tlsFp` = `sha256:<叶证书 DER 的 SHA-256>`。 */
export class RingingV2PairTokenResponse {
  readonly pairingToken: string;
  readonly expiresInMs: number;
  readonly tlsFingerprint: string;

  private constructor(holder: object) {
    this.pairingToken = requiredString(holder, 'pairing_token');
    this.expiresInMs = requiredNumber(holder, 'expires_in_ms');
    this.tlsFingerprint = optionalString(holder, 'tls_fp') ?? '';
  }

  static parse(text: string): RingingV2PairTokenResponse {
    const issued: RingingV2PairTokenResponse =
      new RingingV2PairTokenResponse(parseJson(text));
    if (issued.pairingToken.trim().length === 0 ||
      !isSafeInteger(issued.expiresInMs)) {
      throw new ProtocolError('invalid_pairing_token_response', '');
    }
    return issued;
  }
}

/** `POST /pair` 请求体（免 Bearer，靠一次性 pairing_token 自证）。 */
export class RingingV2PairRequest {
  readonly pairingToken: string;
  readonly deviceName: string;
  readonly platform: string;

  constructor(pairingToken: string, deviceName: string, platform: string) {
    this.pairingToken = pairingToken;
    this.deviceName = deviceName;
    this.platform = platform;
  }

  toWire(): Record<string, string> {
    return {
      'pairing_token': this.pairingToken,
      'device_name': this.deviceName,
      'platform': this.platform
    };
  }
}

/** `POST /pair` 响应。device_token 仅此一次明文下发。 */
export class RingingV2PairResponse {
  readonly deviceId: string;
  readonly deviceToken: string;
  readonly scope: string;
  readonly daemonVersion: string;
  readonly protocolVersion: number;

  private constructor(holder: object) {
    this.deviceId = requiredString(holder, 'device_id');
    this.deviceToken = requiredString(holder, 'device_token');
    this.scope = requiredString(holder, 'scope');
    this.daemonVersion = optionalString(holder, 'daemon_version') ?? '';
    this.protocolVersion = requiredNumber(holder, 'protocol_version');
  }

  static parse(text: string): RingingV2PairResponse {
    const paired: RingingV2PairResponse = new RingingV2PairResponse(parseJson(text));
    if (paired.deviceId.trim().length === 0 || paired.deviceToken.trim().length === 0 ||
      !DeviceScope.isDeviceScope(paired.scope)) {
      throw new ProtocolError('invalid_pair_response', '');
    }
    return paired;
  }
}

/**
 * daemon 错误正文 `{code,message}`（api_error_response 形态）。配对失败要用它
 * 区分 `pairing_used` / `pairing_expired` / `insufficient_scope`，否则 UI 只能说
 * 「403 了」。非 JSON 正文（如未鉴权时的纯文本 `unauthorized`）返回空 code。
 */
export class WireErrorBody {
  readonly code: string;
  readonly message: string;

  private constructor(holder: object) {
    this.code = optionalString(holder, 'code') ?? '';
    this.message = optionalString(holder, 'message') ?? '';
  }

  static parse(text: string): WireErrorBody {
    try {
      return new WireErrorBody(parseJson(text));
    } catch (error) {
      // 非 JSON 错误体（纯文本 unauthorized / 网关 HTML）按形态收下。
      return new WireErrorBody({} as Record<string, string>);
    }
  }
}

/**
 * 桌面端配对二维码 payload（spec §11 第 2 步，桌面壳组装、daemon 不参与）：
 * `{ "v":1, "kind":"qaqh-pair", "base_url":..., "pairing_token":<one-time>,
 *    "tls_fp":"sha256:<hex>", "host_name":str }`。
 *
 * `kind`/`v` 严格校验——扫到别的二维码不能误当配对票；`pairing_token` 一次性
 * 且 TTL 120s。`tls_fp` 是 daemon 证书指纹：NetworkKit http 不支持指纹 pinning
 * （只有 caData/skip），本端消费时只透传给 UI 展示，TLS 信任仍走既有 PEM/跳过
 * 设置——这点 UI 文案必须如实标注。
 */
export class PairQrPayload {
  static readonly KIND: string = 'qaqh-pair';
  static readonly VERSION: number = 1;

  readonly baseUrl: string;
  readonly pairingToken: string;
  readonly tlsFp: string;
  readonly hostName: string;

  private constructor(holder: object) {
    this.baseUrl = requiredString(holder, 'base_url');
    this.pairingToken = requiredString(holder, 'pairing_token');
    this.tlsFp = optionalString(holder, 'tls_fp') ?? '';
    this.hostName = optionalString(holder, 'host_name') ?? '';
  }

  static parse(text: string): PairQrPayload {
    const holder: object = parseJson(text);
    const kind: string = optionalString(holder, 'kind') ?? '';
    const version: number = optionalNumber(holder, 'v') ?? -1;
    if (kind !== PairQrPayload.KIND || version !== PairQrPayload.VERSION) {
      throw new ProtocolError('not_pair_qr', 'scanned code is not a qaqh pair ticket');
    }
    return new PairQrPayload(holder);
  }
}
