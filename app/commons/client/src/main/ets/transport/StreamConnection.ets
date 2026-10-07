/**
 * 流式传输抽象（SSE 订阅用）。与请求/响应式 Transport 并列：
 * EventStream 只依赖 StreamConnection 接口，真机实现走
 * `@ohos.net.http requestInStream`，单测用脚本化假件。
 */

export class StreamRequest {
  readonly url: string;
  readonly headers: Record<string, string>;

  constructor(url: string, headers: Record<string, string>) {
    this.url = url;
    this.headers = headers;
  }
}

/** 连接端点描述：baseUrl 不含路径，path 与 `?since_cursor=` 由 EventStream 组装。 */
export class StreamEndpoint {
  readonly baseUrl: string;
  readonly headers: Record<string, string>;

  constructor(baseUrl: string, headers: Record<string, string>) {
    this.baseUrl = baseUrl;
    this.headers = headers;
  }
}

export interface StreamListener {
  /** 收到一段原始字节（可能跨帧/含半帧，由上层 SseDecoder 重组）。 */
  onData(chunk: Uint8Array): void;
  /** 流正常收尾（dataEnd 或服务端关闭）。status 为 HTTP 响应码。 */
  onEnded(status: number): void;
  /** 网络级失败（连接被拒、超时、底层错误）。 */
  onFailed(code: string, message: string): void;
}

export interface StreamConnection {
  connect(request: StreamRequest, listener: StreamListener): void;
  cancel(): void;
}
