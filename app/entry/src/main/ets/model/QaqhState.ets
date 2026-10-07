/**
 * AppStorage 键名单源（M9）：写方只有 AppModel（状态广播）与 EntryAbility
 * （深链预选），读方各视图 @StorageLink 用同名常量。单独成文件是为了让
 * 视图引用键名时不 import AppModel（ApprovalDialog 与 AppModel 互相引用会成环）。
 */

export class QaqhState {
  static readonly STATUS: string = 'qaqhStatus';
  static readonly TICK: string = 'qaqhTick';
  static readonly CONNECTED: string = 'qaqhConnected';
  static readonly SESSION_ENTRIES: string = 'qaqhSessionEntries';
  static readonly ACTIVE_SESSION: string = 'qaqhActiveSession';
  /** 活动会话的 G2 展示标题与模型名（详情顶栏；AppModel 在 enterSession 时灌入）。 */
  static readonly ACTIVE_TITLE: string = 'qaqhActiveTitle';
  static readonly ACTIVE_MODEL: string = 'qaqhActiveModel';
  static readonly CARDS: string = 'qaqhCards';
  static readonly CREATING: string = 'qaqhCreating';
  static readonly SENDING: string = 'qaqhSending';
  static readonly TURN_ACTIVE: string = 'qaqhTurnActive';
  static readonly SEAT_TEXT: string = 'qaqhSeatText';
  static readonly CAN_LOAD_OLDER: string = 'qaqhCanLoadOlder';
  static readonly BASE_URL: string = 'qaqhBaseUrl';
  static readonly TOKEN: string = 'qaqhToken';
  static readonly CA_PEM: string = 'qaqhCaPem';
  static readonly SKIP_VERIFY: string = 'qaqhSkipVerify';
  static readonly PAIRED_LABEL: string = 'qaqhPairedLabel';
  static readonly PAIRING: string = 'qaqhPairing';
  /** 开屏引导门（M14）：无已配对凭证时主壳换成扫码/手动配对首屏。 */
  static readonly ONBOARD: string = 'qaqhOnboard';
  static readonly TAB: string = 'qaqhTab';
  /** 沉浸式安全区（EntryAbility 回灌，vp）：顶栏 padding / 胶囊抬升 / 内容留位。 */
  static readonly SAFE_TOP: string = 'qaqhSafeTop';
  static readonly SAFE_BOTTOM: string = 'qaqhSafeBottom';
  static readonly CAP_SPACE: string = 'qaqhCapSpace';
  /** 左栏 session.list 抽屉开关（ConversationTab 与详情顶栏共用，避免 props 链失真）。 */
  static readonly NAV_VISIBLE: string = 'qaqhNavVisible';
  /** 是否分栏（ConversationTab 按宽高比判定；详情顶栏据此决定折叠钮显隐）。 */
  static readonly SPLIT: string = 'qaqhSplit';
  static readonly FOCUS_INTERACTION: string = 'qaqhFocusInteraction';
  static readonly FOCUS_ACTION: string = 'qaqhFocusAction';
  /** daemon 配置面（BYOK 六字段 + profile；M10 设置页，读方 SettingsTab）。 */
  static readonly CFG_MODEL: string = 'qaqhCfgModel';
  static readonly CFG_BASE_URL: string = 'qaqhCfgBaseUrl';
  static readonly CFG_WIRE: string = 'qaqhCfgWire';
  static readonly CFG_MAX_TOKENS: string = 'qaqhCfgMaxTokens';
  static readonly CFG_CONTEXT_LENGTH: string = 'qaqhCfgContextLength';
  static readonly CFG_EFFORT: string = 'qaqhCfgEffort';
  static readonly CFG_API_KEY_LABEL: string = 'qaqhCfgApiKeyLabel';
  static readonly CFG_NEW_API_KEY: string = 'qaqhCfgNewApiKey';
  static readonly CFG_PROFILES: string = 'qaqhCfgProfiles';
  static readonly CFG_ACTIVE_PROFILE: string = 'qaqhCfgActiveProfile';
  static readonly CFG_SELECTED_PROFILE: string = 'qaqhCfgSelectedProfile';
  static readonly CFG_STATUS: string = 'qaqhCfgStatus';
  static readonly CFG_LOADED: string = 'qaqhCfgLoaded';
  static readonly CFG_SAVING: string = 'qaqhCfgSaving';
  /** 内存探针（M13，MemoryProbe 写、SettingsTab 调试卡读；MB 字符串）。 */
  static readonly PERF_PSS: string = 'qaqhPerfPss';
  static readonly PERF_NATIVE: string = 'qaqhPerfNative';
  static readonly PERF_PEAK: string = 'qaqhPerfPeak';
}
