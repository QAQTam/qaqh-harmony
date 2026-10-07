/**
 * 交互正文解析（镜像 qaqh-domain interaction_body.rs——content store 中
 * `application/vnd.qaqh.interaction-request+json` 的单一来源）。
 *
 * 与 delta 不同，正文是**展示面**：未知 kind 不抛错（保留 raw 交给 UI 降级
 * 展示），只有 JSON 畸形才响亮失败——避免 daemon 新增交互类型直接砸掉审批 UI。
 */

import { parseJson, requiredString, optionalString, optionalNumber, optionalArray,
  requiredArray, isBoolean } from './Json';

export class InteractionBodyKind {
  static readonly ASK: string = 'ask';
  static readonly PLAN: string = 'plan';
  static readonly PERMISSION: string = 'permission';
}

export class AskModeWire {
  static readonly SINGLE: string = 'single';
  static readonly BATCH: string = 'batch';
}

/** 单个 ask 问题（qaqh-domain AskQuestion）。 */
export class AskQuestionBody {
  readonly id: string;
  readonly question: string;
  readonly options: string[];
  readonly allowCustom: boolean;

  constructor(holder: object) {
    this.id = requiredString(holder, 'id');
    this.question = requiredString(holder, 'question');
    this.options = [];
    const rawOptions: Object[] | undefined = optionalArray(holder, 'options');
    if (rawOptions !== undefined) {
      for (const option of rawOptions) {
        this.options.push(`${option}`);
      }
    }
    const allowCustom: Object | undefined = (holder as Record<string, Object>)['allow_custom'];
    this.allowCustom = isBoolean(allowCustom) ? allowCustom as boolean : true;
  }
}

/** `kind = "ask"` 正文。 */
export class AskBody {
  readonly mode: string;
  readonly questions: AskQuestionBody[];

  constructor(holder: object) {
    this.mode = optionalString(holder, 'mode') ?? AskModeWire.SINGLE;
    this.questions = [];
    const rawQuestions: Object[] = requiredArray(holder, 'questions');
    for (const question of rawQuestions) {
      this.questions.push(new AskQuestionBody(question as object));
    }
  }
}

/** `kind = "plan"` 正文（review_type: plan / todo_activation）。 */
export class PlanBody {
  readonly planContent: string;
  readonly reviewType: string;
  readonly todoItems: Object[];

  constructor(holder: object) {
    this.planContent = optionalString(holder, 'plan_content') ?? '';
    this.reviewType = optionalString(holder, 'review_type') ?? 'plan';
    this.todoItems = optionalArray(holder, 'todo_items') ?? [];
  }
}

/** `kind = "permission"` 正文。 */
export class PermissionBody {
  readonly toolName: string;
  readonly actionSummary: string | undefined;
  readonly reason: string;
  readonly paths: string[];
  readonly category: string;
  readonly level: number;
  readonly risk: string;
  readonly consequence: string;

  constructor(holder: object) {
    this.toolName = requiredString(holder, 'tool_name');
    this.actionSummary = optionalString(holder, 'action_summary');
    this.reason = optionalString(holder, 'reason') ?? '';
    this.paths = [];
    const rawPaths: Object[] | undefined = optionalArray(holder, 'paths');
    if (rawPaths !== undefined) {
      for (const path of rawPaths) {
        this.paths.push(`${path}`);
      }
    }
    this.category = optionalString(holder, 'category') ?? '';
    this.level = optionalNumber(holder, 'level') ?? 0;
    this.risk = optionalString(holder, 'risk') ?? '';
    this.consequence = optionalString(holder, 'consequence') ?? '';
  }
}

export class InteractionBody {
  readonly kind: string;
  ask: AskBody | undefined;
  plan: PlanBody | undefined;
  permission: PermissionBody | undefined;
  readonly raw: object;

  private constructor(kind: string, holder: object) {
    this.kind = kind;
    this.raw = holder;
    this.ask = undefined;
    this.plan = undefined;
    this.permission = undefined;
  }

  static parse(text: string): InteractionBody {
    const holder: object = parseJson(text);
    const kind: string = optionalString(holder, 'kind') ?? '';
    const body: InteractionBody = new InteractionBody(kind, holder);
    if (kind === InteractionBodyKind.ASK) {
      body.ask = new AskBody(holder);
    } else if (kind === InteractionBodyKind.PLAN) {
      body.plan = new PlanBody(holder);
    } else if (kind === InteractionBodyKind.PERMISSION) {
      body.permission = new PermissionBody(holder);
    }
    // 未知 kind：保留 raw，由 UI 降级展示（展示面容忍策略）。
    return body;
  }
}
