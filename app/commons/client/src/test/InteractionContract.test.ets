/**
 * M3 授权闭环契约测试：InteractionCenter（pending 集合 / 三类应答命令 /
 * causation 确认 / ACK 丢失状态回退 / first-answer-wins）。
 * 夹具与后端 command.rs / engine_turn.rs 归因语义对拍。
 */

import { describe, it, expect } from '@ohos/hypium';

import { AskAnswer, CanonicalCursor, CursorToken, ProjectionPayload,
  RingingV2Bootstrap, RingingV2EventEnvelope }
  from '@qaqh/protocol';
import { InteractionCenter, InteractionCenterListener, PendingInteractionView }
  from '../main/ets/InteractionCenter';
import { RingingClient, RingingClientConfig } from '../main/ets/RingingClient';
import { LeaseTimer, Transport, TransportRequest, TransportResponse, TransportError }
  from '../main/ets/transport/Transport';

const OPEN_OK: string = '{"schema":"qaqh.Ringing","version":2,"accepted":true,' +
  '"client_session_id":"cs-1","server_epoch":"epoch-1","lease_ttl_ms":30000,' +
  '"renew_interval_ms":10000,"capabilities":{"subscribe":true,"interact":true,' +
  '"drive":true,"timeline":true,"service":true,"content":true,"single_stream":true}}';

function bootstrapWithPlanInteraction(): string {
  const token: string =
    CursorToken.encodeSnapshot(CanonicalCursor.snapshot('log-1', 42)).asString();
  return '{"schema":"qaqh.Ringing","version":2,"server_epoch":"epoch-1",' +
    '"session_id":"seed-1","snapshot_cursor":"' + token + '",' +
    '"control":{"channel":"control","state_revision":7,"snapshot_version":1,' +
    '"state":{"session_id":"seed-1","revision":7,"last_fact_seq":42,' +
    '"interactions":[{"interaction_id":"i1","call_id":"call_1","turn_id":"t1",' +
    '"kind":"plan","request":{"kind":"ref","data":{"content_ref":"cnt_1"}}}],' +
    '"driver":{"holder":null,"driver_epoch":3,"can_claim":true}}},' +
    '"conversation":{"channel":"conversation","state_revision":19,"snapshot_version":1,' +
    '"state":{"revision":19,"messages":[]}},' +
    '"tool":{"channel":"tool","state_revision":11,"snapshot_version":1,' +
    '"state":{"tools":[]}}}';
}

const REQUESTED_PERMISSION: string = '{"kind":"control_delta","data":' +
  '{"kind":"interaction_requested","data":{"revision":2,"interaction_id":"i2",' +
  '"call_id":"call_2","kind":"permission","request":{"kind":"inline",' +
  '"data":{"text":"run rm -rf /tmp/x"}},"expires_at_ms":null}}}';

function resolvedPayload(interactionId: string): string {
  return '{"kind":"control_delta","data":{"kind":"interaction_resolved","data":' +
    '{"revision":9,"interaction_id":"' + interactionId + '","decision":' +
    '{"kind":"inline","data":{"text":"approved"}},"resolved_by":{"kind":"user"},' +
    '"resolution_seq":1}}}';
}

const EXPIRED: string = '{"kind":"control_delta","data":{"kind":"interaction_expired",' +
  '"data":{"revision":4,"interaction_id":"i1"}}}';

/** ephemeral 信封（无 cursor；causationId 空串则省略字段）。 */
function ephemeralEnvelope(causationId: string, payloadJson: string): RingingV2EventEnvelope {
  let text: string = '{"schema":"qaqh.Ringing","version":2,"server_epoch":"epoch-1",' +
    '"session_id":"seed-1","event_id":"evt-' + Math.floor(Math.random() * 100000) + '",' +
    '"stream_key":{"kind":"channel","data":"control"},"delivery":"ephemeral",';
  if (causationId.length > 0) {
    text += '"causation_id":"' + causationId + '",';
  }
  text += '"payload":' + payloadJson + '}';
  return RingingV2EventEnvelope.parse(text);
}

class ScriptedReply {
  readonly failed: boolean;
  readonly status: number;
  readonly body: string;
  /** true 时回显请求里的 command_id（%CMDID% 占位符）。 */
  readonly echoAck: boolean;

  constructor(failed: boolean, status: number, body: string, echoAck: boolean) {
    this.failed = failed;
    this.status = status;
    this.body = body;
    this.echoAck = echoAck;
  }
}

class FakeTransport implements Transport {
  readonly requests: TransportRequest[] = [];
  readonly script: ScriptedReply[] = [];

  enqueue(status: number, body: string): FakeTransport {
    this.script.push(new ScriptedReply(false, status, body, false));
    return this;
  }

  enqueueAckEcho(): FakeTransport {
    return this.enqueueAckTemplate('{"command_id":"%CMDID%","status":"accepted"}');
  }

  /** ACK 回显 command_id（%CMDID% 占位），status/template 自定。 */
  enqueueAckTemplate(template: string): FakeTransport {
    this.script.push(new ScriptedReply(false, 200, template, true));
    return this;
  }

  enqueueNetworkError(): FakeTransport {
    this.script.push(new ScriptedReply(true, -1, '', false));
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
    let body: string = next.body;
    if (next.echoAck) {
      const match = /"command_id":"([^"]*)"/.exec(request.body);
      body = next.body.split('%CMDID%').join(match !== null ? match[1] : 'unknown');
    }
    return Promise.resolve(new TransportResponse(next.status, body));
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

  fire(): void {
    if (this.lastFire !== undefined) {
      this.lastFire();
    }
  }
}

class RecordingListener implements InteractionCenterListener {
  pendingIds: string[] = [];
  resolvedIds: string[] = [];
  resolvedDetails: string[] = [];
  failures: string[] = [];

  onPendingChanged(pending: PendingInteractionView[]): void {
    this.pendingIds = [];
    for (const view of pending) {
      this.pendingIds.push(view.interactionId);
    }
  }

  onInteractionResolved(interactionId: string, detail: string): void {
    this.resolvedIds.push(interactionId);
    this.resolvedDetails.push(detail);
  }

  onRespondFailed(interactionId: string, detail: string): void {
    this.failures.push(`${interactionId}: ${detail}`);
  }
}

async function settle(): Promise<void> {
  for (let i = 0; i < 10; i++) {
    await Promise.resolve();
  }
}

/** 建好 OPEN 状态 client + 已 ingest bootstrap 的 center。 */
async function makeCenter(transport: FakeTransport,
  listener: RecordingListener): Promise<InteractionCenter> {
  const client: RingingClient = new RingingClient(new RingingClientConfig(
    'http://daemon.test', 'tok-1', 'instance-1', transport, new FakeTimer()));
  const center: InteractionCenter = new InteractionCenter(client, listener);
  center.setSessionId('seed-1');
  transport.enqueue(200, OPEN_OK);
  transport.enqueue(200, bootstrapWithPlanInteraction());
  await client.open();
  const snapshot: RingingV2Bootstrap = await client.bootstrap('seed-1');
  center.ingestBootstrap(snapshot);
  return center;
}

export default function interactionContractTest() {
  describe('interaction_center_contract', () => {
    it('bootstrap_ingests_pending_interactions', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const listener: RecordingListener = new RecordingListener();
      await makeCenter(transport, listener);
      expect(listener.pendingIds.length).assertEqual(1);
      expect(listener.pendingIds[0]).assertEqual('i1');
    });

    it('requested_delta_adds_pending', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const listener: RecordingListener = new RecordingListener();
      const center: InteractionCenter = await makeCenter(transport, listener);

      center.ingestEnvelope(ephemeralEnvelope('', REQUESTED_PERMISSION),
        ProjectionPayload.parse(JSON.parse(REQUESTED_PERMISSION) as object));

      expect(listener.pendingIds.length).assertEqual(2);
      expect(listener.pendingIds.includes('i2')).assertTrue();
      void center;
    });

    it('respond_plan_confirms_by_causation', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const listener: RecordingListener = new RecordingListener();
      const center: InteractionCenter = await makeCenter(transport, listener);
      const view = center.pendingValue()[0];

      transport.enqueueAckEcho();
      await center.respondPlan(view, true, '', false);

      const request: TransportRequest = transport.lastRequest();
      expect(request.url).assertEqual('http://daemon.test/ringing/v2/commands/control');
      expect(request.body.includes('"type":"plan_review_respond"')).assertTrue();
      expect(request.body.includes('"approved":true')).assertTrue();
      // ACK accepted → 进入 awaiting，等 causation 确认。
      expect(listener.resolvedIds.length).assertEqual(0);

      const commandIdMatch = /"command_id":"([^"]*)"/.exec(request.body);
      const commandId: string = commandIdMatch !== null ? commandIdMatch[1] : '';
      center.ingestEnvelope(ephemeralEnvelope(commandId, resolvedPayload('i1')),
        ProjectionPayload.parse(JSON.parse(resolvedPayload('i1')) as object));

      expect(listener.resolvedIds.length).assertEqual(1);
      expect(listener.resolvedIds[0]).assertEqual('i1');
      expect(listener.resolvedDetails[0].includes('confirmed by causation')).assertTrue();
      expect(listener.pendingIds.length).assertEqual(0);
    });

    it('respond_permission_posts_to_tool_channel', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const listener: RecordingListener = new RecordingListener();
      const center: InteractionCenter = await makeCenter(transport, listener);
      center.ingestEnvelope(ephemeralEnvelope('', REQUESTED_PERMISSION),
        ProjectionPayload.parse(JSON.parse(REQUESTED_PERMISSION) as object));
      const view = center.pendingValue()[1];

      transport.enqueueAckEcho();
      await center.respondPermission(view, false, false);

      const request: TransportRequest = transport.lastRequest();
      expect(request.url).assertEqual('http://daemon.test/ringing/v2/commands/tool');
      expect(request.body
        .includes('"type":"tool_permission_respond","tool_call_id":"call_2"')).assertTrue();
      expect(request.body.includes('"approved":false,"trust_folder":false')).assertTrue();
    });

    it('ack_rejected_with_existing_resolves_immediately', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const listener: RecordingListener = new RecordingListener();
      const center: InteractionCenter = await makeCenter(transport, listener);
      const view = center.pendingValue()[0];
      transport.enqueueAckTemplate('{"command_id":"%CMDID%","status":"rejected",' +
        '"code":"interaction_already_resolved","existing":{"source":"command_receipt",' +
        '"state":"succeeded","result":{"kind":"plan_review_resolved",' +
        '"interaction_id":"i1","approved":true}}}');

      await center.respondPlan(view, true, '', false);

      expect(listener.resolvedIds.length).assertEqual(1);
      expect(listener.resolvedDetails[0].includes('already succeeded')).assertTrue();
      expect(listener.pendingIds.length).assertEqual(0);
    });

    it('ack_lost_falls_back_to_status_query', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const listener: RecordingListener = new RecordingListener();
      const center: InteractionCenter = await makeCenter(transport, listener);
      const view = center.pendingValue()[0];

      transport.enqueueNetworkError();
      transport.enqueue(200, '{"command_id":"cmd-y","state":"succeeded",' +
        '"payload_fingerprint":"fp"}');
      await center.respondPlan(view, true, '', false);

      // GET /commands/{command_id}，command_id 与被丢 ACK 的 POST 一致。
      const postBody: string = transport.requests[2].body;
      const match = /"command_id":"([^"]*)"/.exec(postBody);
      const commandId: string = match !== null ? match[1] : '';
      expect(commandId.length > 0).assertTrue();
      expect(transport.lastRequest().url)
        .assertEqual(`http://daemon.test/ringing/v2/commands/${commandId}`);
      expect(listener.resolvedIds.length).assertEqual(1);
      expect(listener.resolvedDetails[0].includes('status query')).assertTrue();
      void center;
    });

    it('external_resolution_removes_pending', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const listener: RecordingListener = new RecordingListener();
      const center: InteractionCenter = await makeCenter(transport, listener);

      center.ingestEnvelope(ephemeralEnvelope('', resolvedPayload('i1')),
        ProjectionPayload.parse(JSON.parse(resolvedPayload('i1')) as object));

      expect(listener.pendingIds.length).assertEqual(0);
      expect(listener.resolvedIds.length).assertEqual(1);
      expect(listener.resolvedDetails[0]).assertEqual('resolved externally');
    });

    it('expired_delta_removes_pending_silently', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const listener: RecordingListener = new RecordingListener();
      const center: InteractionCenter = await makeCenter(transport, listener);

      center.ingestEnvelope(ephemeralEnvelope('', EXPIRED),
        ProjectionPayload.parse(JSON.parse(EXPIRED) as object));

      expect(listener.pendingIds.length).assertEqual(0);
      expect(listener.resolvedIds.length).assertEqual(0);
      expect(listener.failures.length).assertEqual(0);
    });

    it('respond_ask_carries_answers', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const listener: RecordingListener = new RecordingListener();
      const center: InteractionCenter = await makeCenter(transport, listener);
      const view = center.pendingValue()[0];

      transport.enqueueAckEcho();
      await center.respondAsk(view, [new AskAnswer('q1', '方案 A')]);

      const request: TransportRequest = transport.lastRequest();
      expect(request.body.includes('"type":"interaction_ask_respond"')).assertTrue();
      expect(request.body.includes('"answers":[{"question_id":"q1","answer":"方案 A"}]'))
        .assertTrue();
    });
  });

  describe('ask_protocol_errors', () => {
    it('ack_rejected_without_existing_reports_failure', 0, async () => {
      const transport: FakeTransport = new FakeTransport();
      const listener: RecordingListener = new RecordingListener();
      const center: InteractionCenter = await makeCenter(transport, listener);
      const view = center.pendingValue()[0];
      transport.enqueueAckTemplate('{"command_id":"%CMDID%","status":"rejected",' +
        '"code":"not_driver","message":"hold the driver seat first"}');

      await center.respondPlan(view, true, '', false);

      expect(listener.failures.length).assertEqual(1);
      expect(listener.failures[0].includes('not_driver')).assertTrue();
      void center;
    });
  });
}
