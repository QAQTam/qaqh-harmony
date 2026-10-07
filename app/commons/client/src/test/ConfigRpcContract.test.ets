/**
 * Config/Profile 服务面 RPC 契约测试：RingingClient 的 config.load /
 * config.save / profile.apply / config.set_permission_level。
 *
 * 对拍后端 axum_impl::service_api（HTTP 4xx 错误回包 = {code,message}，
 * Read→query_failed / Write→action_failed）与 service_methods 方法表。
 */

import { describe, it, expect } from '@ohos/hypium';

import { ProtocolError, RingingConfigDto, RingingConfigPatch } from '@qaqh/protocol';
import { RingingClient, RingingClientConfig, ServiceRpcError } from '../main/ets/RingingClient';
import { LeaseTimer, Transport, TransportRequest, TransportResponse, TransportError }
  from '../main/ets/transport/Transport';

const OPEN_OK: string = '{"schema":"qaqh.Ringing","version":2,"accepted":true,' +
  '"client_session_id":"cs-1","server_epoch":"epoch-1","lease_ttl_ms":30000,' +
  '"renew_interval_ms":10000,"capabilities":{"subscribe":true,"interact":true,' +
  '"drive":true,"timeline":true,"service":true,"content":true,"single_stream":true}}';

/** 与 protocol ConfigContract 共用的完整 ConfigDto wire 形状。 */
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
  '"maxTokens":4096,"timeoutSecs":120,"defaultTools":[],' +
  '"maxDepth":1,"messageInFlightPerPair":16,"messageOutboundPerSender":1024},' +
  '"mcp":{"enabled":false,"idleShutdownSecs":300,"servers":[]},' +
  '"lsp":{"enabled":false,"idleShutdownSecs":600,"servers":[]},' +
  '"tokenizerPath":null}';

class ScriptedReply {
  readonly failed: boolean;
  readonly status: number;
  readonly body: string;

  constructor(failed: boolean, status: number, body: string) {
    this.failed = failed;
    this.status = status;
    this.body = body;
  }
}

class FakeTransport implements Transport {
  readonly requests: TransportRequest[] = [];
  readonly script: ScriptedReply[] = [];

  enqueue(status: number, body: string): FakeTransport {
    this.script.push(new ScriptedReply(false, status, body));
    return this;
  }

  send(request: TransportRequest): Promise<TransportResponse> {
    this.requests.push(request);
    const next: ScriptedReply | undefined = this.script.shift();
    if (next === undefined) {
      return Promise.reject(new TransportError('script_empty', -1, 'no scripted reply'));
    }
    if (next.failed) {
      return Promise.reject(new TransportError('network_error', -1, 'injected failure'));
    }
    return Promise.resolve(new TransportResponse(next.status, next.body));
  }

  lastRequest(): TransportRequest {
    return this.requests[this.requests.length - 1];
  }

  count(): number {
    return this.requests.length;
  }
}

class FakeTimer implements LeaseTimer {
  lastIntervalMs: number = -1;
  lastFire: (() => void) | undefined;
  stopped: boolean = false;

  start(intervalMs: number, fire: () => void): void {
    this.lastIntervalMs = intervalMs;
    this.lastFire = fire;
    this.stopped = false;
  }

  stop(): void {
    this.stopped = true;
    this.lastFire = undefined;
  }
}

/** 建好 OPEN 状态 client（open 已消费第一条脚本回复）。 */
async function makeClient(transport: FakeTransport): Promise<RingingClient> {
  const client: RingingClient = new RingingClient(new RingingClientConfig(
    'http://daemon.test', 'tok-1', 'instance-1', transport, new FakeTimer()));
  transport.enqueue(200, OPEN_OK);
  await client.open();
  return client;
}

export default function configRpcContractTest() {
  describe('config_rpc_contract', () => {
    it('config_load_posts_empty_body_and_parses_dto', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const client: RingingClient = await makeClient(transport);
      transport.enqueue(200, CONFIG_DTO_WIRE);

      const dto: RingingConfigDto = await client.configLoad();

      const request: TransportRequest = transport.lastRequest();
      expect(request.url).assertEqual('http://daemon.test/ringing/v2/service/config.load');
      expect(request.method).assertEqual('POST');
      expect(request.body).assertEqual('{}');
      expect(dto.baseUrl).assertEqual('https://opencode.ai/zen/go/v1');
      expect(dto.wire).assertEqual('openai');
      expect(dto.contextLength).assertEqual(1000000);
      expect(dto.apiKey).assertEqual('****');
    });

    it('config_save_sends_merge_patch_with_set_fields_only', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const client: RingingClient = await makeClient(transport);
      transport.enqueue(200, 'null');
      const patch: RingingConfigPatch = new RingingConfigPatch();
      patch.baseUrl = 'https://api.deepseek.com';
      patch.wire = 'openai';
      patch.model = 'deepseek-chat';
      patch.contextLength = 128000;

      await client.configSave(patch);

      const request: TransportRequest = transport.lastRequest();
      expect(request.url).assertEqual('http://daemon.test/ringing/v2/service/config.save');
      expect(request.body).assertEqual('{"model":"deepseek-chat",' +
        '"baseUrl":"https://api.deepseek.com","wire":"openai","contextLength":128000}');
    });

    it('config_save_rejects_invalid_patch_before_sending', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const client: RingingClient = await makeClient(transport);
      const patch: RingingConfigPatch = new RingingConfigPatch();
      patch.wire = 'grpc';

      let caught: string = '';
      try {
        await client.configSave(patch);
      } catch (error) {
        if (error instanceof ProtocolError) {
          caught = error.code;
        } else {
          caught = `unexpected error type: ${(error as Error).message}`;
        }
      }
      expect(caught).assertEqual('invalid_patch');
      // 非法补丁不出端：除了 open 没有任何请求发出去。
      expect(transport.count()).assertEqual(1);
    });

    it('service_error_body_maps_to_service_rpc_error', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const client: RingingClient = await makeClient(transport);
      // 后端拒绝写回包的形状：HTTP 400 + {code, message}（如
      // validate 之外的失败——profile 不存在、落盘 IO 错误等）。
      // 这里用本地合法的补丁 + 注入 400，验证错误映射不打折。
      transport.enqueue(400, '{"code":"action_failed",' +
        '"message":"contextLength 必须大于 0"}');
      const patch: RingingConfigPatch = new RingingConfigPatch();
      patch.model = 'deepseek-chat';

      let caughtCode: string = '';
      let caughtMessage: string = '';
      let caughtStatus: number = 0;
      try {
        await client.configSave(patch);
      } catch (error) {
        if (error instanceof ServiceRpcError) {
          caughtCode = error.code;
          caughtMessage = error.message;
          caughtStatus = error.status;
        } else {
          caughtCode = `unexpected error type: ${(error as Error).message}`;
        }
      }
      expect(caughtCode).assertEqual('action_failed');
      expect(caughtMessage.includes('contextLength 必须大于 0')).assertTrue();
      expect(caughtStatus).assertEqual(400);
    });

    it('profile_apply_sends_name_and_maps_rejection', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const client: RingingClient = await makeClient(transport);
      transport.enqueue(200, 'null');

      await client.applyProfile('work');
      expect(transport.lastRequest().url)
        .assertEqual('http://daemon.test/ringing/v2/service/profile.apply');
      expect(transport.lastRequest().body).assertEqual('{"name":"work"}');

      transport.enqueue(400, '{"code":"action_failed","message":"profile \'work\' not found"}');
      let caughtCode: string = '';
      try {
        await client.applyProfile('work');
      } catch (error) {
        if (error instanceof ServiceRpcError) {
          caughtCode = error.code;
        } else {
          caughtCode = `unexpected error type: ${(error as Error).message}`;
        }
      }
      expect(caughtCode).assertEqual('action_failed');
    });

    it('permission_level_validated_locally_and_sent', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const client: RingingClient = await makeClient(transport);
      transport.enqueue(200, '{"permission_level":3}');

      await client.setPermissionLevel(3);
      expect(transport.lastRequest().url)
        .assertEqual('http://daemon.test/ringing/v2/service/config.set_permission_level');
      expect(transport.lastRequest().body).assertEqual('{"level":3}');

      let caught: string = '';
      try {
        await client.setPermissionLevel(4);
      } catch (error) {
        if (error instanceof ProtocolError) {
          caught = error.code;
        } else {
          caught = `unexpected error type: ${(error as Error).message}`;
        }
      }
      expect(caught).assertEqual('invalid_patch');
      // open + 成功的那次；档位 4 被本地拦截未出端。
      expect(transport.count()).assertEqual(2);
    });
  });
}
