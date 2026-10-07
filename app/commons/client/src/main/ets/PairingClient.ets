/**
 * 设备配对客户端（移动端 M0）。
 *
 * 与 RingingClient 分开：配对面**不走 lease/open 状态机**——`/pair` 是公开端点，
 * `/pairing/tokens` 只要 Bearer。整条链路是一次性的：换到 device_token 后持久化，
 * 之后一切请求只用它（daemon 在跑即可，桌面端不必在线）。
 */

import {
  DeviceScope, pairPath, pairingTokensPath, PairQrPayload, RingingV2PairRequest,
  RingingV2PairResponse,
  RingingV2PairTokenRequest, RingingV2PairTokenResponse, WireErrorBody
} from '@qaqh/protocol';
import { Transport, TransportRequest, TransportResponse, TransportError }
  from './transport/Transport';

/** 配对失败（带 daemon 回的 code，便于 UI 区分 used/expired/invalid/scope）。 */
export class PairingError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(code: string, status: number, detail: string) {
    super(detail.length > 0 ? `${code}: ${detail}` : code);
    this.code = code;
    this.status = status;
  }
}

export class PairingClient {
  private readonly transport: Transport;
  private readonly baseUrl: string;

  constructor(transport: Transport, baseUrl: string) {
    this.transport = transport;
    this.baseUrl = baseUrl;
  }

  /**
   * `POST /ringing/v2/pairing/tokens`。用 Admin 凭据（本机手填一次）签一次性配对
   * 令牌。手动配对路径——桌面端 QR 已可用时优先 `pairWithQr`（免手填 token）。
   * 换到设备令牌后 Admin 凭据即可丢弃。
   */
  async issuePairingToken(adminToken: string, deviceName: string,
    scopeGrant?: string): Promise<RingingV2PairTokenResponse> {
    const request: RingingV2PairTokenRequest = new RingingV2PairTokenRequest(
      scopeGrant !== undefined ? scopeGrant : DeviceScope.INTERACT, deviceName, 'harmony');
    const response: TransportResponse = await this.post(pairingTokensPath(),
      this.bearerHeaders(adminToken), JSON.stringify(request.toWire()));
    return RingingV2PairTokenResponse.parse(response.body);
  }

  /** `POST /ringing/v2/pair`（免 Bearer）。一次性令牌 → 长期 device_token。 */
  async pair(pairingToken: string, deviceName: string): Promise<RingingV2PairResponse> {
    const request: RingingV2PairRequest = new RingingV2PairRequest(
      pairingToken, deviceName, 'harmony');
    const response: TransportResponse = await this.post(pairPath(),
      this.contentTypeOnlyHeaders(), JSON.stringify(request.toWire()));
    return RingingV2PairResponse.parse(response.body);
  }

  /** 一步到位：签发 + 兑换（令牌 TTL 120s，同进程内串起来没有窗口问题）。 */
  async pairWithAdminToken(adminToken: string,
    deviceName: string): Promise<RingingV2PairResponse> {
    const issued: RingingV2PairTokenResponse =
      await this.issuePairingToken(adminToken, deviceName);
    return this.pair(issued.pairingToken, deviceName);
  }

  /**
   * 扫码配对：消费桌面端 QR payload（spec §11 第 2 步，含 base_url + 一次性
   * pairing_token），直接对 payload 自带的 baseUrl 走 `/pair`。scope 由桌面端
   * grant 决定，本端不再传。TLS 信任按调用方传入的 transport 现有设置执行
   * （见 PairQrPayload.tlsFp 的注释——指纹 pinning 本端暂不支持）。
   */
  static async pairWithQr(transport: Transport, qr: PairQrPayload,
    deviceName: string): Promise<RingingV2PairResponse> {
    const client: PairingClient = new PairingClient(transport, qr.baseUrl);
    return client.pair(qr.pairingToken, deviceName);
  }

  private bearerHeaders(token: string): Record<string, string> {
    let headers: Record<string, string> = {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json'
    };
    return headers;
  }

  private contentTypeOnlyHeaders(): Record<string, string> {
    let headers: Record<string, string> = {
      'Content-Type': 'application/json'
    };
    return headers;
  }

  private async post(path: string, headers: Record<string, string>,
    body: string): Promise<TransportResponse> {
    let response: TransportResponse;
    try {
      response = await this.transport.send(
        new TransportRequest('POST', this.baseUrl + path, headers, body));
    } catch (error) {
      if (error instanceof TransportError) {
        throw new PairingError('network_error', -1, error.message);
      }
      throw error as Error;
    }
    if (response.status < 200 || response.status >= 300) {
      const wire: WireErrorBody = WireErrorBody.parse(response.body);
      throw new PairingError(wire.code.length > 0 ? wire.code : `http_${response.status}`,
        response.status, wire.message.length > 0 ? wire.message : response.body);
    }
    return response;
  }
}
