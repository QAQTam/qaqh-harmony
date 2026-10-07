/**
 * 移动端 M0 设备接入契约测试：PairingClient（配对换设备凭证）、
 * RingingClient.attachSession（归属命令）、SessionMonitor 设备身份下
 * 「open → attach → bootstrap → 订阅」的顺序。
 *
 * 全部夹具形态取自 scripts/wire-smoke.sh 对真 daemon 的实测响应
 * （pairing.rs / v2.rs / command.rs），不是凭想象写的假件。
 */

import { describe, it, expect } from '@ohos/hypium';

import { CanonicalCursor, CursorToken, PairQrPayload, ProjectionPayload, ProtocolError,
  RingingV2Bootstrap,
  RingingV2EventEnvelope, RingingV2ResetRequired } from '@qaqh/protocol';
import { PairingClient, PairingError } from '../main/ets/PairingClient';
import { RingingClient, RingingClientConfig } from '../main/ets/RingingClient';
import { SessionMonitor, SessionMonitorListener, CursorStore }
  from '../main/ets/SessionMonitor';
import { LeaseTimer, Transport, TransportRequest, TransportResponse }
  from '../main/ets/transport/Transport';
import { StreamConnection, StreamListener, StreamRequest }
  from '../main/ets/transport/StreamConnection';

const OPEN_OK: string = '{"schema":"qaqh.Ringing","version":2,"accepted":true,' +
  '"client_session_id":"cs-1","server_epoch":"epoch-1","lease_ttl_ms":30000,' +
  '"renew_interval_ms":10000,"capabilities":{"subscribe":true,"interact":true,' +
  '"drive":true,"timeline":true,"service":true,"content":true,"single_stream":true,' +
  '"pairing":true}}';

const PAIR_TOKEN_OK: string = '{"pairing_token":"01M47AXG000000000000000000' +
  '01M47AXG000000000000000001","expires_in_ms":120000,' +
  '"tls_fp":"sha256:5ec75e5ff53bc0b51599ea1e0241f79b944513ea027a0d0f7a0b639d06b54ed5"}';

const PAIR_OK: string = '{"device_id":"01M47AXHRDEXAR6MSWE4291W6G",' +
  '"device_token":"dt-secret-looks-like-this","scope":"interact",' +
  '"daemon_version":"2.0.0-beta.2","protocol_version":2}';

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

/** 脚本化传输：按序回放，并记录请求供断言。ACK 模板支持 %CMDID% 回显。 */
class RecordingTransport implements Transport {
  readonly requests: TransportRequest[] = [];
  private readonly statuses: number[] = [];
  private readonly bodies: string[] = [];
  private index: number = 0;

  enqueue(status: number, body: string): RecordingTransport {
    this.statuses.push(status);
    this.bodies.push(body);
    return this;
  }

  send(request: TransportRequest): Promise<TransportResponse> {
    this.requests.push(request);
    if (this.index >= this.statuses.length) {
      return Promise.reject(new Error('script exhausted'));
    }
    const status: number = this.statuses[this.index];
    let body: string = this.bodies[this.index];
    this.index++;
    // center/client 每次现生成 command_id，脚本必须回显它（assertAckMatches 会核对）。
    const match: RegExpMatchArray | null = request.body.match(/"command_id":"([^"]+)"/);
    if (match !== null) {
      body = body.split('%CMDID%').join(match[1]);
    }
    return Promise.resolve(new TransportResponse(status, body));
  }

  lastRequest(): TransportRequest {
    return this.requests[this.requests.length - 1];
  }

  count(): number {
    return this.requests.length;
  }

  urls(): string[] {
    const out: string[] = [];
    for (const request of this.requests) {
      out.push(`${request.method} ${request.url}`);
    }
    return out;
  }
}

class SilentStreamConnection implements StreamConnection {
  connect(request: StreamRequest, listener: StreamListener): void {
    void request;
    void listener;
  }

  cancel(): void {
  }
}

class NoopTimer implements LeaseTimer {
  start(intervalMs: number, fire: () => void): void {
    void intervalMs;
    void fire;
  }

  stop(): void {
  }
}

class NoopMonitorListener implements SessionMonitorListener {
  onBootstrap(snapshot: RingingV2Bootstrap): void {
    void snapshot;
  }

  onEnvelope(envelope: RingingV2EventEnvelope, payload: ProjectionPayload): void {
    void envelope;
    void payload;
  }

  onResetRequired(reset: RingingV2ResetRequired): void {
    void reset;
  }

  onStatusChanged(status: string): void {
    void status;
  }

  onProtocolError(error: ProtocolError): void {
    void error;
  }
}

async function settle(): Promise<void> {
  for (let i = 0; i < 12; i++) {
    await Promise.resolve();
  }
}

export default function deviceAccessContractTest() {
  describe('device_access_contract', () => {
    it('pairing_token_request_carries_admin_bearer', 0, async () => {
      const transport: RecordingTransport =
        new RecordingTransport().enqueue(200, PAIR_TOKEN_OK);
      const client: PairingClient = new PairingClient(transport, 'https://daemon.test');

      const issued = await client.issuePairingToken('admin-11', 'harmony-phone');

      expect(issued.pairingToken.length).assertEqual(52);
      expect(issued.expiresInMs).assertEqual(120000);
      expect(issued.tlsFingerprint.startsWith('sha256:')).assertTrue();
      const request = transport.lastRequest();
      expect(request.url).assertEqual('https://daemon.test/ringing/v2/pairing/tokens');
      expect(request.headers['Authorization']).assertEqual('Bearer admin-11');
      expect(request.body.includes('"scope_grant":"interact"')).assertTrue();
      expect(request.body.includes('"device_name":"harmony-phone"')).assertTrue();
      expect(request.body.includes('"platform":"harmony"')).assertTrue();
    });

    it('pair_endpoint_is_public_and_exchanges_token', 0, async () => {
      const transport: RecordingTransport =
        new RecordingTransport().enqueue(200, PAIR_OK);
      const client: PairingClient = new PairingClient(transport, 'https://daemon.test');

      const paired = await client.pair('01M47AXG00000000000000000001M47AXG000000000000000001',
        'harmony-phone');

      expect(paired.deviceId).assertEqual('01M47AXHRDEXAR6MSWE4291W6G');
      expect(paired.deviceToken).assertEqual('dt-secret-looks-like-this');
      expect(paired.scope).assertEqual('interact');
      expect(paired.protocolVersion).assertEqual(2);
      const request = transport.lastRequest();
      expect(request.url).assertEqual('https://daemon.test/ringing/v2/pair');
      // /pair 免 Bearer：带上 Admin 头反而说明配对成了特权自举。
      const auth: string | undefined = request.headers['Authorization'];
      expect(auth === undefined).assertTrue();
      expect(request.body.includes('"pairing_token":"01M47AXG')).assertTrue();
    });

    it('pair_replay_surfaces_daemon_code', 0, async () => {
      const transport: RecordingTransport = new RecordingTransport()
        .enqueue(403, '{"code":"pairing_used","message":"pairing token rejected"}');
      const client: PairingClient = new PairingClient(transport, 'https://daemon.test');

      let code: string = '';
      let status: number = 0;
      try {
        await client.pair('used-token', 'harmony-phone');
      } catch (error) {
        code = (error as PairingError).code;
        status = (error as PairingError).status;
      }
      expect(code).assertEqual('pairing_used');
      expect(status).assertEqual(403);
    });

    it('pair_with_admin_token_chains_two_requests', 0, async () => {
      const transport: RecordingTransport = new RecordingTransport()
        .enqueue(200, PAIR_TOKEN_OK).enqueue(200, PAIR_OK);
      const client: PairingClient = new PairingClient(transport, 'https://daemon.test');

      const paired = await client.pairWithAdminToken('admin-11', 'harmony-phone');

      expect(paired.deviceId).assertEqual('01M47AXHRDEXAR6MSWE4291W6G');
      expect(transport.count()).assertEqual(2);
      // 兑换请求必须复用签发下来的那个 pairing_token。
      const issuedToken: string =
        (JSON.parse(PAIR_TOKEN_OK) as Record<string, Object>)['pairing_token'] as string;
      expect(transport.requests[1].body.includes(issuedToken)).assertTrue();
    });

    it('pair_with_qr_uses_desktop_base_url_and_token', 0, async () => {
      // 桌面端 QR payload（spec §11 第 2 步）：自带 base_url + 一次性票。
      const qr: PairQrPayload = PairQrPayload.parse(
        '{"v":1,"kind":"qaqh-pair","base_url":"https://10.0.0.2:64413",' +
        '"pairing_token":"one-time-tkt","tls_fp":"sha256:aa11","host_name":"work-pc"}');
      expect(qr.baseUrl).assertEqual('https://10.0.0.2:64413');
      expect(qr.hostName).assertEqual('work-pc');
      const transport: RecordingTransport = new RecordingTransport()
        .enqueue(200, PAIR_OK);

      const paired = await PairingClient.pairWithQr(transport, qr, 'harmony-phone');

      expect(paired.deviceToken).assertEqual('dt-secret-looks-like-this');
      // 直飞 payload 自带的 daemon 地址，不是构造时给的默认地址。
      expect(transport.lastRequest().url)
        .assertEqual('https://10.0.0.2:64413/ringing/v2/pair');
      expect(transport.lastRequest().body.includes('"pairing_token":"one-time-tkt"'))
        .assertTrue();
      // /pair 免 Bearer；scope 由桌面端 grant 决定，本端不带 scope_grant。
      const auth: string | undefined = transport.lastRequest().headers['Authorization'];
      expect(auth === undefined).assertTrue();
      expect(transport.lastRequest().body.includes('scope_grant')).assertFalse();
    });

    it('pair_qr_rejects_foreign_code_and_missing_token', 0, () => {
      // 扫到别的二维码不能误当配对票：kind/v 严格校验。
      let code: string = '';
      try {
        PairQrPayload.parse('{"v":1,"kind":"other-app-pair","base_url":"https://x",' +
          '"pairing_token":"t"}');
      } catch (error) {
        code = (error as ProtocolError).code;
      }
      expect(code).assertEqual('not_pair_qr');
      try {
        PairQrPayload.parse('{"v":1,"kind":"qaqh-pair","base_url":"https://x"}');
      } catch (error) {
        code = (error as ProtocolError).code;
      }
      expect(code).assertEqual('missing_field');
    });

    it('attach_session_posts_control_channel_session_attach', 0, async () => {
      const transport: RecordingTransport = new RecordingTransport()
        .enqueue(200, OPEN_OK)
        .enqueue(200, '{"command_id":"%CMDID%","status":"accepted"}');
      const client: RingingClient = new RingingClient(new RingingClientConfig(
        'https://daemon.test', 'dt-secret', '01M47AXHRDEXAR6MSWE4291W6G',
        transport, new NoopTimer(), true));
      await client.open();

      const ack = await client.attachSession('seed-1');

      expect(ack.status).assertEqual('accepted');
      const request = transport.lastRequest();
      expect(request.url).assertEqual('https://daemon.test/ringing/v2/commands/control');
      // 信封必须顶层 channel 与 command.channel 并存（M0 埋雷）。
      expect(request.body.includes('"channel":"control"')).assertTrue();
      expect(request.body.includes('"type":"session_attach"')).assertTrue();
      expect(request.body.includes('"session_id":"seed-1"')).assertTrue();
      const submitted: string =
        (JSON.parse(request.body) as Record<string, Object>)['command_id'] as string;
      expect(submitted !== null && submitted.length === 26).assertTrue();
    });

    it('device_identity_attaches_before_bootstrap', 0, async () => {
      const transport: RecordingTransport = new RecordingTransport()
        .enqueue(200, OPEN_OK)
        .enqueue(200, '{"command_id":"%CMDID%","status":"accepted"}')
        .enqueue(200, bootstrapFixture());
      const monitor: SessionMonitor = new SessionMonitor(
        new RingingClient(new RingingClientConfig('https://daemon.test', 'dt-secret',
          'device-1', transport, new NoopTimer(), true)),
        new SilentStreamConnection(), new NoopTimer(), new NoopMonitorListener());

      await monitor.start('seed-1');
      await settle();

      // 顺序即契约：attach 早于 bootstrap，否则 daemon 判 forbidden_not_owner。
      expect(transport.urls()[1])
        .assertEqual('POST https://daemon.test/ringing/v2/commands/control');
      expect(transport.urls()[2])
        .assertEqual('GET https://daemon.test/ringing/v2/sessions/seed-1/bootstrap');
    });

    it('admin_identity_skips_attach', 0, async () => {
      const transport: RecordingTransport = new RecordingTransport()
        .enqueue(200, OPEN_OK).enqueue(200, bootstrapFixture());
      const monitor: SessionMonitor = new SessionMonitor(
        new RingingClient(new RingingClientConfig('https://daemon.test', 'admin-11',
          'harmony-admin', transport, new NoopTimer())),
        new SilentStreamConnection(), new NoopTimer(), new NoopMonitorListener());

      await monitor.start('seed-1');
      await settle();

      expect(transport.count()).assertEqual(2);
      expect(transport.urls()[1])
        .assertEqual('GET https://daemon.test/ringing/v2/sessions/seed-1/bootstrap');
    });
  });
}
