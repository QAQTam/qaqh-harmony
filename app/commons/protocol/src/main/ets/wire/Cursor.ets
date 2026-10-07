/**
 * Canonical cursor + opaque wire token.
 *
 * 镜像 qaqh-ringing v2/cursor.rs：
 * - token 形态 `v2.<base64url-no-pad(compact-json)>`；
 * - 解码必须能重编码出完全相同的 token（拒绝 padding / 非规范 base64 / 尾部 JSON）；
 * - reliable 的 projection_index <= 65534，snapshot 必须等于 END_OF_FACT。
 */

import { MAX_SAFE_INTEGER, END_OF_FACT } from './Constants';
import { ProtocolError } from './Json';
import { encodeUtf8, decodeUtf8Strict } from './Utf8';

const BASE64URL_ALPHABET: string =
  'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

function base64UrlEncode(bytes: Uint8Array): string {
  let out: string = '';
  let i: number = 0;
  while (i + 2 < bytes.length) {
    const n: number = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
    out += BASE64URL_ALPHABET.charAt((n >> 18) & 63) +
      BASE64URL_ALPHABET.charAt((n >> 12) & 63) +
      BASE64URL_ALPHABET.charAt((n >> 6) & 63) +
      BASE64URL_ALPHABET.charAt(n & 63);
    i += 3;
  }
  const remaining: number = bytes.length - i;
  if (remaining === 1) {
    const n: number = bytes[i] << 16;
    out += BASE64URL_ALPHABET.charAt((n >> 18) & 63) +
      BASE64URL_ALPHABET.charAt((n >> 12) & 63);
  } else if (remaining === 2) {
    const n: number = (bytes[i] << 16) | (bytes[i + 1] << 8);
    out += BASE64URL_ALPHABET.charAt((n >> 18) & 63) +
      BASE64URL_ALPHABET.charAt((n >> 12) & 63) +
      BASE64URL_ALPHABET.charAt((n >> 6) & 63);
  }
  return out;
}

function base64UrlDecode(text: string): Uint8Array {
  const lookup: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < BASE64URL_ALPHABET.length; i++) {
    lookup.set(BASE64URL_ALPHABET.charAt(i), i);
  }
  if (text.length % 4 === 1) {
    throw new ProtocolError('invalid_base64', 'cursor token is not base64url-no-pad');
  }
  const byteCount: number = Math.floor(text.length * 3 / 4);
  const out: Uint8Array = new Uint8Array(byteCount);
  let outIndex: number = 0;
  let buffer: number = 0;
  let bits: number = 0;
  for (let i = 0; i < text.length; i++) {
    const value: number | undefined = lookup.get(text.charAt(i));
    if (value === undefined) {
      throw new ProtocolError('invalid_base64', 'cursor token is not base64url-no-pad');
    }
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[outIndex++] = (buffer >> bits) & 0xff;
    }
  }
  return out;
}

export class CanonicalCursor {
  readonly logId: string;
  readonly factSeq: number;
  readonly projectionIndex: number;

  constructor(logId: string, factSeq: number, projectionIndex: number) {
    this.logId = logId;
    this.factSeq = factSeq;
    this.projectionIndex = projectionIndex;
  }

  static snapshot(logId: string, factSeq: number): CanonicalCursor {
    return new CanonicalCursor(logId, factSeq, END_OF_FACT);
  }

  validateCommon(): void {
    if (this.logId.trim().length === 0) {
      throw new ProtocolError('invalid_cursor', 'log_id must not be empty');
    }
    if (this.factSeq === 0 || this.factSeq > MAX_SAFE_INTEGER) {
      throw new ProtocolError('invalid_cursor', 'fact_seq must be in 1..=MAX_SAFE_INTEGER');
    }
  }

  validateReliable(): void {
    this.validateCommon();
    if (this.projectionIndex === END_OF_FACT) {
      throw new ProtocolError('invalid_cursor', 'reliable projection_index must be <= 65534');
    }
  }

  validateSnapshot(): void {
    this.validateCommon();
    if (this.projectionIndex !== END_OF_FACT) {
      throw new ProtocolError('invalid_cursor', 'snapshot projection_index must be END_OF_FACT');
    }
  }

  /** 只在同一 canonical log 内比较。 */
  isAfter(other: CanonicalCursor): boolean {
    this.validateCommon();
    other.validateCommon();
    if (this.logId !== other.logId) {
      throw new ProtocolError('log_mismatch', 'cursor log_id does not match');
    }
    if (this.factSeq !== other.factSeq) {
      return this.factSeq > other.factSeq;
    }
    return this.projectionIndex > other.projectionIndex;
  }
}

export class CursorToken {
  readonly value: string;

  private constructor(value: string) {
    this.value = value;
  }

  static fromOpaque(value: string): CursorToken {
    return new CursorToken(value);
  }

  asString(): string {
    return this.value;
  }

  private static encodeCursor(cursor: CanonicalCursor): string {
    cursor.validateCommon();
    // 与 Rust serde_json 的 compact 形态逐字节一致：字段名顺序固定、无空格。
    const text: string = `{"log_id":${JSON.stringify(cursor.logId)},` +
      `"fact_seq":${cursor.factSeq},"projection_index":${cursor.projectionIndex}}`;
    const bytes: Uint8Array = encodeUtf8(text);
    return `v2.${base64UrlEncode(bytes)}`;
  }

  static encodeReliable(cursor: CanonicalCursor): CursorToken {
    cursor.validateReliable();
    return new CursorToken(CursorToken.encodeCursor(cursor));
  }

  static encodeSnapshot(cursor: CanonicalCursor): CursorToken {
    cursor.validateSnapshot();
    return new CursorToken(CursorToken.encodeCursor(cursor));
  }

  decode(): CanonicalCursor {
    const prefix: string = 'v2.';
    if (!this.value.startsWith(prefix)) {
      throw new ProtocolError('invalid_prefix', 'cursor token must start with `v2.`');
    }
    const encoded: string = this.value.substring(prefix.length);
    if (encoded.length === 0) {
      throw new ProtocolError('invalid_base64', 'cursor token is not base64url-no-pad');
    }
    if (encoded.includes('=')) {
      throw new ProtocolError('invalid_base64', 'cursor token is not base64url-no-pad');
    }
    let json: string;
    try {
      const bytes: Uint8Array = base64UrlDecode(encoded);
      json = decodeUtf8Strict(bytes, 0, bytes.length);
    } catch (error) {
      throw new ProtocolError('invalid_base64', 'cursor token is not base64url-no-pad');
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(json) as Object;
    } catch (error) {
      throw new ProtocolError('bad_json', 'cursor payload is not valid JSON');
    }
    if (typeof parsed !== 'object' || parsed === null) {
      throw new ProtocolError('invalid_cursor', 'cursor payload must be an object');
    }
    const holder = parsed as Record<string, Object>;
    const logId = holder['log_id'];
    const factSeq = holder['fact_seq'];
    const projectionIndex = holder['projection_index'];
    if (typeof logId !== 'string' || typeof factSeq !== 'number' ||
      typeof projectionIndex !== 'number') {
      throw new ProtocolError('invalid_cursor', 'cursor payload fields are malformed');
    }
    if (Object.keys(holder).length !== 3) {
      throw new ProtocolError('invalid_cursor', 'cursor payload has unexpected fields');
    }
    const cursor: CanonicalCursor = new CanonicalCursor(logId, factSeq, projectionIndex);
    const canonical: string = CursorToken.encodeCursor(cursor);
    if (canonical !== this.value) {
      throw new ProtocolError('non_canonical', 'cursor token is not canonical');
    }
    return cursor;
  }

  decodeReliable(): CanonicalCursor {
    const cursor: CanonicalCursor = this.decode();
    cursor.validateReliable();
    return cursor;
  }

  decodeSnapshot(): CanonicalCursor {
    const cursor: CanonicalCursor = this.decode();
    cursor.validateSnapshot();
    return cursor;
  }

  decodeForLog(logId: string): CanonicalCursor {
    const cursor: CanonicalCursor = this.decode();
    if (cursor.logId !== logId) {
      throw new ProtocolError('log_mismatch', 'cursor log_id does not match');
    }
    return cursor;
  }
}
