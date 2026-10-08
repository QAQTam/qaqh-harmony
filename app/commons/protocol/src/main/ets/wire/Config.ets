/**
 * Config/Profile 服务面契约（`POST /ringing/v2/service/config.*` / `profile.*`）。
 *
 * 镜像 qaqh-config-api（camelCase，**不做向前兼容**：缺字段即解析失败，与后端
 * 读侧同一哲学——2026-10 BYOK 重构后的形状）：
 * - provider 预设坐标已删（`providerId`/预设 endpoint id/`providers` 目录
 *   都不在 wire 上了）；配置面收口为 BYOK 六字段：`baseUrl` + `wire` +
 *   `model` + `maxTokens` + `contextLength` + apiKey（apiKey 不在 config 里落值）。
 * - `wire` ∈ `openai` | `responses` | `anthropic`。
 * - `apiKey` 永不出 daemon：空串 = 未配置，`"****"` = 已配置（掩码）。
 * - `contextLength` 是本地压缩的唯一分母（旧 `contextLimit`/`contextWindow`
 *   双口径已退役）。
 *
 * 写侧（`config.save`）是 JSON Merge Patch：只发要改的字段，缺失 = 不动。
 * 后端对每个字段独立 `Option`，**发旧键不会报错、但会被 serde 静默丢掉**
 * （写不动），所以键名必须逐字对齐本文件的常量。
 *
 * 刻意不建模：`subagent` 的写侧嵌套补丁、`mcp`/`lsp` 的 server 列表展开
 * （移动端暂无编辑面；读侧只验证存在性）。需要时再按后端 qaqh-config-api 补。
 */

import { parseJson, requiredString, requiredStringAllowEmpty, requiredNumber,
  requiredBoolean, requiredObject, requiredStringArray, optionalString } from './Json';

/** `wire` 值域（后端 `ConfigPatch::validate` 同域，非法值整包拒绝）。 */
export class ConfigWire {
  static readonly OPENAI: string = 'openai';
  static readonly RESPONSES: string = 'responses';
  static readonly ANTHROPIC: string = 'anthropic';

  static isValid(value: string): boolean {
    return value === ConfigWire.OPENAI || value === ConfigWire.RESPONSES ||
      value === ConfigWire.ANTHROPIC;
  }
}

/** `reasoningEffort` 值域（同上）。 */
class ReasoningEfforts {
  static readonly VALUES: string[] =
    ['low', 'medium', 'high', 'xhigh', 'max'];
}

/** 子代理配置读模型（镜像 `SubagentDto`；移动端只读透传）。 */
export class RingingConfigSubagent {
  readonly model: string;
  readonly baseUrl: string;
  readonly apiKey: string;
  readonly apiKeySet: boolean;
  readonly maxTokens: number;
  readonly timeoutSecs: number;
  readonly defaultTools: string[];
  readonly maxDepth: number;
  readonly messageInFlightPerPair: number;
  readonly messageOutboundPerSender: number;

  constructor(holder: object) {
    this.model = requiredStringAllowEmpty(holder, 'model');
    this.baseUrl = requiredStringAllowEmpty(holder, 'baseUrl');
    this.apiKey = requiredStringAllowEmpty(holder, 'apiKey');
    this.apiKeySet = requiredBoolean(holder, 'apiKeySet');
    this.maxTokens = requiredNumber(holder, 'maxTokens');
    this.timeoutSecs = requiredNumber(holder, 'timeoutSecs');
    this.defaultTools = requiredStringArray(holder, 'defaultTools');
    this.maxDepth = requiredNumber(holder, 'maxDepth');
    this.messageInFlightPerPair = requiredNumber(holder, 'messageInFlightPerPair');
    this.messageOutboundPerSender = requiredNumber(holder, 'messageOutboundPerSender');
  }
}

/**
 * `config.load` 读模型（镜像 `ConfigDto` 序列化形状——后端全字段产出，
 * `lang`/`theme`/`tokenizerPath` 为 null 时解析为 undefined）。
 */
export class RingingConfigDto {
  readonly model: string;
  /** BYOK endpoint：scheme + host + 可选前缀（不含 wire 自身路径）。 */
  readonly baseUrl: string;
  readonly wire: string;
  readonly maxTokens: number;
  /** 端点声明的上下文窗口——本地压缩的唯一分母。 */
  readonly contextLength: number;
  readonly reasoningEffort: string;
  /** 值域 [0,1]；0 = 关闭自动压缩。 */
  readonly autoCompactThreshold: number;
  /** 1=read-only，2=workspace-write，3=skip-permissions。 */
  readonly permissionLevel: number;
  /** 空串 = 未配置、`"****"` = 已配置（掩码）。 */
  readonly apiKey: string;
  readonly lang: string | undefined;
  readonly fontFamily: string;
  /** undefined/null = 跟随系统。 */
  readonly theme: string | undefined;
  readonly notificationsEnabled: boolean;
  readonly activeProfile: string;
  /** profile 名列表（管理 UI 用；不含敏感字段）。 */
  readonly profiles: string[];
  readonly complianceEnabled: boolean;
  readonly subagent: RingingConfigSubagent;
  /** MCP/LSP 段只验证存在，不展开（移动端暂无消费面）。 */
  readonly mcp: object;
  readonly lsp: object;
  readonly tokenizerPath: string | undefined;

  constructor(holder: object) {
    this.model = requiredStringAllowEmpty(holder, 'model');
    this.baseUrl = requiredStringAllowEmpty(holder, 'baseUrl');
    this.wire = requiredString(holder, 'wire');
    this.maxTokens = requiredNumber(holder, 'maxTokens');
    this.contextLength = requiredNumber(holder, 'contextLength');
    this.reasoningEffort = requiredString(holder, 'reasoningEffort');
    this.autoCompactThreshold = requiredNumber(holder, 'autoCompactThreshold');
    this.permissionLevel = requiredNumber(holder, 'permissionLevel');
    this.apiKey = requiredStringAllowEmpty(holder, 'apiKey');
    this.lang = optionalString(holder, 'lang');
    this.fontFamily = requiredStringAllowEmpty(holder, 'fontFamily');
    this.theme = optionalString(holder, 'theme');
    this.notificationsEnabled = requiredBoolean(holder, 'notificationsEnabled');
    this.activeProfile = requiredString(holder, 'activeProfile');
    this.profiles = requiredStringArray(holder, 'profiles');
    this.complianceEnabled = requiredBoolean(holder, 'complianceEnabled');
    this.subagent = new RingingConfigSubagent(requiredObject(holder, 'subagent'));
    this.mcp = requiredObject(holder, 'mcp');
    this.lsp = requiredObject(holder, 'lsp');
    this.tokenizerPath = optionalString(holder, 'tokenizerPath');
  }

  static parse(text: string): RingingConfigDto {
    return new RingingConfigDto(parseJson(text));
  }

  /** `wire` 是否为后端认可的三值之一（展示前防御）。 */
  wireKnown(): boolean {
    return ConfigWire.isValid(this.wire);
  }
}

/**
 * `config.save` 写模型（JSON Merge Patch，镜像 `ConfigPatch`）：
 * 未赋值的字段不出现在 wire 上（缺失 = 不动）；多端并发编辑互不覆盖。
 *
 * 特例语义冻结：`apiKey` 沿用后端守卫——`"****"` 或空串 = 保持现值
 * （显式删除须专用接口）；`theme` 赋空串 = 跟随系统。
 */
export class RingingConfigPatch {
  apiKey: string | undefined = undefined;
  model: string | undefined = undefined;
  baseUrl: string | undefined = undefined;
  wire: string | undefined = undefined;
  maxTokens: number | undefined = undefined;
  contextLength: number | undefined = undefined;
  reasoningEffort: string | undefined = undefined;
  autoCompactThreshold: number | undefined = undefined;
  complianceEnabled: boolean | undefined = undefined;
  lang: string | undefined = undefined;
  fontFamily: string | undefined = undefined;
  theme: string | undefined = undefined;
  notificationsEnabled: boolean | undefined = undefined;
  /** 值域 1..=3（1=read-only, 2=workspace-write, 3=skip-permissions）。 */
  permissionLevel: number | undefined = undefined;

  /**
   * 值域校验（镜像后端 `ConfigPatch::validate`；返回首个违规的人类可读
   * 错误，空串 = 合法）。本地先拦一道：非法补丁不出端。
   */
  validate(): string {
    if (this.autoCompactThreshold !== undefined) {
      const t: number = this.autoCompactThreshold;
      if (Number.isNaN(t) || t < 0 || t > 1) {
        return `autoCompactThreshold 必须在 [0, 1] 区间（0=关闭），收到 ${t}`;
      }
    }
    if (this.maxTokens !== undefined && this.maxTokens === 0) {
      return 'maxTokens 必须大于 0';
    }
    if (this.contextLength !== undefined && this.contextLength === 0) {
      return 'contextLength 必须大于 0';
    }
    if (this.wire !== undefined && !ConfigWire.isValid(this.wire)) {
      return `wire 仅允许 openai|responses|anthropic，收到 ${this.wire}`;
    }
    if (this.reasoningEffort !== undefined &&
      !ReasoningEfforts.VALUES.includes(this.reasoningEffort)) {
      return `reasoningEffort 仅允许 low|medium|high|xhigh|max，收到 ${this.reasoningEffort}`;
    }
    if (this.permissionLevel !== undefined &&
      (this.permissionLevel < 1 || this.permissionLevel > 3)) {
      return `permissionLevel 仅允许 1..=3（1=read-only, 2=workspace-write, 3=skip-permissions），收到 ${this.permissionLevel}`;
    }
    return '';
  }

  /** 序列化为 Merge Patch：只含已赋值字段（camelCase，与后端键逐字对齐）。 */
  toWire(): Record<string, Object> {
    const wire: Record<string, Object> = {};
    if (this.apiKey !== undefined) {
      wire['apiKey'] = this.apiKey;
    }
    if (this.model !== undefined) {
      wire['model'] = this.model;
    }
    if (this.baseUrl !== undefined) {
      wire['baseUrl'] = this.baseUrl;
    }
    if (this.wire !== undefined) {
      wire['wire'] = this.wire;
    }
    if (this.maxTokens !== undefined) {
      wire['maxTokens'] = this.maxTokens;
    }
    if (this.contextLength !== undefined) {
      wire['contextLength'] = this.contextLength;
    }
    if (this.reasoningEffort !== undefined) {
      wire['reasoningEffort'] = this.reasoningEffort;
    }
    if (this.autoCompactThreshold !== undefined) {
      wire['autoCompactThreshold'] = this.autoCompactThreshold;
    }
    if (this.complianceEnabled !== undefined) {
      wire['complianceEnabled'] = this.complianceEnabled;
    }
    if (this.lang !== undefined) {
      wire['lang'] = this.lang;
    }
    if (this.fontFamily !== undefined) {
      wire['fontFamily'] = this.fontFamily;
    }
    if (this.theme !== undefined) {
      wire['theme'] = this.theme;
    }
    if (this.notificationsEnabled !== undefined) {
      wire['notificationsEnabled'] = this.notificationsEnabled;
    }
    if (this.permissionLevel !== undefined) {
      wire['permissionLevel'] = this.permissionLevel;
    }
    return wire;
  }
}
