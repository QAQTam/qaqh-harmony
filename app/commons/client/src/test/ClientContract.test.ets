/**
 * RingingClient 契约测试（M1）。
 *
 * 传输与定时器全部使用假件：只验证 client 层的请求形态、鉴权 header、
 * 状态机与 lease 策略；HTTP 设备实现（HttpTransport）不做本地单测。
 * 夹具与后端 axum_impl/v2.rs、qaqh-client session.rs 的行为逐条对拍。
 */

import { describe, it, expect } from '@ohos/hypium';

import { ProtocolError, CanonicalCursor, CursorToken, RingingV2CommandEnvelope,
  ControlCommands } from '@qaqh/protocol';
import { RingingClient, RingingClientConfig, RingingClientState,
  LeaseLostReason, MAX_RENEW_FAILURES, RENEW_REQUEST_TIMEOUT_MS } from '../main/ets/RingingClient';
import { Transport, TransportRequest, TransportResponse,
  TransportError, LeaseTimer } from '../main/ets/transport/Transport';

const OPEN_OK: string = '{"schema":"qaqh.Ringing","version":2,"accepted":true,' +
  '"client_session_id":"cs-1","server_epoch":"epoch-1","lease_ttl_ms":30000,' +
  '"renew_interval_ms":10000,"capabilities":{"subscribe":true,"interact":true,' +
  '"drive":true,"timeline":true,"service":true,"content":true,"single_stream":true}}';

const OPEN_REJECTED: string = OPEN_OK.replace('"accepted":true', '"accepted":false');

const OPEN_NO_SINGLE_STREAM: string =
  OPEN_OK.replace('"single_stream":true', '"single_stream":false');

const RENEW_OK: string = '{"ok":true,"lease_ttl_ms":30000,"renew_interval_ms":10000}';

const RENEW_NOT_OK: string = '{"ok":false,"lease_ttl_ms":30000,"renew_interval_ms":10000}';

const ACK_ACCEPTED: string = '{"command_id":"cmd-1","status":"accepted"}';

const ACK_MISMATCH: string = '{"command_id":"cmd-other","status":"accepted"}';

const COMMAND_STATUS: string = '{"command_id":"cmd-1","state":"succeeded",' +
  '"payload_fingerprint":"fp-1","terminal_event_id":"evt-1"}';

function bootstrapFixture(): string {
  const token: string =
    CursorToken.encodeSnapshot(CanonicalCursor.snapshot('log-1', 42)).asString();
  return '{"schema":"qaqh.Ringing","version":2,"server_epoch":"epoch-1",' +
    '"session_id":"seed-1","snapshot_cursor":"' + token + '",' +
    '"control":{"channel":"control","state_revision":7,"snapshot_version":1,' +
    '"state":{"session_id":"seed-1","revision":7,"last_fact_seq":42,' +
    '"interactions":[],"driver":{"holder":null,"driver_epoch":3,"can_claim":true}}},' +
    '"conversation":{"channel":"conversation","state_revision":19,"snapshot_version":1,' +
    '"state":{"revision":19,"messages":[]}},' +
    '"tool":{"channel":"tool","state_revision":11,"snapshot_version":1,' +
    '"state":{"tools":[]}}}';
}

/** 脚本条目：failed=true 时抛 TransportError，否则返回固定响应。 */
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

  enqueueNetworkError(): FakeTransport {
    this.script.push(new ScriptedReply(true, -1, ''));
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

  fire(): void {
    if (this.lastFire !== undefined) {
      this.lastFire();
    }
  }
}

function makeClient(transport: FakeTransport, timer: FakeTimer): RingingClient {
  return new RingingClient(new RingingClientConfig(
    'http://daemon.test', 'tok-1', 'instance-1', transport, timer));
}

async function settle(): Promise<void> {
  for (let i = 0; i < 10; i++) {
    await Promise.resolve();
  }
}

async function expectAsyncError(code: string, action: () => Promise<void>): Promise<void> {
  let caught: string = '';
  try {
    await action();
  } catch (error) {
    if (error instanceof ProtocolError) {
      caught = error.code;
    } else if (error instanceof TransportError) {
      caught = error.code;
    } else {
      caught = `unexpected error type: ${(error as Error).message}`;
    }
  }
  expect(caught).assertEqual(code);
}

export default function clientContractTest() {
  describe('ringing_client_contract', () => {
    it('open_posts_wire_and_adopts_state', 0, async () => {
      const transport: FakeTransport = new FakeTransport().enqueue(200, OPEN_OK);
      const timer: FakeTimer = new FakeTimer();
      const client: RingingClient = makeClient(transport, timer);

      const response = await client.open();

      expect(response.clientSessionId).assertEqual('cs-1');
      expect(client.stateValue()).assertEqual(RingingClientState.OPEN);
      expect(client.sessionHeader()).assertEqual('cs-1');
      expect(client.serverEpochValue()).assertEqual('epoch-1');

      const request: TransportRequest = transport.lastRequest();
      expect(request.method).assertEqual('POST');
      expect(request.url).assertEqual('http://daemon.test/ringing/v2/clients/open');
      expect(request.body).assertEqual(
        '{"schema":"qaqh.Ringing","version":2,"client_instance_id":"instance-1"}');
      expect(request.headers['Authorization']).assertEqual('Bearer tok-1');
      expect(request.headers['X-QAQH-Client-Session-Id']).assertUndefined();

      // 节拍 = max(1000, renew_interval/2)，对齐 qaqh-client session.rs。
      expect(timer.lastIntervalMs).assertEqual(5000);
    });

    it('open_rejects_accepted_false', 0, async () => {
      const transport: FakeTransport = new FakeTransport().enqueue(200, OPEN_REJECTED);
      const client: RingingClient = makeClient(transport, new FakeTimer());
      await expectAsyncError('open_rejected', async () => {
        await client.open();
      });
      expect(client.stateValue()).assertEqual(RingingClientState.IDLE);
    });

    it('open_requires_single_stream_capability', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_NO_SINGLE_STREAM);
      const client: RingingClient = makeClient(transport, new FakeTimer());
      await expectAsyncError('single_stream_required', async () => {
        await client.open();
      });
    });

    it('open_maps_non_2xx_to_transport_error', 0, async () => {
      const transport: FakeTransport = new FakeTransport().enqueue(401, '{"error":"bad token"}');
      const client: RingingClient = makeClient(transport, new FakeTimer());
      let caught: string = '';
      try {
        await client.open();
      } catch (error) {
        if (error instanceof TransportError) {
          caught = `${error.code}/${error.status}`;
        }
      }
      expect(caught).assertEqual('http_status/401');
    });

    it('renew_is_bodyless_and_reschedules', 0, async () => {
      const transport: FakeTransport = new FakeTransport()
        .enqueue(200, OPEN_OK).enqueue(200, RENEW_OK);
      const timer: FakeTimer = new FakeTimer();
      const client: RingingClient = makeClient(transport, timer);
      await client.open();

      timer.fire();
      await settle();

      const request: TransportRequest = transport.lastRequest();
      expect(request.url).assertEqual('http://daemon.test/ringing/v2/leases/renew');
      expect(request.body).assertEqual('');
      expect(request.headers['X-QAQH-Client-Session-Id']).assertEqual('cs-1');
      expect(request.headers['Authorization']).assertEqual('Bearer tok-1');
      // 续期必须自带短读预算：晚到即作废（服务端 TTL 30s），不能沿用大正文
      // 端点的 120s 传输默认（一次挂起就烧穿 TTL → 401 lease_expired）。
      expect(request.timeoutMs).assertEqual(RENEW_REQUEST_TIMEOUT_MS);
      expect(transport.requests[0].timeoutMs).assertEqual(0);
      expect(client.stateValue()).assertEqual(RingingClientState.OPEN);
      expect(timer.lastIntervalMs).assertEqual(5000);
      expect(timer.stopped).assertFalse();
    });

    it('renew_survives_single_failure', 0, async () => {
      const transport: FakeTransport = new FakeTransport()
        .enqueue(200, OPEN_OK).enqueueNetworkError().enqueue(200, RENEW_OK);
      const timer: FakeTimer = new FakeTimer();
      const client: RingingClient = makeClient(transport, timer);
      await client.open();

      timer.fire();
      await settle();
      expect(client.stateValue()).assertEqual(RingingClientState.OPEN);

      timer.fire();
      await settle();
      expect(client.stateValue()).assertEqual(RingingClientState.OPEN);
    });

    it('renew_fails_after_consecutive_failures', 0, async () => {
      const transport: FakeTransport = new FakeTransport().enqueue(200, OPEN_OK);
      transport.enqueueNetworkError();
      transport.enqueueNetworkError();
      transport.enqueueNetworkError();
      const timer: FakeTimer = new FakeTimer();
      let lostReason: string = '';
      const client: RingingClient = makeClient(transport, timer);
      client.onLeaseLost((reason: string) => {
        lostReason = reason;
      });
      await client.open();
      expect(MAX_RENEW_FAILURES).assertEqual(3);

      // 前两次为瞬时失败：2s 快速重试（FakeTimer.fire 不区分延迟），仍 OPEN。
      timer.fire();
      await settle();
      expect(client.stateValue()).assertEqual(RingingClientState.OPEN);

      timer.fire();
      await settle();
      expect(client.stateValue()).assertEqual(RingingClientState.OPEN);

      timer.fire();
      await settle();
      expect(client.stateValue()).assertEqual(RingingClientState.CLOSED);
      expect(lostReason).assertEqual(LeaseLostReason.RENEWAL_FAILURES);
      expect(timer.stopped).assertTrue();
    });

    it('renew_4xx_closes_lease_immediately', 0, async () => {
      // 4xx = 服务端明确拒绝（吊销/过期）：不等阈值，立即判死。
      const transport: FakeTransport = new FakeTransport()
        .enqueue(200, OPEN_OK).enqueue(401, '{"code":"lease_expired"}');
      const timer: FakeTimer = new FakeTimer();
      let lostReason: string = '';
      const client: RingingClient = makeClient(transport, timer);
      client.onLeaseLost((reason: string) => {
        lostReason = reason;
      });
      await client.open();

      timer.fire();
      await settle();

      expect(client.stateValue()).assertEqual(RingingClientState.CLOSED);
      expect(lostReason).assertEqual(LeaseLostReason.REJECTED);
    });

    it('renew_not_ok_closes_lease_immediately', 0, async () => {
      const transport: FakeTransport = new FakeTransport()
        .enqueue(200, OPEN_OK).enqueue(200, RENEW_NOT_OK);
      const timer: FakeTimer = new FakeTimer();
      let lostReason: string = '';
      const client: RingingClient = makeClient(transport, timer);
      client.onLeaseLost((reason: string) => {
        lostReason = reason;
      });
      await client.open();

      timer.fire();
      await settle();

      expect(client.stateValue()).assertEqual(RingingClientState.CLOSED);
      expect(lostReason).assertEqual(LeaseLostReason.REJECTED);
    });

    it('bootstrap_requires_open_state', 0, async () => {
      const client: RingingClient = makeClient(new FakeTransport(), new FakeTimer());
      await expectAsyncError('invalid_state', async () => {
        await client.bootstrap('seed-1');
      });
    });

    it('bootstrap_gets_and_parses_snapshot', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, bootstrapFixture());
      const client: RingingClient = makeClient(transport, new FakeTimer());
      await client.open();

      const bootstrap = await client.bootstrap('seed-1');

      const request: TransportRequest = transport.lastRequest();
      expect(request.method).assertEqual('GET');
      expect(request.url)
        .assertEqual('http://daemon.test/ringing/v2/sessions/seed-1/bootstrap');
      expect(request.headers['X-QAQH-Client-Session-Id']).assertEqual('cs-1');
      expect(bootstrap.logId()).assertEqual('log-1');
      expect(bootstrap.controlState.revision).assertEqual(7);
      expect(bootstrap.controlState.driver!.driverEpoch).assertEqual(3);
    });

    it('send_command_posts_envelope_and_validates_ack', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, ACK_ACCEPTED);
      const client: RingingClient = makeClient(transport, new FakeTimer());
      await client.open();
      const envelope = RingingCommandFixtures.sessionResume();

      const ack = await client.sendCommand(envelope);

      const request: TransportRequest = transport.lastRequest();
      expect(request.method).assertEqual('POST');
      expect(request.url).assertEqual('http://daemon.test/ringing/v2/commands/control');
      expect(request.body.includes('"command_id":"cmd-1"')).assertTrue();
      expect(request.body.includes('"session_id":"seed-1"')).assertTrue();
      expect(request.headers['X-QAQH-Client-Session-Id']).assertEqual('cs-1');
      expect(ack.commandId).assertEqual('cmd-1');
      expect(ack.status).assertEqual('accepted');
    });

    it('send_command_rejects_ack_mismatch', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, ACK_MISMATCH);
      const client: RingingClient = makeClient(transport, new FakeTimer());
      await client.open();
      await expectAsyncError('ack_mismatch', async () => {
        await client.sendCommand(RingingCommandFixtures.sessionResume());
      });
    });

    it('send_command_rejected_ack_passes_through_with_empty_id', 0, async () => {
      // 后端 driver 门禁拒绝（not_driver）的 ACK command_id 为空串——
      // 拒绝态不核对 command_id，原样上抛给调用方决策。
      const transport: FakeTransport = new FakeTransport().enqueue(200, OPEN_OK)
        .enqueue(200, '{"command_id":"","status":"rejected","code":"not_driver",' +
          '"message":"another client holds the driver seat"}');
      const client: RingingClient = makeClient(transport, new FakeTimer());
      await client.open();

      const ack = await client.sendCommand(RingingCommandFixtures.sessionResume());

      expect(ack.status).assertEqual('rejected');
      expect(ack.code).assertEqual('not_driver');
    });

    it('driver_claim_posts_to_dedicated_endpoint_and_parses', 0, async () => {
      const transport: FakeTransport = new FakeTransport().enqueue(200, OPEN_OK)
        .enqueue(200, '{"accepted":true,"holder":"cs-1","driver_epoch":3,' +
          '"reason":"already_holder"}');
      const client: RingingClient = makeClient(transport, new FakeTimer());
      await client.open();

      const claim = await client.driverClaim('seed-1');

      const request: TransportRequest = transport.lastRequest();
      expect(request.method).assertEqual('POST');
      expect(request.url)
        .assertEqual('http://daemon.test/ringing/v2/sessions/seed-1/driver/claim');
      expect(request.headers['X-QAQH-Client-Session-Id']).assertEqual('cs-1');
      expect(claim.accepted).assertTrue();
      expect(claim.driverEpoch).assertEqual(3);
      expect(claim.reason).assertEqual('already_holder');
    });

    it('driver_release_posts_to_dedicated_endpoint', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, '{}');
      const client: RingingClient = makeClient(transport, new FakeTimer());
      await client.open();

      await client.driverRelease('seed-1');

      const request: TransportRequest = transport.lastRequest();
      expect(request.method).assertEqual('POST');
      expect(request.url)
        .assertEqual('http://daemon.test/ringing/v2/sessions/seed-1/driver/release');
    });

    it('command_status_parses_terminal_state', 0, async () => {
      const transport: FakeTransport =
        new FakeTransport().enqueue(200, OPEN_OK).enqueue(200, COMMAND_STATUS);
      const client: RingingClient = makeClient(transport, new FakeTimer());
      await client.open();

      const status = await client.commandStatus('cmd-1');

      const request: TransportRequest = transport.lastRequest();
      expect(request.method).assertEqual('GET');
      expect(request.url)
        .assertEqual('http://daemon.test/ringing/v2/commands/cmd-1');
      expect(status.state).assertEqual('succeeded');
      expect(status.payloadFingerprint).assertEqual('fp-1');
    });

    it('close_stops_timer_and_blocks_requests', 0, async () => {
      const transport: FakeTransport = new FakeTransport().enqueue(200, OPEN_OK);
      const timer: FakeTimer = new FakeTimer();
      const client: RingingClient = makeClient(transport, timer);
      await client.open();

      client.close();

      expect(client.stateValue()).assertEqual(RingingClientState.CLOSED);
      expect(timer.stopped).assertTrue();
      await expectAsyncError('invalid_state', async () => {
        await client.bootstrap('seed-1');
      });
    });

    it('approvals_list_gets_session_scoped_snapshot_and_parses', 0, async () => {
      const transport: FakeTransport = new FakeTransport().enqueue(200, OPEN_OK)
        .enqueue(200, '{"challenges":[{"challenge_id":"' + 'a'.repeat(64) + '",' +
          '"kind":"tool_permission","expires_in":299,"details":{"tool_name":"exec"}}]}');
      const client: RingingClient = makeClient(transport, new FakeTimer());
      await client.open();

      const snapshot = await client.approvalsList('seed-1');

      const request: TransportRequest = transport.lastRequest();
      expect(request.method).assertEqual('GET');
      expect(request.url)
        .assertEqual('http://daemon.test/ringing/v2/sessions/seed-1/approvals');
      expect(request.headers['X-QAQH-Client-Session-Id']).assertEqual('cs-1');
      expect(snapshot.items.length).assertEqual(1);
      expect(snapshot.items[0].kind).assertEqual('tool_permission');
      expect(snapshot.items[0].respondId.length).assertEqual(64);
    });

    it('approvals_respond_posts_challenge_bound_to_session_path', 0, async () => {
      // 串频防线（对拍 challenge.rs consume）：challenge 只在其归属会话的路径上
      // 可消费——URL 里的 session_id 与 body 的 challenge_id 必须同源。
      const transport: FakeTransport = new FakeTransport()
        .enqueue(200, OPEN_OK).enqueue(200, '{}');
      const client: RingingClient = makeClient(transport, new FakeTimer());
      await client.open();

      await client.approvalsRespond('seed-1', 'ch-1', 'approve', undefined);

      const request: TransportRequest = transport.lastRequest();
      expect(request.method).assertEqual('POST');
      expect(request.url).assertEqual(
        'http://daemon.test/ringing/v2/sessions/seed-1/approvals/respond');
      expect(request.body).assertEqual('{"challenge_id":"ch-1","decision":"approve"}');
    });

    it('approvals_respond_rejects_unknown_decision_before_wiring', 0, async () => {
      const transport: FakeTransport = new FakeTransport().enqueue(200, OPEN_OK);
      const client: RingingClient = makeClient(transport, new FakeTimer());
      await client.open();

      await expectAsyncError('invalid_decision', async () => {
        await client.approvalsRespond('seed-1', 'ch-1', 'maybe', undefined);
      });
      // 非法 decision 本地拦截，不出端（最后请求仍是 open）。
      expect(transport.lastRequest().url)
        .assertEqual('http://daemon.test/ringing/v2/clients/open');
    });
  });
}

/**
 * 命令夹具集合。
 */
class RingingCommandFixtures {
  static sessionResume(): RingingV2CommandEnvelope {
    return RingingV2CommandEnvelope.create(
      'cmd-1', 'instance-1', 'cs-1', 'seed-1',
      ControlCommands.sessionResume('seed-1'));
  }
}
