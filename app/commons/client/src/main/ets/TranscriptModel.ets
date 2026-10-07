/**
 * 正文模型（M8）：Timeline 通道 → 稳定行表（增量维护）。
 *
 * 在 M7 的基础上吸收 qaqh-tui-app 的渲染语义与性能纪律：
 * - **思考链路**：reasoning 块流式期渲尾部 3 行滚动窗口，sealed 后折成单行
 *   摘要（点击展开全文）；空正文的 sealed reasoning 直接丢弃（对齐 TUI
 *   adapter.rs 的「空块不进历史」）。
 * - **工具过滤/分组**：连续、同回合、同工具、全部成功的 lookup 族
 *   （read/grep/glob/list…）合并成一张「读取了 N 个文件（点击展开）」摘要卡；
 *   展开即拆组。todo 族（todo_write/update/list）解析成计划清单卡，并把最新
 *   状态汇给侧栏面板（in_progress 置顶；全完成时面板隐藏由 UI 决定）。
 * - **O1 增量**：行对象跨重建复用（rowPool），text_delta/tool_progress 只
 *   改对应行并标脏（structuralVersion 不动）；只有结构事件（块增删、回合
 *   边界、拆/合组、展开态变化）才重建行表并递增 structuralVersion。
 *   渲染侧据此做 LazyForEach 局部刷新，不再每帧全表重算。
 *
 * 纯逻辑、无 UI 装饰器：@Observed 视图模型在 entry 侧做包装，保持本模块
 * 可单测。
 */

import {
  TimelineBlock, TimelineEntry, TimelineEvent, TimelineRound, TimelineTool, TimelineTurn,
  TimelineBlockKind, TimelineBlockState, TimelineTurnState, TimelineToolState
} from '@qaqh/protocol';

/** 行类别（渲染分派用）。 */
export class TranscriptRowKind {
  static readonly USER: string = 'user';
  static readonly TEXT: string = 'text';
  static readonly THINKING: string = 'thinking';
  static readonly NOTICE: string = 'notice';
  static readonly TOOL: string = 'tool';
  static readonly TOOL_GROUP: string = 'toolGroup';
  static readonly TODO: string = 'todo';
  static readonly MARKER: string = 'marker';
}

/** 工具态 → 卡片配色档（终态 succeeded 绿；failed/cancelled 红；进行态黄）。 */
export function toolStatusTone(status: string): string {
  if (status === TimelineToolState.PREPARED || status === TimelineToolState.RUNNING) {
    return 'running';
  }
  if (status === TimelineToolState.SUCCEEDED) {
    return 'ok';
  }
  if (status === TimelineToolState.FAILED || status === TimelineToolState.CANCELLED) {
    return 'bad';
  }
  return 'other';
}

/** 进度缓冲上限（对齐 TUI MAX_PROGRESS_LEN/KEEP）：超限保尾部，不做无界累积。 */
const MAX_PROGRESS_LEN: number = 8192;
const PROGRESS_TAIL_KEEP: number = 6144;

/**
 * 正文/思考块硬上限（M13 防打爆）：`text_delta` 无界累积是单条大消息打爆
 * 前端的根因——内存驻留、每 flush 全文扫描、Markdown Worker 全量重 parse
 * 三条代价都随它线性涨。超限**保尾**（流式期用户看的是正在生成的尾部），
 * 丢弃段用提示行如实标注（timeline 正文服务端已摊平，没有 ref 可回拉）。
 */
const MAX_TEXT_LEN: number = 131072;
const TEXT_TAIL_KEEP: number = 98304;
const TEXT_TRUNCATED_NOTICE: string = '……（前文过长已省略，完整正文见桌面端）\n';

/** 流式轻量视图阈值：超过后不再把全文喂给 Markdown Worker（sealed 才做
 * 一次性全文排版），渲染降级为等宽尾部窗口（对齐思考链的窗口语义）。 */
export const LIVE_MARKDOWN_LIMIT: number = 8192;
/** 流式轻量视图的尾部窗口行数。 */
export const LIVE_TEXT_TAIL_LINES: number = 40;
/** 展开态工具正文显示上限（tool.output 服务端可能未截，这里兜显示面）。 */
const MAX_TOOL_BODY_CHARS: number = 65536;

/** 折叠预览的行数（工具正文 / thinking 滚动窗口 / todo 清单共用）。 */
export const PREVIEW_LINES: number = 3;

/** 尾部 n 行（滚动窗口取尾；无正文返回空串）。 */
export function tailLines(text: string, n: number): string {
  if (text.length === 0 || n <= 0) {
    return '';
  }
  let end: number = text.length;
  // 忽略末尾空行，让窗口贴着最后一条有内容的行。
  while (end > 0 && (text.charAt(end - 1) === '\n' || text.charAt(end - 1) === ' ')) {
    end--;
  }
  let found: number = 0;
  let cursor: number = end;
  while (cursor > 0 && found < n) {
    if (text.charAt(cursor - 1) === '\n') {
      found++;
      if (found >= n) {
        break;
      }
    }
    cursor--;
  }
  return text.substring(cursor, end);
}

/** 首部 n 行（终态正文预览取头——结局在开头；与取尾的滚动窗口相对）。 */
export function headLines(text: string, n: number): string {
  if (text.length === 0 || n <= 0) {
    return '';
  }
  let found: number = 0;
  for (let i = 0; i < text.length; i++) {
    if (text.charAt(i) === '\n') {
      found++;
      if (found >= n) {
        return text.substring(0, i);
      }
    }
  }
  return text;
}

/** 行数（'\n' 计数 + 末段；空串 0 行）。 */
export function countLines(text: string): number {
  if (text.length === 0) {
    return 0;
  }
  let lines: number = 1;
  for (let i = 0; i < text.length; i++) {
    if (text.charAt(i) === '\n') {
      lines++;
    }
  }
  return lines;
}

/** 工具名 → 人话（`todo_write` → `Todo Write`；镜像 TUI display_tool_name）。 */
export function displayToolName(name: string): string {
  const parts: string[] = name.split(/[_\-.]/);
  const words: string[] = [];
  for (const part of parts) {
    if (part.length === 0) {
      continue;
    }
    words.push(part.charAt(0).toUpperCase() + part.substring(1));
  }
  return words.join(' ');
}

/** lookup 族谓词（镜像 TUI is_lookup_tool）。 */
export function isLookupTool(name: string): boolean {
  return name === 'read' || name === 'read_file' || name === 'grep' ||
    name === 'search' || name === 'glob' || name === 'list';
}

/** todo 族谓词（对齐后端 dashboard::is_todo_tool；禁止各处再手写名单）。 */
export function isTodoTool(name: string): boolean {
  return name === 'todo_write' || name === 'todo_update' || name === 'todo_list';
}

/** lookup 分组的名词（摘要卡「读取了 N 个文件」）。 */
export function lookupGroupNoun(name: string): string {
  if (name === 'read' || name === 'read_file') {
    return '个文件';
  }
  if (name === 'grep' || name === 'search') {
    return '次搜索';
  }
  if (name === 'glob' || name === 'list') {
    return '个模式';
  }
  return '次调用';
}

/** 工具动词（卡片头部「读取 src/a.rs」式人话；未知名回退 displayToolName）。 */
export function toolVerb(name: string): string {
  if (name === 'bash' || name === 'exec' || name === 'shell' || name === 'pwsh' ||
    name === 'powershell' || name === 'command') {
    return '执行';
  }
  if (name === 'edit') {
    return '编辑';
  }
  if (name === 'write' || name === 'create' || name === 'patch') {
    return '写入';
  }
  if (name === 'read' || name === 'read_file') {
    return '读取';
  }
  if (name === 'grep' || name === 'search') {
    return '搜索';
  }
  if (name === 'glob' || name === 'list') {
    return '列出';
  }
  if (name === 'web_fetch' || name === 'fetch') {
    return '抓取';
  }
  return displayToolName(name);
}

/**
 * 卡片头部的「目标」：优先服务端 summary（人话参数，形如 `read src/lib.rs`，
 * 前缀与工具名重复时剥掉）；缺省时按参数里最常见的目标字段抽一小截。
 */
export function toolTarget(name: string, summary: string, argsText: string): string {
  let target: string = summary.trim();
  if (target.length > 0 && target.startsWith(name)) {
    target = target.substring(name.length).trim();
  }
  if (target.length > 0) {
    return target;
  }
  const fromArgs: string = pickArgTarget(argsText);
  if (fromArgs.length > 0) {
    return fromArgs;
  }
  return '';
}

const ARG_TARGET_KEYS: string[] = ['path', 'file_path', 'file', 'pattern', 'query',
  'cmd', 'command', 'url'];

function pickArgTarget(argsText: string): string {
  if (argsText.length === 0) {
    return '';
  }
  let parsed: Object | undefined;
  try {
    parsed = JSON.parse(argsText) as Object;
  } catch (error) {
    return '';
  }
  if (parsed === undefined) {
    return '';
  }
  const holder: Record<string, Object> = parsed as Record<string, Object>;
  for (const key of ARG_TARGET_KEYS) {
    const value: Object | undefined = holder[key];
    if (typeof value === 'string') {
      const text: string = value as string;
      return text.length > 96 ? `${text.substring(0, 96)}…` : text;
    }
  }
  return '';
}

/** todo 状态值（服务端只认这三个）。 */
export class TodoItemStatus {
  static readonly PENDING: string = 'pending';
  static readonly IN_PROGRESS: string = 'in_progress';
  static readonly COMPLETED: string = 'completed';
}

export class TodoItemView {
  readonly id: string;
  readonly title: string;
  status: string;
  evidence: string;

  constructor(id: string, title: string, status: string, evidence: string) {
    this.id = id;
    this.title = title;
    this.status = status;
    this.evidence = evidence;
  }
}

/**
 * todo_write 入参解析：`{"items":[{"id"?,"title","status",…}]}`。
 * 任一条目畸形就整体作废（半个计划比没有计划更误导人）——调用方回退普通工具卡。
 * 字段名是 `items`（实测契约），不是 Claude 的 todos 也不是 Codex 的 plan。
 */
export function parseTodoItems(argsText: string): TodoItemView[] | undefined {
  if (argsText.length === 0) {
    return undefined;
  }
  let parsed: Object | undefined;
  try {
    parsed = JSON.parse(argsText) as Object;
  } catch (error) {
    return undefined;
  }
  const holder: Record<string, Object> = parsed as Record<string, Object>;
  const raw: Object | undefined = holder['items'];
  if (raw === undefined || !Array.isArray(raw)) {
    return undefined;
  }
  const entries: Object[] = raw as Object[];
  if (entries.length === 0) {
    return undefined;
  }
  const out: TodoItemView[] = [];
  for (const entry of entries) {
    const item: Record<string, Object> = entry as Record<string, Object>;
    const title: Object | undefined = item['title'];
    const status: Object | undefined = item['status'];
    if (typeof title !== 'string' || (title as string).length === 0 ||
      typeof status !== 'string') {
      return undefined;
    }
    const idValue: Object | undefined = item['id'];
    const evidenceValue: Object | undefined = item['evidence'];
    out.push(new TodoItemView(typeof idValue === 'string' ? idValue as string : '',
      title as string, status as string,
      typeof evidenceValue === 'string' ? evidenceValue as string : ''));
  }
  return out;
}

/** todo_update delta 解析：`{id,status,evidence?}`（一次一条，无批量形态）。 */
export function parseTodoUpdate(argsText: string): TodoItemView | undefined {
  if (argsText.length === 0) {
    return undefined;
  }
  let parsed: Object | undefined;
  try {
    parsed = JSON.parse(argsText) as Object;
  } catch (error) {
    return undefined;
  }
  const holder: Record<string, Object> = parsed as Record<string, Object>;
  const id: Object | undefined = holder['id'];
  const status: Object | undefined = holder['status'];
  if (typeof id !== 'string' || (id as string).trim().length === 0 ||
    typeof status !== 'string') {
    return undefined;
  }
  const statusText: string = status as string;
  if (statusText !== TodoItemStatus.PENDING && statusText !== TodoItemStatus.IN_PROGRESS &&
    statusText !== TodoItemStatus.COMPLETED) {
    return undefined;
  }
  const evidence: Object | undefined = holder['evidence'];
  return new TodoItemView((id as string).trim(), '', statusText,
    typeof evidence === 'string' ? evidence as string : '');
}

/** 渲染顺序：进行中 → 待办 → 已完成（稳定排序保留原始次序；镜像 TUI ordered）。 */
export function orderTodoItems(items: TodoItemView[]): TodoItemView[] {
  const indexed: TodoItemView[][] = [];
  const rank = (status: string): number => {
    if (status === TodoItemStatus.IN_PROGRESS) {
      return 0;
    }
    if (status === TodoItemStatus.COMPLETED) {
      return 2;
    }
    return 1;
  };
  const buckets: TodoItemView[][] = [[], [], []];
  for (const item of items) {
    buckets[rank(item.status)].push(item);
  }
  for (const bucket of buckets) {
    for (const item of bucket) {
      indexed.push([item]);
    }
  }
  const out: TodoItemView[] = [];
  for (const pair of indexed) {
    out.push(pair[0]);
  }
  return out;
}

/** 分组摘要卡的一个成员（target 行清单）。 */
export class ToolGroupMember {
  readonly rowId: string;
  readonly target: string;

  constructor(rowId: string, target: string) {
    this.rowId = rowId;
    this.target = target;
  }
}

/** 一条渲染行。跨结构重建复用实例（rowPool），内容变更只 bump revision。 */
export class TranscriptRow {
  readonly rowId: string;
  readonly kind: string;
  /** 显示内容版本号：dirty drain 后视图侧据此决定局部刷新。 */
  revision: number = 0;
  turnId: string = '';

  // user / text / notice / marker
  text: string = '';
  sealed: boolean = false;
  /** 超过硬上限发生过保尾截断（text/thinking 行如实标注）。 */
  truncated: boolean = false;

  // thinking：fullText 全文；live 渲尾部窗口，sealed 折摘要
  lineCount: number = 0;
  expanded: boolean = false;

  // tool
  callId: string = '';
  toolName: string = '';
  toolState: string = '';
  target: string = '';
  argsText: string = '';
  outputText: string = '';
  errorText: string = '';
  progressText: string = '';
  diffText: string = '';
  bodyText: string = '';
  hiddenLines: number = 0;

  // toolGroup
  groupVerb: string = '';
  groupNoun: string = '';
  members: ToolGroupMember[] = [];

  // todo
  todoItems: TodoItemView[] = [];

  constructor(rowId: string, kind: string) {
    this.rowId = rowId;
    this.kind = kind;
  }

  touch(): void {
    this.revision++;
  }
}

/** 可变块状态（直播增量就地改，条目顺序由 block_order 固定）。 */
/** 增量里的换行数（行数缓存的增量维护；全文扫描只发生在覆盖/截断重置）。 */
function countNewlines(text: string): number {
  let n: number = 0;
  for (let i = 0; i < text.length; i++) {
    if (text.charAt(i) === '\n') {
      n++;
    }
  }
  return n;
}

class BlockView {
  readonly blockId: string;
  kind: string;
  order: number;
  state: string;
  text: string;
  /** 行数缓存（= countLines(text) 同口径；增量维护，全文扫描只进覆盖/截断）。 */
  lineCount: number = 0;
  /** 换行数累计（lineCount 的增量底账：非空文本行数 = 换行数 + 1）。 */
  private newlines: number = 0;
  /** 超过硬上限发生过保尾截断（UI 如实标注）。 */
  truncated: boolean = false;
  tool: TimelineTool | undefined;
  /** tool_progress 累积缓冲（不再逐 chunk 重建 TimelineTool）。 */
  progress: string = '';
  progressTruncated: boolean = false;
  /** 被拆组后单独显示（不许再回组——TUI「展开即拆组」语义）。 */
  soloExpanded: boolean = false;

  constructor(block: TimelineBlock) {
    this.blockId = block.blockId;
    this.kind = block.kind;
    this.order = block.blockOrder;
    this.state = block.state;
    this.text = '';
    this.tool = block.tool;
    this.setText(block.text);
  }

  /** 流式追加：行数只数增量换行，全文扫描不进热路径。 */
  appendText(delta: string): void {
    if (delta.length === 0) {
      return;
    }
    this.newlines += countNewlines(delta);
    this.text += delta;
    this.lineCount = this.text.length === 0 ? 0 : this.newlines + 1;
    this.normalizeText();
  }

  /** 整体覆盖（checkpoint `text` / 服务端块快照 / 回合重放）。 */
  setText(text: string): void {
    this.text = text;
    this.newlines = countNewlines(text);
    this.lineCount = text.length === 0 ? 0 : this.newlines + 1;
    this.normalizeText();
  }

  private normalizeText(): void {
    if (this.text.length <= MAX_TEXT_LEN) {
      return;
    }
    this.text = TEXT_TRUNCATED_NOTICE +
      this.text.substring(this.text.length - TEXT_TAIL_KEEP);
    this.newlines = countNewlines(this.text);
    this.lineCount = this.newlines + 1;
    this.truncated = true;
  }
}

class RoundView {
  readonly roundNum: number;
  sealed: boolean;
  isFinal: boolean;
  readonly blocks: BlockView[] = [];

  constructor(roundNum: number, sealed: boolean, isFinal: boolean) {
    this.roundNum = roundNum;
    this.sealed = sealed;
    this.isFinal = isFinal;
  }
}

class TurnView {
  readonly turnId: string;
  userText: string;
  state: string;
  sealed: boolean;
  failureCode: string;
  failureMessage: string;
  readonly rounds: RoundView[] = [];
  /** block_id → 块（直播增量按 id 定位，避免线性扫全表）。 */
  readonly blocks: Map<string, BlockView> = new Map();

  constructor(turnId: string, userText: string, state: string, sealed: boolean) {
    this.turnId = turnId;
    this.userText = userText;
    this.state = state;
    this.sealed = sealed;
    this.failureCode = '';
    this.failureMessage = '';
  }

  round(num: number): RoundView {
    for (const round of this.rounds) {
      if (round.roundNum === num) {
        return round;
      }
    }
    const created: RoundView = new RoundView(num, false, false);
    this.rounds.push(created);
    return created;
  }

  lastRound(): RoundView {
    return this.rounds.length > 0 ? this.rounds[this.rounds.length - 1] : this.round(0);
  }

  /** 按 (round, block_order) 的展示序枚举块。 */
  orderedBlocks(out: BlockView[]): void {
    for (const round of this.rounds) {
      for (const block of round.blocks) {
        out.push(block);
      }
    }
  }
}

export class TranscriptModel {
  private readonly turns: TurnView[] = [];
  private readonly turnIndex: Map<string, TurnView> = new Map();
  /** rowId → 行实例（跨重建复用；隐藏组成员也留在池里保持身份稳定）。 */
  private readonly rowPool: Map<string, TranscriptRow> = new Map();
  private rows: TranscriptRow[] = [];
  private structuralVersionValue: number = 0;
  private readonly dirty: Set<TranscriptRow> = new Set();
  /** 未建模的 timeline 事件类型（漂移可见化，UI 可提示但不该断流）。 */
  private unrecognizedEventType: string = '';
  /** 进行中回合计数（turnActiveValue 的 O(1) 形态）。 */
  private runningTurns: number = 0;
  /** todo 面板快照（write 整表替换、update 按 id 折叠；最后一条 todo 卡活渲染）。 */
  private todoPanel: TodoItemView[] = [];
  private todoPanelVersionValue: number = 0;
  /** 最后一条 todo_write 卡的 rowId：它渲染面板实时态，其余卡保持当时快照。 */
  private lastTodoRowId: string = '';

  reset(): void {
    this.turns.length = 0;
    this.turnIndex.clear();
    this.rowPool.clear();
    this.rows = [];
    this.dirty.clear();
    this.unrecognizedEventType = '';
    this.runningTurns = 0;
    this.todoPanel = [];
    this.structuralVersionValue++;
  }

  unrecognizedEventValue(): string {
    return this.unrecognizedEventType;
  }

  structuralVersion(): number {
    return this.structuralVersionValue;
  }

  /** 当前行表（引用稳定；结构变化后换新数组）。 */
  rowsRef(): TranscriptRow[] {
    return this.rows;
  }

  /** 取走并清空脏行（视图节流器在 flush 节拍调用）。 */
  drainDirty(): TranscriptRow[] {
    const out: TranscriptRow[] = [];
    for (const row of this.dirty) {
      out.push(row);
    }
    this.dirty.clear();
    return out;
  }

  todoPanelItems(): TodoItemView[] {
    return this.todoPanel;
  }

  todoPanelVersion(): number {
    return this.todoPanelVersionValue;
  }

  /** 快照 seed：整段历史（oldest→newest）一次到位。 */
  seed(turns: TimelineTurn[]): void {
    this.reset();
    for (const turn of turns) {
      this.pushTurn(this.toTurnView(turn));
    }
    this.rebuildTodoPanel();
    this.rebuild();
    this.refreshRunningTurns();
  }

  /** 深翻页：把更早的一页接到开头（游标由调用方维护）。 */
  prependOlder(turns: TimelineTurn[]): void {
    const existing: TurnView[] = this.turns.slice();
    this.turns.length = 0;
    this.turnIndex.clear();
    for (const turn of turns) {
      this.pushTurn(this.toTurnView(turn));
    }
    for (const view of existing) {
      this.pushTurn(view);
    }
    this.rebuildTodoPanel();
    this.rebuild();
    this.refreshRunningTurns();
  }

  private toTurnView(turn: TimelineTurn): TurnView {
    const view: TurnView = new TurnView(turn.turnId, turn.userText, turn.state, turn.sealed);
    if (turn.failure !== undefined) {
      view.failureCode = turn.failure.code;
      view.failureMessage = turn.failure.message;
    }
    for (const round of turn.rounds) {
      const roundView: RoundView = view.round(round.roundNum);
      roundView.sealed = round.sealed;
      roundView.isFinal = round.isFinal;
      for (const block of round.blocks) {
        const blockView: BlockView = new BlockView(block);
        blockView.progress = capProgressTail(block.tool !== undefined
          ? block.tool.progress : '');
        roundView.blocks.push(blockView);
        view.blocks.set(blockView.blockId, blockView);
      }
    }
    return view;
  }

  private rebuildTodoPanel(): void {
    // 面板取全历史重放的最新真值（write 整表替换、update 按 id 折叠），与正文一致。
    const panel: TodoItemView[] = [];
    for (const turn of this.turns) {
      const blocks: BlockView[] = [];
      turn.orderedBlocks(blocks);
      for (const block of blocks) {
        if (block.kind !== TimelineBlockKind.TOOL || block.tool === undefined) {
          continue;
        }
        const tool: TimelineTool = block.tool;
        if (!isTodoTool(tool.name)) {
          continue;
        }
        if (tool.name === 'todo_write') {
          const items: TodoItemView[] | undefined = parseTodoItems(tool.argsText);
          if (items !== undefined) {
            panel.length = 0;
            for (const item of items) {
              panel.push(item);
            }
          }
        } else if (tool.name === 'todo_update') {
          const delta: TodoItemView | undefined = parseTodoUpdate(tool.argsText);
          if (delta !== undefined) {
            applyTodoDelta(panel, delta);
          }
        }
      }
    }
    this.todoPanel = panel;
    this.todoPanelVersionValue++;
  }

  private pushTurn(view: TurnView): void {
    this.turns.push(view);
    this.turnIndex.set(view.turnId, view);
  }

  private row(rowId: string, kind: string): TranscriptRow {
    const existing: TranscriptRow | undefined = this.rowPool.get(rowId);
    if (existing !== undefined && existing.kind === kind) {
      return existing;
    }
    const created: TranscriptRow = new TranscriptRow(rowId, kind);
    this.rowPool.set(rowId, created);
    return created;
  }

  /** 从后往前找最后一条 todo_write 清单卡（它承担「计划实时视图」职责）。 */
  private findLastTodoRowId(): string {
    for (let t = this.turns.length - 1; t >= 0; t--) {
      const blocks: BlockView[] = [];
      this.turns[t].orderedBlocks(blocks);
      for (let b = blocks.length - 1; b >= 0; b--) {
        const block: BlockView = blocks[b];
        if (block.kind === TimelineBlockKind.TOOL && block.tool !== undefined &&
          isTodoTool(block.tool.name) &&
          parseTodoItems(block.tool.argsText) !== undefined) {
          return blockRowId(this.turns[t].turnId, block.blockId);
        }
      }
    }
    return '';
  }

  /** 直播增量就地应用。回合不存在时按 turn_opened 的到达顺序补建（不乱序猜内容）。 */
  applyEntry(entry: TimelineEntry): void {
    const event: TimelineEvent = entry.event;
    let turn: TurnView | undefined = this.turnIndex.get(entry.turnId);
    if (turn === undefined) {
      turn = new TurnView(entry.turnId, '', TimelineTurnState.RUNNING, false);
      this.pushTurn(turn);
      this.runningTurns++;
      this.rebuild();
    }
    const round: RoundView = entry.roundNum !== undefined
      ? turn.round(entry.roundNum) : turn.lastRound();

    if (event.type === 'turn_opened') {
      turn.userText = event.userText;
      if (!turn.sealed && turn.state !== TimelineTurnState.RUNNING) {
        this.runningTurns++;
      }
      turn.state = TimelineTurnState.RUNNING;
      turn.sealed = false;
      this.rebuild();
      return;
    }
    if (event.type === 'block_opened' && event.block !== undefined) {
      const block: TimelineBlock = event.block;
      const existing: BlockView | undefined = turn.blocks.get(block.blockId);
      if (existing !== undefined) {
        // 重放/快照重叠：就地补齐，不新增条目（条目顺序由 block_order 定）。
        existing.kind = block.kind;
        existing.state = block.state;
        if (block.text.length > 0) {
          existing.setText(block.text);
        }
        existing.tool = block.tool !== undefined ? block.tool : existing.tool;
        this.rebuild();
        return;
      }
      const created: BlockView = new BlockView(block);
      round.blocks.push(created);
      turn.blocks.set(created.blockId, created);
      this.rebuild();
      return;
    }
    if (event.type === 'text_delta') {
      const block: BlockView | undefined = turn.blocks.get(event.blockId);
      if (block !== undefined) {
        block.appendText(event.delta);
        this.dirtyRow(turn, block);
      }
      return;
    }
    if (event.type === 'block_checkpoint') {
      const block: BlockView | undefined = turn.blocks.get(event.blockId);
      if (block === undefined) {
        return;
      }
      // 服务端契约：`arg` 是增量、`text` 是整体覆盖（增量不可导时才给）。
      if (event.text.length > 0) {
        block.setText(event.text);
      } else if (event.arg.length > 0) {
        block.appendText(event.arg);
      }
      this.dirtyRow(turn, block);
      return;
    }
    if (event.type === 'tool_updated') {
      const block: BlockView | undefined = turn.blocks.get(event.blockId);
      if (block !== undefined && event.tool !== undefined) {
        block.tool = event.tool;
        block.state = TimelineBlockState.SEALED;
        if (block.progress.length === 0) {
          block.progress = capProgressTail(event.tool.progress);
        }
        if (isTodoTool(event.tool.name)) {
          this.rebuildTodoPanel();
        }
        this.rebuild();
      }
      return;
    }
    if (event.type === 'tool_progress') {
      const block: BlockView | undefined = turn.blocks.get(event.blockId);
      if (block !== undefined) {
        // 有界累积 + 只保尾部（TUI 纪律：无界进度是内存税）。
        if (event.truncated) {
          block.progressTruncated = true;
        } else {
          block.progress = capProgressTail(`${block.progress}${event.chunk}`);
        }
        this.dirtyRow(turn, block);
      }
      return;
    }
    if (event.type === 'block_sealed') {
      const block: BlockView | undefined = turn.blocks.get(event.blockId);
      if (block !== undefined) {
        block.state = TimelineBlockState.SEALED;
        if (block.kind === TimelineBlockKind.REASONING) {
          // 空正文的 sealed reasoning 不进历史（TUI adapter 规则）→ 结构变化。
          if (block.text.length === 0) {
            this.rebuild();
          } else {
            this.dirtyRow(turn, block);
          }
        } else {
          this.dirtyRow(turn, block);
        }
      }
      return;
    }
    if (event.type === 'round_sealed') {
      round.sealed = true;
      round.isFinal = event.isFinal;
      return;
    }
    if (event.type === 'turn_sealed') {
      if (!turn.sealed && turn.state === TimelineTurnState.RUNNING) {
        this.runningTurns--;
      }
      turn.state = event.state.length > 0 ? event.state : TimelineTurnState.COMPLETED;
      turn.sealed = true;
      if (event.failure !== undefined) {
        turn.failureCode = event.failure.code;
        turn.failureMessage = event.failure.message;
      }
      this.rebuild();
      return;
    }
    if (event.type !== 'tool_estimated') {
      // 后端新增变体：不显示、不断流，但要让漂移看得见。
      this.unrecognizedEventType = event.type;
    }
  }

  /** 展开/折叠（工具单卡、thinking、todo 预览、分组拆卡）。返回是否变化。 */
  toggleExpanded(rowId: string): boolean {
    const row: TranscriptRow | undefined = this.rowPool.get(rowId);
    if (row === undefined) {
      return false;
    }
    if (row.kind === TranscriptRowKind.TOOL_GROUP) {
      // 展开即拆组：成员块单独成卡（各自折叠态），组卡消失。
      for (const member of row.members) {
        const parsed: string[] = splitRowId(member.rowId);
        const turn: TurnView | undefined = this.turnIndex.get(parsed[0]);
        if (turn === undefined) {
          continue;
        }
        const block: BlockView | undefined = turn.blocks.get(parsed[1]);
        if (block !== undefined) {
          block.soloExpanded = true;
        }
      }
      this.rebuild();
      return true;
    }
    row.expanded = !row.expanded;
    if (row.kind === TranscriptRowKind.TOOL) {
      // 正文预览/全文要按新展开态重算。
      this.rebuild();
      return true;
    }
    row.touch();
    this.dirty.add(row);
    return true;
  }

  /** 块内容变更 → 对应行就地刷新并标脏；行缺失或类别漂移则结构重建。 */
  private dirtyRow(turn: TurnView, block: BlockView): void {
    const rowId: string = blockRowId(turn.turnId, block.blockId);
    const row: TranscriptRow | undefined = this.rowPool.get(rowId);
    if (row === undefined || row.kind !== this.blockRowKind(block)) {
      this.rebuild();
      return;
    }
    this.fillBlockRow(row, turn, block);
    this.dirty.add(row);
  }

  /** 行表重建：复用 rowPool 实例，只换数组与新行。 */
  private rebuild(): void {
    this.lastTodoRowId = this.findLastTodoRowId();
    const next: TranscriptRow[] = [];
    for (const turn of this.turns) {
      if (turn.userText.length > 0) {
        const userRow: TranscriptRow = this.row(`${turn.turnId}:user`,
          TranscriptRowKind.USER);
        userRow.text = turn.userText;
        userRow.turnId = turn.turnId;
        userRow.touch();
        next.push(userRow);
      }
      const blocks: BlockView[] = [];
      turn.orderedBlocks(blocks);
      let i: number = 0;
      while (i < blocks.length) {
        const block: BlockView = blocks[i];
        if (block.kind === TimelineBlockKind.REASONING &&
          block.state === TimelineBlockState.SEALED && block.text.length === 0) {
          i++;
          continue; // 空正文的 sealed reasoning 不进历史（TUI adapter 规则）。
        }
        const groupLen: number = lookupGroupLen(turn, blocks, i);
        if (groupLen >= 2) {
          next.push(this.buildGroupRow(turn, blocks, i, groupLen));
          i += groupLen;
          continue;
        }
        const row: TranscriptRow = this.row(blockRowId(turn.turnId, block.blockId),
          this.blockRowKind(block));
        this.fillBlockRow(row, turn, block);
        next.push(row);
        i += 1;
      }
      if (turn.sealed || turn.state !== TimelineTurnState.RUNNING) {
        const label: string = turnStateLabel(turn.state);
        const detail: string = turn.failureMessage.length > 0
          ? `${label}（${turn.failureCode}: ${turn.failureMessage}）` : label;
        const markerRow: TranscriptRow = this.row(`${turn.turnId}:marker`,
          TranscriptRowKind.MARKER);
        markerRow.text = `— 回合 ${detail} —`;
        markerRow.turnId = turn.turnId;
        markerRow.touch();
        next.push(markerRow);
      }
    }
    this.rows = next;
    this.structuralVersionValue++;
  }

  private blockRowKind(block: BlockView): string {
    if (block.kind === TimelineBlockKind.REASONING) {
      return TranscriptRowKind.THINKING;
    }
    if (block.kind === TimelineBlockKind.TOOL) {
      const tool: TimelineTool | undefined = block.tool;
      if (tool !== undefined && isTodoTool(tool.name) &&
        parseTodoItems(tool.argsText) !== undefined) {
        return TranscriptRowKind.TODO;
      }
      return TranscriptRowKind.TOOL;
    }
    if (block.kind === TimelineBlockKind.NOTICE) {
      return TranscriptRowKind.NOTICE;
    }
    return TranscriptRowKind.TEXT;
  }

  private fillBlockRow(row: TranscriptRow, turn: TurnView, block: BlockView): void {
    row.turnId = turn.turnId;
    row.sealed = block.state === TimelineBlockState.SEALED;
    row.truncated = block.truncated;
    const kind: string = this.blockRowKind(block);
    if (kind === TranscriptRowKind.THINKING) {
      row.text = block.text;
      row.lineCount = block.lineCount;
    } else if (kind === TranscriptRowKind.TOOL || kind === TranscriptRowKind.TODO) {
      const tool: TimelineTool | undefined = block.tool;
      row.callId = tool !== undefined ? tool.toolCallId : '';
      row.toolName = tool !== undefined ? tool.name : '';
      // 占位卡（tool_updated 未到）按进行态上色，别闪一下「其他/终态」。
      row.toolState = tool !== undefined ? tool.state : TimelineToolState.PREPARED;
      row.target = tool !== undefined
        ? toolTarget(tool.name, tool.summary, tool.argsText) : '';
      row.argsText = TranscriptModel.capToolBody(tool !== undefined ? tool.argsText : '');
      row.outputText = TranscriptModel.capToolBody(tool !== undefined ? tool.output : '');
      row.errorText = tool !== undefined && tool.failure !== undefined
        ? `${tool.failure.code}: ${tool.failure.message}` : '';
      row.progressText = block.progress;
      row.diffText = tool !== undefined ? tool.diff : '';
      if (kind === TranscriptRowKind.TODO) {
        if (row.rowId === this.lastTodoRowId) {
          // 最后一条计划卡 = 实时清单（todo_update 折叠进面板后就地更新）。
          row.todoItems = this.todoPanel;
        } else {
          const items: TodoItemView[] | undefined =
            tool !== undefined ? parseTodoItems(tool.argsText) : undefined;
          row.todoItems = items !== undefined ? items : [];
        }
      }
      if (tool !== undefined && isTodoTool(tool.name)) {
        // todo 族卡片不 dump 原始 args JSON：清单信息卡自带渲染，
        // 状态推进的实时视图在侧栏面板（TUI 同款分流，避免满屏参数噪音）。
        row.bodyText = '';
        row.hiddenLines = 0;
        if (row.target.length === 0 && tool.name === 'todo_update') {
          row.target = todoUpdateTarget(tool.argsText);
        }
        row.touch();
        return;
      }
      this.fillToolBody(row, block.progress.length > 0 ? row.progressText
        : row.outputText.length > 0 ? row.outputText
          : row.errorText.length > 0 ? row.errorText : row.diffText,
        tool !== undefined && isEditTool(tool.name));
    } else {
      row.text = block.text.length > 0 ? block.text : `[${block.kind} 待补]`;
      row.lineCount = block.lineCount;
    }
    row.touch();
  }

  /** 展开态工具正文显示上限（head 保留——工具输出结局常在开头/末行都有用，取头）。 */
  private static capToolBody(body: string): string {
    return body.length > MAX_TOOL_BODY_CHARS
      ? `${body.substring(0, MAX_TOOL_BODY_CHARS)}\n……（余下已省略）` : body;
  }

  /** 折叠预览：进行态取尾（滚动窗口），终态取头；展开态给全文。 */
  private fillToolBody(row: TranscriptRow, body: string, editTool: boolean): void {
    void editTool;
    if (row.expanded) {
      row.bodyText = TranscriptModel.capToolBody(body);
      row.hiddenLines = 0;
      return;
    }
    const running: boolean = toolStatusTone(row.toolState) === 'running';
    const shown: string = running ? tailLines(body, PREVIEW_LINES)
      : headLines(body, PREVIEW_LINES);
    row.bodyText = shown;
    row.hiddenLines = Math.max(0, countLines(body) - PREVIEW_LINES);
  }

  private buildGroupRow(turn: TurnView, blocks: BlockView[], start: number,
    len: number): TranscriptRow {
    const head: BlockView = blocks[start];
    const headTool: TimelineTool = head.tool as TimelineTool;
    const rowId: string = `grp:${turn.turnId}:${head.blockId}`;
    const row: TranscriptRow = this.row(rowId, TranscriptRowKind.TOOL_GROUP);
    row.turnId = turn.turnId;
    row.sealed = true;
    row.toolName = headTool.name;
    row.toolState = TimelineToolState.SUCCEEDED;
    row.groupVerb = toolVerb(headTool.name);
    row.groupNoun = lookupGroupNoun(headTool.name);
    row.target = '';
    const members: ToolGroupMember[] = [];
    for (let i = start; i < start + len; i++) {
      const member: TimelineTool = blocks[i].tool as TimelineTool;
      const summary: string = toolTarget(member.name, member.summary, member.argsText);
      members.push(new ToolGroupMember(blockRowId(turn.turnId, blocks[i].blockId),
        summary.length > 0 ? summary : displayToolName(member.name)));
    }
    row.members = members;
    row.touch();
    return row;
  }

  /** 回合进行中（UI 的「停止」按钮与排队提示靠它）。 */
  turnActiveValue(): boolean {
    return this.runningTurns > 0;
  }

  private refreshRunningTurns(): void {
    let running: number = 0;
    for (const turn of this.turns) {
      if (!turn.sealed && turn.state === TimelineTurnState.RUNNING) {
        running++;
      }
    }
    this.runningTurns = running;
  }
}

function blockRowId(turnId: string, blockId: string): string {
  return `${turnId}:${blockId}`;
}

function splitRowId(rowId: string): string[] {
  const idx: number = rowId.indexOf(':');
  return [rowId.substring(0, idx), rowId.substring(idx + 1)];
}

function isEditTool(name: string): boolean {
  return name === 'edit' || name === 'write' || name === 'patch' || name === 'create';
}

/** 回合态中文标签（标记行不再中英混排）。 */
function turnStateLabel(state: string): string {
  if (state === TimelineTurnState.COMPLETED) {
    return '完成';
  }
  if (state === TimelineTurnState.FAILED) {
    return '失败';
  }
  if (state === TimelineTurnState.CANCELLED) {
    return '已取消';
  }
  return state;
}

/** todo_update 的头部目标：`T1 → 已完成`（信息在面板，卡片不 dump JSON）。 */
function todoUpdateTarget(argsText: string): string {
  const delta: TodoItemView | undefined = parseTodoUpdate(argsText);
  if (delta === undefined) {
    return '';
  }
  let label: string = delta.status;
  if (delta.status === TodoItemStatus.COMPLETED) {
    label = '已完成';
  } else if (delta.status === TodoItemStatus.IN_PROGRESS) {
    label = '进行中';
  } else if (delta.status === TodoItemStatus.PENDING) {
    label = '待办';
  }
  return `${delta.id} → ${label}`;
}

/** 有界进度尾部保留（对齐 TUI MAX_PROGRESS_LEN/PROGRESS_TAIL_KEEP）。 */
function capProgressTail(text: string): string {
  if (text.length <= MAX_PROGRESS_LEN) {
    return text;
  }
  return text.substring(text.length - PROGRESS_TAIL_KEEP);
}

function applyTodoDelta(panel: TodoItemView[], delta: TodoItemView): void {
  for (const item of panel) {
    if (item.id === delta.id) {
      item.status = delta.status;
      if (delta.evidence.length > 0) {
        item.evidence = delta.evidence;
      }
      return;
    }
  }
}

/**
 * lookup 合并长度（<2 = 不合并）：连续、同工具、全部成功、未展开、无截断进度。
 * 混进失败/运行中/拆组成员就不再合并——那些形状本身就是信息，不该被汇总卡盖掉。
 */
function lookupGroupLen(turn: TurnView, blocks: BlockView[], start: number): number {
  const first: BlockView = blocks[start];
  if (!groupable(first) || first.tool === undefined) {
    return 0;
  }
  const name: string = (first.tool as TimelineTool).name;
  if (!isLookupTool(name)) {
    return 0;
  }
  let len: number = 1;
  for (let i = start + 1; i < blocks.length; i++) {
    const block: BlockView = blocks[i];
    if (!groupable(block) || block.tool === undefined ||
      (block.tool as TimelineTool).name !== name) {
      break;
    }
    len++;
  }
  return len < 2 ? 0 : len;
}

function groupable(block: BlockView): boolean {
  if (block.kind !== TimelineBlockKind.TOOL || block.tool === undefined) {
    return false;
  }
  const tool: TimelineTool = block.tool;
  return tool.state === TimelineToolState.SUCCEEDED && !block.soloExpanded &&
    !block.progressTruncated;
}
