/**
 * Config/Profile 服务面契约测试（BYOK 六字段）。
 *
 * 夹具取自 qaqh-backend `qaqh-config-api/src/lib.rs::dto_parses_the_full_wire_shape`，
 * 保证鸿蒙端与 daemon 逐字段对拍。核心契约：camelCase、缺字段即解析失败
 * （不做向前兼容）、Merge Patch 只发要改的字段、值域校验与后端同域。
 */

import { describe, it, expect } from '@ohos/hypium';

import { ProtocolError } from '../main/ets/wire/Json';
import { RingingConfigDto, RingingConfigPatch, ConfigWire } from '../main/ets/wire/Config';

/** 完整 wire 形状（与后端 qaqh-config-api 测试夹具逐键一致）。 */
const CONFIG_DTO_WIRE: string = '{"model":"ox-alpha-free",' +
  '"baseUrl":"https://opencode.ai/zen/go/v1",' +
  '"wire":"openai",' +
  '"maxTokens":96000,' +
  '"contextLength":1000000,' +
  '"reasoningEffort":"max",' +
  '"autoCompactThreshold":0.95,' +
  '"permissionLevel":2,' +
  '"apiKey":"****",' +
  '"lang":null,' +
  '"fontFamily":"",' +
  '"theme":null,' +
  '"notificationsEnabled":true,' +
  '"activeProfile":"default",' +
  '"profiles":["default"],' +
  '"complianceEnabled":false,' +
  '"subagent":{"model":"","baseUrl":"","apiKey":"","apiKeySet":false,' +
  '"maxTokens":4096,"timeoutSecs":120,"defaultTools":["read"],' +
  '"maxDepth":1,"messageInFlightPerPair":16,"messageOutboundPerSender":1024},' +
  '"mcp":{"enabled":false,"idleShutdownSecs":300,"servers":[]},' +
  '"lsp":{"enabled":false,"idleShutdownSecs":600,"servers":[]},' +
  '"tokenizerPath":null}';

/** 旧形状（providerId / providers 目录 / contextLimit）不再存在于 wire 上。 */
const LEGACY_PROVIDER_KEYS: string = '{"providerId":"deepseek","endpoint":"openai",' +
  '"contextLimit":128000,"providers":[{"id":"openai","baseUrl":"https://api.openai.com"}]}';

function expectProtocolError(code: string, action: () => void): void {
  let caught: string = '';
  try {
    action();
  } catch (error) {
    if (error instanceof ProtocolError) {
      caught = error.code;
    } else {
      caught = `unexpected error type: ${(error as Error).message}`;
    }
  }
  expect(caught).assertEqual(code);
}

export default function configContractTest() {
  describe('config_contract', () => {
    it('config_wire_values_are_frozen', 0, () => {
      expect(ConfigWire.OPENAI).assertEqual('openai');
      expect(ConfigWire.RESPONSES).assertEqual('responses');
      expect(ConfigWire.ANTHROPIC).assertEqual('anthropic');
      expect(ConfigWire.isValid('openai')).assertTrue();
      expect(ConfigWire.isValid('anthropic')).assertTrue();
      expect(ConfigWire.isValid('openai-compatible')).assertFalse();
      expect(ConfigWire.isValid('grpc')).assertFalse();
    });

    it('config_dto_parses_full_wire_shape', 0, () => {
      const dto: RingingConfigDto = RingingConfigDto.parse(CONFIG_DTO_WIRE);
      expect(dto.model).assertEqual('ox-alpha-free');
      expect(dto.baseUrl).assertEqual('https://opencode.ai/zen/go/v1');
      expect(dto.wire).assertEqual('openai');
      expect(dto.maxTokens).assertEqual(96000);
      expect(dto.contextLength).assertEqual(1000000);
      expect(dto.reasoningEffort).assertEqual('max');
      expect(dto.autoCompactThreshold).assertEqual(0.95);
      expect(dto.permissionLevel).assertEqual(2);
      // 掩码语义：已配置 = "****"，密钥本体永不出 daemon。
      expect(dto.apiKey).assertEqual('****');
      // lang/theme/tokenizerPath 为 null → undefined（= 跟随系统/未设置）。
      expect(dto.lang).assertUndefined();
      expect(dto.theme).assertUndefined();
      expect(dto.tokenizerPath).assertUndefined();
      expect(dto.fontFamily).assertEqual('');
      expect(dto.notificationsEnabled).assertTrue();
      expect(dto.activeProfile).assertEqual('default');
      expect(dto.profiles.length).assertEqual(1);
      expect(dto.profiles[0]).assertEqual('default');
      expect(dto.complianceEnabled).assertFalse();
      expect(dto.subagent.timeoutSecs).assertEqual(120);
      expect(dto.subagent.defaultTools.length).assertEqual(1);
      expect(dto.subagent.defaultTools[0]).assertEqual('read');
      expect(dto.wireKnown()).assertTrue();
    });

    it('config_dto_missing_required_field_fails_loud', 0, () => {
      // BYOK 后 `wire` 必填——后端读侧缺字段即解析失败，鸿蒙侧同域。
      const missingWire: string = CONFIG_DTO_WIRE.replace('"wire":"openai",', '');
      expectProtocolError('missing_field', () => RingingConfigDto.parse(missingWire));
      const missingContext: string = CONFIG_DTO_WIRE.replace('"contextLength":1000000,', '');
      expectProtocolError('missing_field', () => RingingConfigDto.parse(missingContext));
      const missingMcp: string = CONFIG_DTO_WIRE.replace(/"mcp":\{[^}]*\},/, '');
      expectProtocolError('missing_field', () => RingingConfigDto.parse(missingMcp));
    });

    it('config_dto_rejects_legacy_provider_shape', 0, () => {
      // 旧键（providerId/endpoint 预设坐标/contextLimit/providers 目录）已删：
      // 按新契约解析必须响亮失败（缺 wire/baseUrl/contextLength），而不是
      // 静默产出一份全空配置。
      expectProtocolError('missing_field', () => RingingConfigDto.parse(LEGACY_PROVIDER_KEYS));
    });

    it('config_patch_serializes_only_set_fields', 0, () => {
      const patch: RingingConfigPatch = new RingingConfigPatch();
      expect(JSON.stringify(patch.toWire())).assertEqual('{}');
      const byok: RingingConfigPatch = new RingingConfigPatch();
      byok.baseUrl = 'https://api.deepseek.com';
      byok.wire = 'openai';
      byok.model = 'deepseek-chat';
      byok.contextLength = 128000;
      const wire: Record<string, Object> = byok.toWire();
      // toWire 按声明顺序（apiKey→model→baseUrl→wire→…）序列化。
      expect(JSON.stringify(wire)).assertEqual(
        '{"model":"deepseek-chat","baseUrl":"https://api.deepseek.com",' +
        '"wire":"openai","contextLength":128000}');
      // 未赋值字段不得出现（缺失 = 后端 Merge Patch 语义的不动）。
      expect(wire['apiKey']).assertUndefined();
      expect(wire['maxTokens']).assertUndefined();
    });

    it('config_patch_validate_mirrors_backend_value_domains', 0, () => {
      const badWire: RingingConfigPatch = new RingingConfigPatch();
      badWire.wire = 'grpc';
      expect(badWire.validate() !== '').assertTrue();
      const badEffort: RingingConfigPatch = new RingingConfigPatch();
      badEffort.reasoningEffort = 'ultra';
      expect(badEffort.validate() !== '').assertTrue();
      const zeroMaxTokens: RingingConfigPatch = new RingingConfigPatch();
      zeroMaxTokens.maxTokens = 0;
      expect(zeroMaxTokens.validate() !== '').assertTrue();
      const zeroContext: RingingConfigPatch = new RingingConfigPatch();
      zeroContext.contextLength = 0;
      expect(zeroContext.validate() !== '').assertTrue();
      const badThreshold: RingingConfigPatch = new RingingConfigPatch();
      badThreshold.autoCompactThreshold = 1.5;
      expect(badThreshold.validate() !== '').assertTrue();
      // 0.0 = 关闭自动压缩，合法（后端真机回归：开区间曾误杀禁用流）。
      const disabledThreshold: RingingConfigPatch = new RingingConfigPatch();
      disabledThreshold.autoCompactThreshold = 0.0;
      expect(disabledThreshold.validate()).assertEqual('');
      const badLevel: RingingConfigPatch = new RingingConfigPatch();
      badLevel.permissionLevel = 4;
      expect(badLevel.validate() !== '').assertTrue();
      const okLevel: RingingConfigPatch = new RingingConfigPatch();
      okLevel.permissionLevel = 3;
      expect(okLevel.validate()).assertEqual('');
      // apiKey 掩码语义：占位值是合法载荷（后端解释为"保持现值"）。
      const maskedKey: RingingConfigPatch = new RingingConfigPatch();
      maskedKey.apiKey = '****';
      expect(maskedKey.validate()).assertEqual('');
      expect(JSON.stringify(maskedKey.toWire())).assertEqual('{"apiKey":"****"}');
      const good: RingingConfigPatch = new RingingConfigPatch();
      good.autoCompactThreshold = 0.95;
      good.reasoningEffort = 'max';
      good.maxTokens = 96000;
      expect(good.validate()).assertEqual('');
    });
  });
}
