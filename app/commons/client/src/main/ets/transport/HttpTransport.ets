/**
 * @ohos.net.http 实现（真机）。每个请求独立 createHttp/destroy，避免复用
 * 句柄的生命周期问题。4xx/5xx 不在这里抛——把响应交给 client 层按端点语义处理。
 */

import { http } from '@kit.NetworkKit';
import { Transport, TransportRequest, TransportResponse, TransportError } from './Transport';
import { TlsTrust } from './TlsTrust';

export class HttpTransport implements Transport {
  private readonly connectTimeoutMs: number;
  private readonly readTimeoutMs: number;
  private readonly trust: TlsTrust;

  constructor(connectTimeoutMs: number, readTimeoutMs: number, trust?: TlsTrust) {
    this.connectTimeoutMs = connectTimeoutMs;
    this.readTimeoutMs = readTimeoutMs;
    this.trust = trust !== undefined ? trust : TlsTrust.none();
  }

  send(request: TransportRequest): Promise<TransportResponse> {
    return new Promise<TransportResponse>((resolve, reject) => {
      const httpRequest = http.createHttp();
      let options: http.HttpRequestOptions = {
        method: request.method === 'POST'
          ? http.RequestMethod.POST : http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: this.connectTimeoutMs,
        readTimeout: request.timeoutMs > 0
          ? Math.min(this.readTimeoutMs, request.timeoutMs) : this.readTimeoutMs,
        header: request.headers
      };
      if (request.body.length > 0) {
        options.extraData = request.body;
      }
      this.trust.applyTo(options);
      httpRequest.request(request.url, options).then((response: http.HttpResponse) => {
        let body: string = '';
        if (typeof response.result === 'string') {
          body = response.result;
        } else {
          body = JSON.stringify(response.result);
        }
        let headers: Record<string, string> = {};
        const rawHeader: Object | undefined = response.header;
        if (typeof rawHeader === 'object' && rawHeader !== null) {
          const record = rawHeader as Record<string, Object>;
          for (const key of Object.keys(record)) {
            headers[key] = `${record[key]}`;
          }
        }
        httpRequest.destroy();
        resolve(new TransportResponse(response.responseCode, body, headers));
      }).catch((error: Object) => {
        httpRequest.destroy();
        reject(new TransportError('network_error', -1, (error as Error).message));
      });
    });
  }
}
