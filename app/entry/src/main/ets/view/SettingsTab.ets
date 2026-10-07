/**
 * 设置 tab（M10）：连接 / 模型端点（BYOK 六字段）/ 配置档案 / 设备配对 /
 * 证书信任。字段直写 AppStorage（AppModel 连接时读取），断开/清除凭证
 * 都是就地操作，不再切换整页视图。
 *
 * 形态基元（Card / SectionHeader / PrimaryButton / GhostButton）收口在
 * UiKit：卡片圆角、按钮高度、胶囊圆角不再逐处手写。
 */

import { AppModel, QaqhState } from '../model/AppModel';
import { BUTTON_HEIGHT, Card, GhostButton, INPUT_HEIGHT, PILL_RADIUS,
  PrimaryButton, SectionHeader } from './UiKit';
import { MONO_FAMILY } from '../theme/QaqhTheme';

/** wire 与 effort 的值域（与 @qaqh/protocol 的 ConfigWire / 后端校验同域）。 */
const WIRE_CHOICES: string[] = ['openai', 'responses', 'anthropic'];
const EFFORT_CHOICES: string[] = ['low', 'medium', 'high', 'xhigh', 'max'];

@Component
export struct SettingsTab {
  /** 悬浮胶囊占位（EntryAbility 按真实安全区回灌，默认 88vp）。 */
  @StorageLink(QaqhState.CAP_SPACE) capSpace: number = 88;
  @StorageLink(QaqhState.BASE_URL) baseUrl: string = '';
  @StorageLink(QaqhState.TOKEN) token: string = '';
  @StorageLink(QaqhState.CA_PEM) caCertPem: string = '';
  @StorageLink(QaqhState.SKIP_VERIFY) skipVerify: boolean = false;
  @StorageLink(QaqhState.PAIRED_LABEL) pairedLabel: string = '';
  @StorageLink(QaqhState.PAIRING) pairing: boolean = false;
  @StorageLink(QaqhState.CONNECTED) connected: boolean = false;
  @StorageLink(QaqhState.STATUS) statusText: string = '';
  // 内存探针（MemoryProbe 5s 一拍）
  @StorageLink(QaqhState.PERF_PSS) perfPss: string = '';
  @StorageLink(QaqhState.PERF_NATIVE) perfNative: string = '';
  @StorageLink(QaqhState.PERF_PEAK) perfPeak: string = '';

  // daemon 配置面
  @StorageLink(QaqhState.CFG_MODEL) cfgModel: string = '';
  @StorageLink(QaqhState.CFG_BASE_URL) cfgBaseUrl: string = '';
  @StorageLink(QaqhState.CFG_WIRE) cfgWire: string = '';
  @StorageLink(QaqhState.CFG_MAX_TOKENS) cfgMaxTokens: string = '';
  @StorageLink(QaqhState.CFG_CONTEXT_LENGTH) cfgContextLength: string = '';
  @StorageLink(QaqhState.CFG_EFFORT) cfgEffort: string = '';
  @StorageLink(QaqhState.CFG_API_KEY_LABEL) cfgApiKeyLabel: string = '';
  @StorageLink(QaqhState.CFG_NEW_API_KEY) cfgNewApiKey: string = '';
  @StorageLink(QaqhState.CFG_PROFILES) cfgProfiles: string[] = [];
  @StorageLink(QaqhState.CFG_ACTIVE_PROFILE) cfgActiveProfile: string = '';
  @StorageLink(QaqhState.CFG_SELECTED_PROFILE) cfgSelectedProfile: string = '';
  @StorageLink(QaqhState.CFG_STATUS) cfgStatus: string = '';
  @StorageLink(QaqhState.CFG_LOADED) cfgLoaded: boolean = false;
  @StorageLink(QaqhState.CFG_SAVING) cfgSaving: boolean = false;
  @State newProfileName: string = '';

  private model(): AppModel {
    return AppModel.instance();
  }

  aboutToAppear(): void {
    // 已连接且已加载过就幂等跳过（连接成功时 AppModel 会强制刷一次）。
    this.model().loadDaemonConfig(false);
  }

  private wireOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (const wire of WIRE_CHOICES) {
      const option: SelectOption = { value: wire };
      options.push(option);
    }
    return options;
  }

  private wireIndex(): number {
    const index: number = WIRE_CHOICES.indexOf(this.cfgWire);
    return index >= 0 ? index : 0;
  }

  private effortOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (const effort of EFFORT_CHOICES) {
      const option: SelectOption = { value: effort };
      options.push(option);
    }
    return options;
  }

  private effortIndex(): number {
    const index: number = EFFORT_CHOICES.indexOf(this.cfgEffort);
    return index >= 0 ? index : 0;
  }

  private profileOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (const name of this.cfgProfiles) {
      const option: SelectOption = { value: name };
      options.push(option);
    }
    return options;
  }

  private profileIndex(): number {
    const index: number = this.cfgProfiles.indexOf(this.cfgSelectedProfile);
    return index >= 0 ? index : 0;
  }

  /** 表单输入统一形态：高度 / 圆角 / 底色（卡面之上的浅一层）。 */
  @Builder
  formInput(text: string, placeholder: string, onInput: (value: string) => void) {
    TextInput({ text: text, placeholder: placeholder })
      .height(INPUT_HEIGHT)
      .borderRadius(14)
      .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
      .onChange((value: string) => {
        onInput(value);
      })
      .width('100%')
  }

  /** 下拉行：固定宽标签 + Select。 */
  @Builder
  pickerRow(label: string, options: SelectOption[], selected: number, value: string,
    onPick: (index: number) => void) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
        .width(72)
      Select(options)
        .selected(selected)
        .value(value)
        .onSelect((index: number) => {
          onPick(index);
        })
    }
    .width('100%')
  }

  /** 探针读数行：标签 + 等宽数值右对齐（空值 = 探针未运行/环境不支持）。 */
  @Builder
  perfRow(label: string, value: string) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('sys.color.ohos_id_color_text_secondary'))
      Blank()
      Text(value.length > 0 ? `${value} MB` : '—')
        .fontSize(13)
        .fontFamily(MONO_FAMILY)
        .fontColor($r('sys.color.ohos_id_color_text_primary'))
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Text('设置')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.ohos_id_color_text_primary'))
          .margin({ top: 12, bottom: 2, left: 4 })
          .alignSelf(ItemAlign.Start)

        // 连接
        Card() {
          Column({ space: 10 }) {
            SectionHeader({ title: '连接' })
            this.formInput(this.baseUrl, 'daemon 地址（LAN 为 https://）',
              (value: string) => {
                this.baseUrl = value;
                this.model().refreshPairedLabel();
              })
            TextInput({ text: this.token, placeholder: 'daemon token（配对后可留空）' })
              .height(INPUT_HEIGHT)
              .borderRadius(14)
              .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
              .type(InputType.Password)
              .onChange((value: string) => {
                this.token = value;
              })
              .width('100%')
            Row({ space: 10 }) {
              Button(this.connected ? '重新连接' : '连接')
                .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
                .fontColor(Color.White)
                .fontSize(14)
                .height(BUTTON_HEIGHT)
                .borderRadius(PILL_RADIUS)
                .layoutWeight(1)
                .clickEffect({ level: ClickEffectLevel.LIGHT })
                .onClick(() => {
                  this.model().connect();
                })
              if (this.connected) {
                GhostButton({
                  label: '断开',
                  weight: 1,
                  onAction: (): void => {
                    this.model().disconnect();
                  }
                })
              }
            }
            .width('100%')

            Text(this.statusText)
              .fontSize(12)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .width('100%')
          }
          .width('100%')
        }

        // 模型端点（BYOK 六字段；config.load / config.save）
        Card() {
          Column({ space: 10 }) {
            SectionHeader({ title: '模型端点' })
            if (this.cfgLoaded) {
              this.formInput(this.cfgModel, '模型名（如 deepseek-chat）',
                (value: string) => {
                  this.cfgModel = value;
                })
              this.formInput(this.cfgBaseUrl, '端点 URL（scheme + host + 可选前缀）',
                (value: string) => {
                  this.cfgBaseUrl = value;
                })
              this.pickerRow('wire', this.wireOptions(), this.wireIndex(), this.cfgWire,
                (index: number) => {
                  this.cfgWire = WIRE_CHOICES[index];
                })
              this.pickerRow('推理力度', this.effortOptions(), this.effortIndex(),
                this.cfgEffort, (index: number) => {
                  this.cfgEffort = EFFORT_CHOICES[index];
                })
              this.formInput(this.cfgMaxTokens, '单次回复上限（max tokens）',
                (value: string) => {
                  this.cfgMaxTokens = value;
                })
              this.formInput(this.cfgContextLength, '上下文窗口（本地压缩分母，如 128000）',
                (value: string) => {
                  this.cfgContextLength = value;
                })
              Text(`API 密钥：${this.cfgApiKeyLabel}（密钥本体不出 daemon）`)
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .width('100%')
              TextInput({ text: this.cfgNewApiKey,
                placeholder: '输入新密钥（留空 = 保持现值）' })
                .height(INPUT_HEIGHT)
                .borderRadius(14)
                .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
                .type(InputType.Password)
                .onChange((value: string) => {
                  this.cfgNewApiKey = value;
                })
                .width('100%')
              Row({ space: 10 }) {
                PrimaryButton({
                  label: this.cfgSaving ? '保存中…' : '保存改动',
                  active: !this.cfgSaving,
                  weight: 1,
                  onAction: (): void => {
                    this.model().saveDaemonConfig();
                  }
                })
                GhostButton({
                  label: '重新读取',
                  weight: 1,
                  onAction: (): void => {
                    this.model().loadDaemonConfig(true);
                  }
                })
              }
              .width('100%')
            } else {
              Text('连接 daemon 后读取模型端点配置。')
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
                .width('100%')
              GhostButton({
                label: '读取配置',
                onAction: (): void => {
                  this.model().loadDaemonConfig(true);
                }
              })
            }
            Text(this.cfgStatus)
              .fontSize(12)
              .fontColor($r('sys.color.ohos_id_color_text_secondary'))
              .width('100%')
          }
          .width('100%')
        }

        // 配置档案（profile.apply = 切端点）
        Card() {
          Column({ space: 10 }) {
            SectionHeader({ title: '配置档案' })
            if (this.cfgLoaded) {
              Text(`当前档案：${this.cfgActiveProfile}`)
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(PILL_RADIUS)
                .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
              if (this.cfgProfiles.length > 0) {
                Select(this.profileOptions())
                  .selected(this.profileIndex())
                  .value(this.cfgSelectedProfile)
                  .onSelect((index: number) => {
                    this.cfgSelectedProfile = this.cfgProfiles[index];
                  })
                  .width('100%')
              }
              PrimaryButton({
                label: '应用所选档案（切换端点）',
                onAction: (): void => {
                  this.model().applyDaemonProfile();
                }
              })
              this.formInput(this.newProfileName, '新档案名',
                (value: string) => {
                  this.newProfileName = value;
                })
              GhostButton({
                label: '把当前配置存为该档案',
                onAction: (): void => {
                  this.model().saveDaemonProfile(this.newProfileName);
                }
              })
            } else {
              Text('连接后可查看 / 切换配置档案（切换档案会连同端点一起换）。')
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
                .width('100%')
            }
          }
          .width('100%')
        }

        // 设备配对
        Card() {
          Column({ space: 10 }) {
            SectionHeader({ title: '设备配对' })
            PrimaryButton({
              label: this.pairing ? '配对中…' : '扫码配对',
              active: !this.pairing,
              onAction: (): void => {
                this.model().pairViaScan();
              }
            })
            Text('扫桌面端「设备配对」页生成的二维码（120 秒有效）。' +
              '未导入证书 PEM 时自签端点会校验失败——请先在下方证书信任里导入。')
              .fontSize(12)
              .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
              .width('100%')
            Row({ space: 10 }) {
              GhostButton({
                label: '手动填 Admin token 配对',
                active: !this.pairing,
                weight: 1,
                onAction: (): void => {
                  this.model().pairDevice();
                }
              })
              GhostButton({
                label: '清除本机凭证',
                weight: 1,
                onAction: (): void => {
                  this.model().unpairDevice();
                }
              })
            }
            .width('100%')

            if (this.pairedLabel.length > 0) {
              Text(this.pairedLabel)
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_text_primary_activated'))
                .width('100%')
            }
          }
          .width('100%')
        }

        // 证书信任
        Card() {
          Column({ space: 10 }) {
            SectionHeader({ title: '证书信任' })
            TextArea({ text: this.caCertPem,
              placeholder: '自签证书 PEM（<数据根>/tls/cert.pem）' })
              .height(96)
              .fontSize(11)
              .borderRadius(14)
              .backgroundColor($r('sys.color.ohos_id_color_list_card_bg'))
              .onChange((value: string) => {
                this.caCertPem = value;
              })
              .width('100%')
            Row({ space: 8 }) {
              Text('跳过证书校验（仅调试，会失去 MITM 防护）')
                .fontSize(12)
                .fontColor($r('sys.color.ohos_id_color_warning'))
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.skipVerify })
                .onChange((isOn: boolean) => {
                  this.skipVerify = isOn;
                  this.model().saveTrustSettings();
                })
            }
            .width('100%')
          }
          .width('100%')
        }

        // 内存探针（调试卡）
        Card() {
          Column({ space: 8 }) {
            SectionHeader({ title: '内存探针' })
            this.perfRow('进程 PSS', this.perfPss)
            this.perfRow('Native heap', this.perfNative)
            this.perfRow('峰值 PSS', this.perfPeak)
            Text('hidebug 5s 采样，hilog tag QaqhMem 同步落账（后接 DevEco Profiler）')
              .fontSize(11)
              .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
              .width('100%')
          }
          .width('100%')
        }

        Text('QAQ-Harness · Ringing v2 · M10')
          .fontSize(11)
          .fontColor($r('sys.color.ohos_id_color_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 4 })
      }
      .padding({ left: 16, right: 16, bottom: this.capSpace + 12 })
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .width('100%')
    .height('100%')
  }
}
