/**
 * `@ohos.net.http requestInStream` 实现。每个连接独立 createHttp/destroy。
 * 响应头到达即 resolve（Promise<number> = 响应码），正文经 dataReceive 分块
 * 上抛；非 2xx 直接按 onEnded(status) 收尾（SSE 端点不会给错误正文流）。
 */

import { http } from '@kit.NetworkKit';
import { StreamConnection, StreamListener, StreamRequest } from './StreamConnection';
import { TlsTrust } from './TlsTrust';

export class HttpStreamConnection implements StreamConnection {
  private readonly trust: TlsTrust;
  private httpRequest: http.HttpRequest | undefined;
  private cancelled: boolean = false;

  constructor(trust?: TlsTrust) {
    this.trust = trust !== undefined ? trust : TlsTrust.none();
  }

  connect(request: StreamRequest, listener: StreamListener): void {
    this.cancelled = false;
    const connection = http.createHttp();
    this.httpRequest = connection;
    connection.on('dataReceive', (value: ArrayBuffer) => {
      if (!this.cancelled) {
        listener.onData(new Uint8Array(value));
      }
    });
    connection.on('dataEnd', () => {
      this.teardown();
      listener.onEnded(200);
    });
    let options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 10000,
      // SSE 是长连接：真机实测服务端 15s keepalive **不重置** readTimeout，
      // 给有限值（曾用 120000）会让流每 2 分钟被 `CURLcode 28` 掐断一次。
      // 0 = 不设读取超时；断线由 dataEnd/onFailed/流终止帧负责暴露。
      readTimeout: 0,
      header: request.headers
    };
    this.trust.applyTo(options);
    connection.requestInStream(request.url, options)
      .then((status: number) => {
        if (status < 200 || status >= 300) {
          this.teardown();
          listener.onEnded(status);
        }
      })
      .catch((error: Object) => {
        this.teardown();
        if (!this.cancelled) {
          listener.onFailed('network_error', (error as Error).message);
        }
      });
  }

  cancel(): void {
    this.cancelled = true;
    this.teardown();
  }

  private teardown(): void {
    const connection = this.httpRequest;
    if (connection !== undefined) {
      connection.off('dataReceive');
      connection.off('dataEnd');
      connection.destroy();
      this.httpRequest = undefined;
    }
  }
}
