/**
 * Defensive accessors for parsed JSON values.
 *
 * 协议层解析统一走这些守卫：先按接口 cast（ArkTS 静态要求），再用运行时
 * 守卫逐字段校验。任何字段形态不符都抛 `ProtocolError`，与 daemon 侧
 * 「响亮失败而不是静默降级」的策略一致。
 */

export class ProtocolError extends Error {
  readonly code: string;

  constructor(code: string, detail: string) {
    super(detail.length > 0 ? `${code}: ${detail}` : code);
    this.code = code;
  }
}

export function isString(value: Object | undefined | null): boolean {
  return typeof value === 'string';
}

export function isNumber(value: Object | undefined | null): boolean {
  return typeof value === 'number' && Number.isFinite(value);
}

export function isBoolean(value: Object | undefined | null): boolean {
  return typeof value === 'boolean';
}

export function isObject(value: Object | undefined | null): boolean {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export function isArray(value: Object | undefined | null): boolean {
  return Array.isArray(value);
}

export function requiredString(holder: object, field: string): string {
  const raw = (holder as Record<string, Object>)[field];
  if (typeof raw === 'string' && raw.length > 0) {
    return raw;
  }
  throw new ProtocolError('missing_field', `${field} must be a non-empty string`);
}

/** 同 requiredString，但允许空串（apiKey 掩码语义、fontFamily 等）。 */
export function requiredStringAllowEmpty(holder: object, field: string): string {
  const raw = (holder as Record<string, Object>)[field];
  if (typeof raw === 'string') {
    return raw;
  }
  throw new ProtocolError('missing_field', `${field} must be a string`);
}

export function optionalString(holder: object, field: string): string | undefined {
  const raw = (holder as Record<string, Object>)[field];
  if (raw === undefined || raw === null) {
    return undefined;
  }
  if (typeof raw === 'string') {
    return raw;
  }
  throw new ProtocolError('bad_field', `${field} must be a string`);
}

export function requiredBoolean(holder: object, field: string): boolean {
  const raw = (holder as Record<string, Object>)[field];
  if (typeof raw === 'boolean') {
    return raw;
  }
  throw new ProtocolError('missing_field', `${field} must be a boolean`);
}

export function requiredNumber(holder: object, field: string): number {
  const raw = (holder as Record<string, Object>)[field];
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    return raw;
  }
  throw new ProtocolError('missing_field', `${field} must be a number`);
}

export function optionalNumber(holder: object, field: string): number | undefined {
  const raw = (holder as Record<string, Object>)[field];
  if (raw === undefined || raw === null) {
    return undefined;
  }
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    return raw;
  }
  throw new ProtocolError('bad_field', `${field} must be a number`);
}

export function optionalBoolean(holder: object, field: string): boolean | undefined {
  const raw = (holder as Record<string, Object>)[field];
  if (raw === undefined || raw === null) {
    return undefined;
  }
  if (typeof raw === 'boolean') {
    return raw;
  }
  throw new ProtocolError('bad_field', `${field} must be a boolean`);
}

export function requiredObject(holder: object, field: string): object {
  const raw = (holder as Record<string, Object>)[field];
  if (typeof raw === 'object' && raw !== null && !Array.isArray(raw)) {
    return raw;
  }
  throw new ProtocolError('missing_field', `${field} must be an object`);
}

export function optionalObject(holder: object, field: string): object | undefined {
  const raw = (holder as Record<string, Object>)[field];
  if (raw === undefined || raw === null) {
    return undefined;
  }
  if (typeof raw === 'object' && !Array.isArray(raw)) {
    return raw;
  }
  throw new ProtocolError('bad_field', `${field} must be an object`);
}

export function requiredArray(holder: object, field: string): Object[] {
  const raw = (holder as Record<string, Object>)[field];
  if (Array.isArray(raw)) {
    return raw as Object[];
  }
  throw new ProtocolError('missing_field', `${field} must be an array`);
}

/** 严格字符串数组（后端 `Vec<String>`：条目必须全是字符串）。 */
export function requiredStringArray(holder: object, field: string): string[] {
  const raw: Object[] = requiredArray(holder, field);
  const out: string[] = [];
  for (const item of raw) {
    if (typeof item !== 'string') {
      throw new ProtocolError('bad_field', `${field} entries must be strings`);
    }
    out.push(item);
  }
  return out;
}

export function optionalArray(holder: object, field: string): Object[] | undefined {
  const raw = (holder as Record<string, Object>)[field];
  if (raw === undefined || raw === null) {
    return undefined;
  }
  if (Array.isArray(raw)) {
    return raw as Object[];
  }
  throw new ProtocolError('bad_field', `${field} must be an array`);
}

/** 解析 JSON 文本；失败时抛 ProtocolError 而不是返回 null。 */
export function parseJson(text: string): object {
  let value: Object | null = null;
  try {
    value = JSON.parse(text) as Object;
  } catch (error) {
    throw new ProtocolError('bad_json', `invalid JSON: ${(error as Error).message}`);
  }
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new ProtocolError('bad_json', 'top-level JSON value must be an object');
  }
  return value as object;
}
