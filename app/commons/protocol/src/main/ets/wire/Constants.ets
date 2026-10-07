/**
 * Ringing v2 wire constants (mirror of qaqh-ringing protocol.rs / v2/mod.rs).
 */

/** 线协议 schema 标识。 */
export const RINGING_SCHEMA: string = 'qaqh.Ringing';
/** Ringing v2 线协议版本。 */
export const RINGING_V2_VERSION: number = 2;
/** v2 路由基路径。 */
export const RINGING_V2_BASE_PATH: string = '/ringing/v2';
/** open 成功后所有请求使用的连接级身份 header。 */
export const CLIENT_SESSION_HEADER: string = 'X-QAQH-Client-Session-Id';
/** JSON 能被 JavaScript 精确表示的最大无符号整数。 */
export const MAX_SAFE_INTEGER: number = 9007199254740991;
/** 快照基线（END_OF_FACT）保留的 projection_index。 */
export const END_OF_FACT: number = 65535;

export function isSafeInteger(value: number): boolean {
  return Number.isSafeInteger(value) && value <= MAX_SAFE_INTEGER;
}

/** `POST /ringing/v2/clients/open` */
export function openPath(): string {
  return `${RINGING_V2_BASE_PATH}/clients/open`;
}

/** `POST /ringing/v2/leases/renew` */
export function renewLeasePath(): string {
  return `${RINGING_V2_BASE_PATH}/leases/renew`;
}

/** `GET /ringing/v2/sessions/{id}/bootstrap`（id = sessionId,旧称 seed）。 */
export function bootstrapPath(sessionId: string): string {
  return `${RINGING_V2_BASE_PATH}/sessions/${sessionId}/bootstrap`;
}

/** 单流订阅路径（每会话一条 SSE;事件带 stream_key）。 */
export function eventsPath(sessionId: string): string {
  return `${RINGING_V2_BASE_PATH}/sessions/${sessionId}/events`;
}

/** `POST /ringing/v2/service/{method}` — service RPC(session.list 等)。 */
export function servicePath(method: string): string {
  return `${RINGING_V2_BASE_PATH}/service/${method}`;
}

/** `POST /ringing/v2/commands/{channel}` */
export function commandPath(channel: string): string {
  return `${RINGING_V2_BASE_PATH}/commands/${channel}`;
}

/** `GET /ringing/v2/commands/{command_id}` */
export function commandStatusPath(commandId: string): string {
  return `${RINGING_V2_BASE_PATH}/commands/${commandId}`;
}

/** `GET /ringing/v2/content/{content_id}` */
export function contentPath(contentId: string): string {
  return `${RINGING_V2_BASE_PATH}/content/${contentId}`;
}

/** `GET /ringing/v2/sessions/{seed}/approvals` */
export function approvalsPath(sessionId: string): string {
  return `${RINGING_V2_BASE_PATH}/sessions/${sessionId}/approvals`;
}

/** `POST /ringing/v2/sessions/{id}/driver/claim`（驱动席认领专用端点）。 */
export function driverClaimPath(sessionId: string): string {
  return `${RINGING_V2_BASE_PATH}/sessions/${sessionId}/driver/claim`;
}

/** `POST /ringing/v2/sessions/{id}/driver/release`（驱动席释放）。 */
export function driverReleasePath(sessionId: string): string {
  return `${RINGING_V2_BASE_PATH}/sessions/${sessionId}/driver/release`;
}
