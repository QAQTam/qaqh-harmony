/**
 * 正文行的视图模型与数据源（M8，任务「流式 O1 优化」的渲染侧）。
 *
 * 契约：TranscriptModel 负责语义（分组/折叠/脏标记），这里负责把它接到
 * LazyForEach——
 * - 结构版本变了才 notifyDataReload（块增删/拆合组/展开切换）；
 * - 逐字增量只把脏行内容抄进复用的 RowVm 实例，@Observed/@ObjectLink
 *   自动局部刷新对应卡片，不重渲整表；
 * - RowVm 按 rowId 复用，卡片组件身份稳定（滚动位置/动画不闪）。
 */

import {
  TranscriptModel, TranscriptRow, TranscriptRowKind, TodoItemView,
  PREVIEW_LINES, LIVE_MARKDOWN_LIMIT, LIVE_TEXT_TAIL_LINES, tailLines, toolStatusTone
} from '@qaqh/client';

/** 行视图模型：@Observed 让绑定它的子组件只在该行内容变化时重渲。 */
@Observed
export class RowVm {
  readonly rowId: string;
  readonly kind: string;
  turnId: string = '';
  revision: number = -1;

  text: string = '';
  sealed: boolean = false;
  expanded: boolean = false;

  /** thinking：live 渲尾部窗口；sealed 折摘要；展开给全文。 */
  live: boolean = false;
  lineCount: number = 0;
  displayText: string = '';
  /** text 行：流式期超阈降级（等宽尾窗，sealed 才 Markdown 全文排版）。 */
  liveOversize: boolean = false;
  /** text/thinking 行发生过保尾截断（UI 如实标注）。 */
  truncated: boolean = false;

  toolName: string = '';
  toolState: string = '';
  tone: string = 'other';
  target: string = '';
  argsText: string = '';
  errorText: string = '';
  bodyText: string = '';
  hiddenLines: number = 0;

  groupVerb: string = '';
  groupNoun: string = '';
  memberTargets: string[] = [];

  todoItems: TodoItemView[] = [];
  todoDone: number = 0;

  constructor(rowId: string, kind: string) {
    this.rowId = rowId;
    this.kind = kind;
  }

  syncFrom(row: TranscriptRow): void {
    if (row.revision === this.revision && this.revision >= 0) {
      return; // 版本号就是脏判据：没变不抄。
    }
    this.revision = row.revision;
    this.turnId = row.turnId;
    this.text = row.text;
    this.sealed = row.sealed;
    this.expanded = row.expanded;
    this.lineCount = row.lineCount;
    this.truncated = row.truncated;
    this.live = row.kind === TranscriptRowKind.THINKING && !row.sealed;
    if (row.kind === TranscriptRowKind.THINKING) {
      if (row.expanded || !row.sealed) {
        this.displayText = row.sealed ? row.text : tailLines(row.text, PREVIEW_LINES);
      } else {
        this.displayText = '';
      }
      this.liveOversize = false;
    } else if (row.kind === TranscriptRowKind.TEXT) {
      // M13 长文流式降级：live 且超阈只给等宽尾窗（Markdown Worker 不吃增量），
      // sealed 后一次性全文排版。
      if (!row.sealed && row.text.length > LIVE_MARKDOWN_LIMIT) {
        this.liveOversize = true;
        this.displayText = tailLines(row.text, LIVE_TEXT_TAIL_LINES);
      } else {
        this.liveOversize = false;
        this.displayText = row.text;
      }
    } else {
      this.displayText = row.text;
      this.liveOversize = false;
    }
    this.toolName = row.toolName;
    this.toolState = row.toolState;
    this.tone = row.toolState.length > 0 ? toolStatusTone(row.toolState) : 'other';
    this.target = row.target;
    this.argsText = row.argsText;
    this.errorText = row.errorText;
    this.bodyText = row.bodyText;
    this.hiddenLines = row.hiddenLines;
    this.groupVerb = row.groupVerb;
    this.groupNoun = row.groupNoun;
    if (row.members.length > 0 || this.memberTargets.length > 0) {
      const targets: string[] = [];
      for (const member of row.members) {
        targets.push(member.target);
      }
      this.memberTargets = targets;
    }
    if (row.kind === TranscriptRowKind.TODO) {
      this.todoItems = row.todoItems;
      let done: number = 0;
      for (const item of row.todoItems) {
        if (item.status === 'completed') {
          done++;
        }
      }
      this.todoDone = done;
    }
  }
}

/** LazyForEach 数据源：结构变化 reload，内容变化走 @Observed 局部刷新。 */
export class RowsDataSource implements IDataSource {
  private rows: RowVm[] = [];
  private readonly vmById: Map<string, RowVm> = new Map();
  private listeners: DataChangeListener[] = [];
  private model: TranscriptModel | undefined;
  private lastStructural: number = -1;

  attach(model: TranscriptModel | undefined): void {
    this.model = model;
    this.lastStructural = -1;
    this.rows = [];
    this.vmById.clear();
  }

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): RowVm {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter(
      (item: DataChangeListener) => item !== listener);
  }

  /** 同步一次；返回是否发生结构重建（供滚动跟随决策）。 */
  sync(): boolean {
    const model = this.model;
    if (model === undefined) {
      return false;
    }
    if (model.structuralVersion() !== this.lastStructural) {
      const rows = model.rowsRef();
      const next: RowVm[] = [];
      const alive: Set<string> = new Set();
      for (const row of rows) {
        let vm: RowVm | undefined = this.vmById.get(row.rowId);
        if (vm === undefined) {
          vm = new RowVm(row.rowId, row.kind);
          this.vmById.set(row.rowId, vm);
        }
        vm.syncFrom(row);
        next.push(vm);
        alive.add(row.rowId);
      }
      // 掉出画面的行（拆组后的组成员、被丢弃的空 reasoning）清掉引用。
      const deadKeys: string[] = [];
      this.vmById.forEach((vm: RowVm, key: string) => {
        if (!alive.has(key)) {
          deadKeys.push(key);
        }
      });
      for (const key of deadKeys) {
        this.vmById.delete(key);
      }
      this.rows = next;
      this.lastStructural = model.structuralVersion();
      this.notifyDataReload();
      return true;
    }
    for (const row of model.drainDirty()) {
      const vm: RowVm | undefined = this.vmById.get(row.rowId);
      if (vm !== undefined) {
        vm.syncFrom(row);
      }
    }
    return false;
  }

  /** 行是否存在（调试/测试用）。 */
  hasRow(rowId: string): boolean {
    return this.vmById.has(rowId);
  }

  private notifyDataReload(): void {
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}
