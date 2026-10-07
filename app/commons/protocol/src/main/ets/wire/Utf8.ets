/**
 * 严格 UTF-8 编解码（手写，不依赖 @ohos.util 或 Web 全局对象）。
 *
 * - encodeUtf8：字符串 → UTF-8 字节（surrogate pair 组合成码点）；
 * - decodeUtf8Strict：字节 → 字符串，遇到非法序列直接抛错，绝不 lossy
 *   （对齐 qaqh-client SseDecoder 的「非法行跳过，不注入 U+FFFD」语义）。
 */

export function encodeUtf8(text: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < text.length; i++) {
    let code: number = text.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      const low: number = text.charCodeAt(i + 1);
      if (low >= 0xdc00 && low <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
        i++;
      }
    }
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code < 0x10000) {
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else {
      out.push(
        0xf0 | (code >> 18),
        0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f),
        0x80 | (code & 0x3f)
      );
    }
  }
  const bytes: Uint8Array = new Uint8Array(out.length);
  for (let i = 0; i < out.length; i++) {
    bytes[i] = out[i];
  }
  return bytes;
}

export class Utf8Error extends Error {
  constructor() {
    super('invalid UTF-8 byte sequence');
  }
}

export function decodeUtf8Strict(bytes: Uint8Array, start: number, end: number): string {
  let out: string = '';
  let i: number = start;
  while (i < end) {
    const b0: number = bytes[i];
    if (b0 < 0x80) {
      out += String.fromCharCode(b0);
      i += 1;
    } else if (b0 < 0xc2 || b0 > 0xf4) {
      throw new Utf8Error();
    } else if (b0 < 0xe0) {
      if (i + 1 >= end || (bytes[i + 1] & 0xc0) !== 0x80) {
        throw new Utf8Error();
      }
      out += String.fromCharCode(((b0 & 0x1f) << 6) | (bytes[i + 1] & 0x3f));
      i += 2;
    } else if (b0 < 0xf0) {
      if (i + 2 >= end || (bytes[i + 1] & 0xc0) !== 0x80 || (bytes[i + 2] & 0xc0) !== 0x80) {
        throw new Utf8Error();
      }
      const code: number =
        ((b0 & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f);
      if (code < 0x800 || (code >= 0xd800 && code <= 0xdfff)) {
        throw new Utf8Error();
      }
      out += String.fromCharCode(code);
      i += 3;
    } else {
      if (i + 3 >= end || (bytes[i + 1] & 0xc0) !== 0x80 ||
        (bytes[i + 2] & 0xc0) !== 0x80 || (bytes[i + 3] & 0xc0) !== 0x80) {
        throw new Utf8Error();
      }
      const code: number = ((b0 & 0x07) << 18) | ((bytes[i + 1] & 0x3f) << 12) |
        ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f);
      if (code > 0x10ffff || code < 0x10000) {
        throw new Utf8Error();
      }
      const adjusted: number = code - 0x10000;
      out += String.fromCharCode(0xd800 + (adjusted >> 10), 0xdc00 + (adjusted & 0x3ff));
      i += 4;
    }
  }
  return out;
}
