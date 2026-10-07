/**
 * 主题单源（M8.1 视觉打磨）：颜色/圆角/字号尽量走 HarmonyOS 系统资源
 * （`sys.color.ohos_id_*` / `sys.float.*`），深色模式自动适配；
 * 只有「工具状态」这类业务语义色保留自定义（系统 token 没有成功/进行档）。
 *
 * 依据本机 SDK（API 26 CLT）sysResource 表核对过的 token：
 * text_primary/secondary/tertiary、background/sub_background、card_bg、
 * list_separator、emphasize、warning/alert、button_normal、corner_radius_*、
 * text_size_body1/2/3/caption、symbol 图标 4042 枚。
 */

import { CodeHighlight, MarkdownController } from '@luvi/lv-markdown-in';
import { pasteboard } from '@kit.BasicServicesKit';
import { curves, promptAction } from '@kit.ArkUI';

/**
 * 语义色板：状态三档（进行/成功/失败）+ 中性色。
 * 底色用「同色 8% alpha 叠加」而非固定浅色 hex：浅色下与原色板观感一致，
 * 深色模式自动变成同色系暗底（固定浅底在深色页面上会发亮刺眼，M14 走查项）。
 */
export class QaqhTone {
  static readonly RUNNING: string = '#C77700';
  static readonly OK: string = '#4E9A51';
  static readonly BAD: string = '#D4574E';
  static readonly OTHER: string = '#6B7A8C';
  static readonly RUNNING_BG: string = '#14C77700';
  static readonly OK_BG: string = '#144E9A51';
  static readonly BAD_BG: string = '#14D4574E';
}

/** 工具卡 tone → 前景/背景查表（视图侧统一入口）。 */
export function toneColor(tone: string): ResourceColor {
  if (tone === 'running') {
    return QaqhTone.RUNNING;
  }
  if (tone === 'ok') {
    return QaqhTone.OK;
  }
  if (tone === 'bad') {
    return QaqhTone.BAD;
  }
  return QaqhTone.OTHER;
}

export function toneBackground(tone: string): ResourceColor {
  if (tone === 'running') {
    return QaqhTone.RUNNING_BG;
  }
  if (tone === 'ok') {
    return QaqhTone.OK_BG;
  }
  if (tone === 'bad') {
    return QaqhTone.BAD_BG;
  }
  return $r('sys.color.ohos_id_color_list_card_bg');
}

export function toneLabel(tone: string): string {
  if (tone === 'running') {
    return '运行中';
  }
  if (tone === 'ok') {
    return '完成';
  }
  if (tone === 'bad') {
    return '失败';
  }
  return '终态';
}

/**
 * 全局共享的 Markdown 控制器：把 lv-markdown-in 的默认高饱和主题
 * 压回鸿蒙系统色（行内代码不再是红底块），并开启懒渲染/代码块自动折叠
 * （长会话流式下的 CPU/内存护栏）。
 */
export function qaqhMarkdown(): MarkdownController {
  return QaqhMarkdown.instance;
}

class QaqhMarkdown {
  static readonly instance: MarkdownController = QaqhMarkdown.create();

  private static create(): MarkdownController {
    const controller: MarkdownController = new MarkdownController();
    // 个别 setter 返回 void，链式调用会断——统一逐条设置。
    controller.setTextColor($r('sys.color.ohos_id_color_text_primary'));
    controller.setTextSize(15);
    controller.setTextLineHeight(24);
    controller.setBlockSpacing(10);
    controller.setTitleColor($r('sys.color.ohos_id_color_text_primary'));
    controller.setInlineCodeColor($r('sys.color.ohos_id_color_text_primary'));
    controller.setInlineCodeBackgroundColor($r('sys.color.ohos_id_color_list_card_bg'));
    controller.setInlineCodeBackgroundRadius(6);
    controller.setHyperlinkTextColor($r('sys.color.ohos_id_color_text_hyperlink'));
    controller.setQuoteTextColor($r('sys.color.ohos_id_color_text_secondary'));
    controller.setQuoteBorderColor($r('sys.color.ohos_id_color_list_separator'));
    controller.setQuoteBackgroundColor($r('sys.color.ohos_id_color_sub_background'));
    controller.setTableOuterBorderColor($r('sys.color.ohos_id_color_list_separator'));
    controller.setTableInnerBorderColor($r('sys.color.ohos_id_color_list_separator'));
    controller.setTableTitleTextColor($r('sys.color.ohos_id_color_text_primary'));
    controller.setTableNormalTextColor($r('sys.color.ohos_id_color_text_primary'));
    controller.setTableBorderRadius(10);
    controller.setCodeBlockTheme('light');
    controller.setCodeBlockBorderRadius(12);
    controller.setCodeBlockAutoCollapseEnable(true);
    controller.setCodeBlockAutoCollapseThreshold(12);
    // 代码块操作区（3.4.6+）：自带复制按钮，复制文案经本监听落系统剪贴板
    // + 轻反馈（M14，清 M8 挂账的「代码块复制」）。
    controller.setCodeBlockActionAreaVisible(true);
    controller.setCodeCopyListener((text: string) => {
      QaqhMarkdown.copyToClipboard(text);
    });
    controller.setLazyRender(true);
    controller.setLazyPreloadBlockCount(4);
    controller.setCodeHighlight(QaqhMarkdown.highlight());
    return controller;
  }

  /** 剪贴板 + 轻反馈：Markdown 控制器无 UIContext，用全局 promptAction。 */
  private static copyToClipboard(text: string): void {
    const data: pasteboard.PasteData =
      pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({ message: '代码已复制', duration: 1500 });
    }).catch(() => {
      // 剪贴板写入失败不打扰（长按选中复制仍可用）。
    });
  }

  /** 低饱和代码高亮（One Light 系）：语义分色但不抢正文。 */
  private static highlight(): CodeHighlight {
    const colors: CodeHighlight = new CodeHighlight();
    colors.keyword = '#9C2F8F';
    colors.method = '#5B62C5';
    colors.type = '#A35A1F';
    colors.modifier = '#9C2F8F';
    colors.constant = '#1F6FC4';
    colors.variable = '#3E4551';
    colors.operator = '#6B7A8C';
    colors.punctuation = '#5B6270';
    colors.brace = '#5B6270';
    colors.bigBrace = '#5B6270';
    colors.string = '#0B7285';
    colors.number = '#1F6FC4';
    colors.boolean = '#C77700';
    colors.nullish = '#8A93A0';
    colors.promise = '#5B62C5';
    colors.tag = '#5B62C5';
    colors.attrName = '#A35A1F';
    colors.attrValue = '#0B7285';
    colors.doctype = '#8A93A0';
    colors.comment = '#9AA3AE';
    colors.decorator = '#C77700';
    colors.component = '#5B62C5';
    colors.normal = '#3E4551';
    return colors;
  }
}

/**
 * 统一的弹簧曲线（HarmonyOS 运动规范口径：主交互用 springMotion，
 * response 0.3~0.4 之间最贴系统观感；短位移 150-250ms）。
 */
export function qaqhSpring(): curves.ICurve {
  return curves.springMotion(0.32, 0.72, 0.86);
}

export const QAQH_PRESS_MS: number = 120;
export const QAQH_EXPAND_MS: number = 220;
export const QAQH_ITEM_ENTER_MS: number = 180;

/**
 * 等宽字体族单源（M13）：内嵌 Cascadia Mono Regular（SIL OFL 1.1，许可随
 * 字体打包在 rawfile/fonts/，EntryAbility 启动时经 UIContext.Font 注册）。
 * 中文字形不在覆盖范围，缺字按 glyph 自动回落系统字体；注册失败时该族名
 * 落回默认字体（hilog 有账），各消费点不单独判。
 */
export const MONO_FAMILY: string = 'CascadiaMono';
