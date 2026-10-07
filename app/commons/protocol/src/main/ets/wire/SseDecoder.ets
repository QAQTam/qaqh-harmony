/**
 * 游标式 SSE 帧解码器。
 *
 * 逐行对齐 qaqh-client/src/sse_decoder.rs：
 * - 空行定界事件帧；无空行不产出帧；
 * - 注释行（`:` 开头，keepalive）不产出帧；
 * - 多 `data:` 行以单个 `\n` 连接；
 * - 非法 UTF-8 行跳过（绝不 lossy），解码器继续工作；
 * - 流首 BOM 剥离一次，流中段 U+FEFF 是数据不是编码标记；
 * - EOF 不冲刷残帧；
 * - `id:`/`event:`/`data:` 行为字段累积。
 */

import { decodeUtf8Strict, Utf8Error } from './Utf8';

const BOM: number[] = [0xef, 0xbb, 0xbf];

export class SseFrame {
  id: string = '';
  eventType: string = '';
  data: string = '';
}

export class SseDecoder {
  private buf: Uint8Array = new Uint8Array(0);
  private consumed: number = 0;
  private pending: SseFrame | undefined = undefined;
  private bomChecked: boolean = false;

  /** 追加新到达的字节块，并压缩已消费前缀（摊销 O(n)）。 */
  push(chunk: Uint8Array): void {
    if (this.consumed > 0) {
      this.buf = this.buf.slice(this.consumed);
      this.consumed = 0;
    }
    const merged: Uint8Array = new Uint8Array(this.buf.length + chunk.length);
    merged.set(this.buf, 0);
    merged.set(chunk, this.buf.length);
    this.buf = merged;
  }

  /** 取下一完整帧。`undefined` = 暂无完整帧，需等更多数据。抛 Utf8Error 表示本行非法已跳过前遇到致命问题。 */
  nextFrame(): SseFrame | undefined {
    if (!this.bomChecked) {
      const avail: Uint8Array = this.buf.subarray(this.consumed);
      let matched: number = 0;
      while (matched < BOM.length && matched < avail.length && avail[matched] === BOM[matched]) {
        matched++;
      }
      if (matched === BOM.length) {
        this.consumed += BOM.length;
        this.bomChecked = true;
      } else if (avail.length < BOM.length) {
        return undefined;
      } else {
        this.bomChecked = true;
      }
    }

    for (;;) {
      const window: Uint8Array = this.buf.subarray(this.consumed);
      let rel: number = -1;
      for (let i = 0; i < window.length; i++) {
        if (window[i] === 0x0a) {
          rel = i;
          break;
        }
      }
      if (rel < 0) {
        return undefined;
      }
      const end: number = this.consumed + rel;
      const lineStart: number = this.consumed;
      this.consumed = end + 1;

      let line: string;
      try {
        line = decodeUtf8Strict(this.buf, lineStart, end).replace(/[\r\n]+$/, '');
      } catch (error) {
        if (error instanceof Utf8Error) {
          continue; // 非法 UTF-8 行：跳过，绝不 lossy
        }
        throw error as Error;
      }

      if (line.length === 0) {
        // 空行 = 帧结束。
        if (this.pending !== undefined) {
          const frame: SseFrame = this.pending;
          this.pending = undefined;
          return frame;
        }
        continue;
      }
      if (line.startsWith(':')) {
        continue; // 注释行（keepalive）
      }

      if (this.pending === undefined) {
        this.pending = new SseFrame();
      }
      if (line.startsWith('id:')) {
        this.pending.id = line.substring(3).trim();
      } else if (line.startsWith('event:')) {
        this.pending.eventType = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (this.pending.data.length > 0) {
          this.pending.data += '\n';
        }
        this.pending.data += line.substring(5).trim();
      }
      // 其他字段（unknown）忽略。
    }
  }
}
