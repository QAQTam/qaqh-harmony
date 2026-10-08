/**
 * 传输抽象：RingingClient 只依赖这里的接口，设备实现（@ohos.net.http）
 * 与单测假件分列。M1 覆盖请求/响应形态；SSE 流式订阅在 M2 引入。
 */

/**
 * 一次 HTTP 请求的完整形态（url 为绝对地址，body 为空串表示无正文）。
 * `timeoutMs > 0` 时是该请求自己的读超时上限（0 = 用传输层默认）。租约续期
 * 这类「晚到即作废」的请求必须自带短预算，不能跟着大正文端点共用 120s。
 */
export class TransportRequest {
  readonly method: string;
  readonly url: string;
  readonly headers: Record<string, string>;
  readonly body: string;
  readonly timeoutMs: number;

  constructor(method: string, url: string, headers: Record<string, string>, body: string,
    timeoutMs?: number) {
    this.method = method;
    this.url = url;
    this.headers = headers;
    this.body = body;
    this.timeoutMs = timeoutMs !== undefined ? timeoutMs : 0;
  }
}

/** HTTP 响应（body 始终为文本；headers 尽力携带，假件可为空表）。 */
export class TransportResponse {
  readonly status: number;
  readonly body: string;
  readonly headers: Record<string, string>;

  constructor(status: number, body: string, headers?: Record<string, string>) {
    this.status = status;
    this.body = body;
    this.headers = headers !== undefined ? headers : {};
  }
}

/** 传输层错误。status >= 0 表示服务端返回的非 2xx；-1 表示网络级失败。 */
export class TransportError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(code: string, status: number, detail: string) {
    super(detail.length > 0 ? `${code}: ${detail}` : code);
    this.code = code;
    this.status = status;
  }
}

export interface Transport {
  send(request: TransportRequest): Promise<TransportResponse>;
}

/**
 * lease 续期定时器。fire 触发后内部句柄即失效；client 在每次续期完成后
 * 重新 start。真机实现用 setTimeout，单测用可手动触发/检查间隔的假件。
 */
export interface LeaseTimer {
  start(intervalMs: number, fire: () => void): void;
  stop(): void;
}
