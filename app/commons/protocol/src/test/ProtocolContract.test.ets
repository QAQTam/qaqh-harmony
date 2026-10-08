/**
 * Ringing v2 JSON 契约测试。
 *
 * 夹具取自 qaqh-backend 测试（qaqh-ringing types.rs / cursor.rs /
 * qaqh-client sse_decoder.rs），保证鸿蒙端与 daemon 逐字段对拍。
 */

import { describe, it, expect } from '@ohos/hypium';

import {
  RINGING_V2_BASE_PATH, RINGING_V2_VERSION, END_OF_FACT, openPath, eventsPath
} from '../main/ets/wire/Constants';
import { ProtocolError } from '../main/ets/wire/Json';
import { encodeUtf8 } from '../main/ets/wire/Utf8';
import { CanonicalCursor, CursorToken } from '../main/ets/wire/Cursor';
import { SseDecoder } from '../main/ets/wire/SseDecoder';
import {
  RingingV2OpenRequest, RingingV2OpenResponse, RingingV2EventEnvelope,
  RingingV2ResetRequired, RingingV2StreamTerminated, ContentValueRef,
  ContentValueInline, StreamKeyChannel, RingingV2DriverClaimResponse
} from '../main/ets/wire/WireTypes';
import { RingingV2Bootstrap } from '../main/ets/wire/Bootstrap';
import {
  RingingV2CommandAck, CommandReceiptExisting, InteractionResolvedExisting,
  AskResolvedResult, PermissionResolvedResult
} from '../main/ets/wire/Ack';
import { ProjectionPayload, TimelineInput, TimelineToolResult, TimelineDeltaBlock }
  from '../main/ets/wire/Payload';
import { InteractionBody, AskModeWire } from '../main/ets/wire/InteractionBody';
import { RingingSessionListEntry, pickPreferredSession, visibleSessions,
  SESSION_LIST_WIRE_KEYS, SESSION_LIST_MODELED_KEYS, SESSION_LIST_NEVER_ON_WIRE_KEYS }
  from '../main/ets/wire/SessionList';
import {
  RingingV2CommandEnvelope, RingingCommand, ControlCommands, ConversationCommands,
  ToolCommands, AskAnswer, assertAckMatches, newCommandId
} from '../main/ets/wire/Commands';
import { DeviceScope, RingingV2PairTokenRequest, RingingV2PairTokenResponse,
  RingingV2PairRequest, RingingV2PairResponse, WireErrorBody }
  from '../main/ets/wire/Pairing';

function bytesOf(text: string): Uint8Array {
  const out: Uint8Array = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    out[i] = text.charCodeAt(i) & 0xff;
  }
  return out;
}

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

export default function protocolContractTest() {
  describe('ringing_v2_contract', () => {
    it('constants_match_frozen_wire', 0, () => {
      expect(RINGING_V2_VERSION).assertEqual(2);
      expect(RINGING_V2_BASE_PATH).assertEqual('/ringing/v2');
      expect(openPath()).assertEqual('/ringing/v2/clients/open');
      expect(eventsPath('s1')).assertEqual('/ringing/v2/sessions/s1/events');
      expect(END_OF_FACT).assertEqual(65535);
    });

    it('cursor_known_vector_decodes', 0, () => {
      const token: CursorToken = CursorToken.fromOpaque(
        'v2.eyJsb2dfaWQiOiJsb2ctMSIsImZhY3Rfc2VxIjo0MiwicHJvamVjdGlvbl9pbmRleCI6MX0');
      const cursor: CanonicalCursor = token.decodeReliable();
      expect(cursor.logId).assertEqual('log-1');
      expect(cursor.factSeq).assertEqual(42);
      expect(cursor.projectionIndex).assertEqual(1);
    });

    it('cursor_round_trip_is_canonical', 0, () => {
      const token: CursorToken = CursorToken.encodeReliable(new CanonicalCursor('log-1', 42, 1));
      expect(token.asString().startsWith('v2.')).assertTrue();
      expect(token.asString().includes('=')).assertFalse();
      const decoded: CanonicalCursor = token.decodeReliable();
      expect(decoded.logId).assertEqual('log-1');
      expect(decoded.factSeq).assertEqual(42);
      expect(decoded.projectionIndex).assertEqual(1);
    });

    it('snapshot_cursor_uses_end_of_fact', 0, () => {
      const token: CursorToken =
        CursorToken.encodeSnapshot(CanonicalCursor.snapshot('log-1', 42));
      token.decodeSnapshot();
      expectProtocolError('invalid_cursor', () => token.decodeReliable());
      expectProtocolError('invalid_cursor', () =>
        CursorToken.encodeReliable(CanonicalCursor.snapshot('log-1', 42)));
    });

    it('cursor_rejects_tampering_and_noncanonical', 0, () => {
      const token: CursorToken = CursorToken.encodeReliable(new CanonicalCursor('log-1', 42, 1));
      const tampered: string = 'v2.!' + token.asString().substring(4);
      expectProtocolError('invalid_base64', () => CursorToken.fromOpaque(tampered).decode());
      expectProtocolError('invalid_base64', () =>
        CursorToken.fromOpaque(token.asString() + '=').decode());
      expectProtocolError('invalid_prefix', () => CursorToken.fromOpaque('v1.abc').decode());
      // 乱序 JSON 重编码出来的非规范 token 必须被拒绝
      expectProtocolError('non_canonical', () => CursorToken.fromOpaque(
        'v2.eyJwcm9qZWN0aW9uX2luZGV4IjoxLCJmYWN0X3NlcSI6NDIsImxvZ19pZCI6ImxvZy0xIn0').decode());
    });

    it('cursor_rejects_zero_fact_seq', 0, () => {
      expectProtocolError('invalid_cursor', () =>
        CursorToken.encodeReliable(new CanonicalCursor('log-1', 0, 1)));
    });

    it('cursor_rejects_log_mismatch', 0, () => {
      const token: CursorToken = CursorToken.encodeReliable(new CanonicalCursor('log-1', 42, 1));
      expectProtocolError('log_mismatch', () => token.decodeForLog('log-2'));
    });

    it('sse_parses_id_event_data_frame', 0, () => {
      const decoder: SseDecoder = new SseDecoder();
      decoder.push(bytesOf('id: epoch-1:conversation:7\nevent: turn_started\ndata: {"x":1}\n\n'));
      const frame = decoder.nextFrame();
      expect(frame !== undefined).assertTrue();
      expect(frame!.id).assertEqual('epoch-1:conversation:7');
      expect(frame!.eventType).assertEqual('turn_started');
      expect(frame!.data).assertEqual('{"x":1}');
      expect(decoder.nextFrame() === undefined).assertTrue();
    });

    it('sse_frame_split_across_chunks_is_reassembled', 0, () => {
      const decoder: SseDecoder = new SseDecoder();
      decoder.push(bytesOf('id: e:tool:1\nevent: tool_star'));
      expect(decoder.nextFrame() === undefined).assertTrue();
      decoder.push(bytesOf('ted\ndata: {}\n\n'));
      const frame = decoder.nextFrame();
      expect(frame !== undefined).assertTrue();
      expect(frame!.id).assertEqual('e:tool:1');
      expect(frame!.eventType).assertEqual('tool_started');
      expect(frame!.data).assertEqual('{}');
    });

    it('sse_utf8_char_split_across_chunks_is_not_corrupted', 0, () => {
      const decoder: SseDecoder = new SseDecoder();
      // "中" = E4 B8 AD，切到两个 push。
      decoder.push(bytesOf('data: {"t":"\u00e4\u00b8'));
      expect(decoder.nextFrame() === undefined).assertTrue();
      decoder.push(bytesOf('\u00ad"}\n\n'));
      const frame = decoder.nextFrame();
      expect(frame !== undefined).assertTrue();
      expect(frame!.data).assertEqual('{"t":"中"}');
    });

    it('sse_invalid_utf8_line_is_skipped', 0, () => {
      const decoder: SseDecoder = new SseDecoder();
      decoder.push(new Uint8Array([0x64, 0x61, 0x74, 0x61, 0x3a, 0x20, 0xff, 0xfe,
        0x20, 0x62, 0x72, 0x6f, 0x6b, 0x65, 0x6e, 0x0a, 0x0a]));
      expect(decoder.nextFrame() === undefined).assertTrue();
      decoder.push(bytesOf('data: fine\n\n'));
      const frame = decoder.nextFrame();
      expect(frame !== undefined).assertTrue();
      expect(frame!.data).assertEqual('fine');
    });

    it('sse_multiple_data_lines_aggregate', 0, () => {
      const decoder: SseDecoder = new SseDecoder();
      decoder.push(bytesOf('data: first\n'));
      expect(decoder.nextFrame() === undefined).assertTrue();
      decoder.push(bytesOf('data: second\n\n'));
      const frame = decoder.nextFrame();
      expect(frame !== undefined).assertTrue();
      expect(frame!.data).assertEqual('first\nsecond');
    });

    it('sse_keepalive_comment_frames_emit_nothing', 0, () => {
      const decoder: SseDecoder = new SseDecoder();
      decoder.push(bytesOf(': keepalive\n\n'));
      expect(decoder.nextFrame() === undefined).assertTrue();
    });

    it('sse_crlf_line_endings_are_handled', 0, () => {
      const decoder: SseDecoder = new SseDecoder();
      decoder.push(bytesOf('data: {"a":1}\r\n\r\n'));
      const frame = decoder.nextFrame();
      expect(frame !== undefined).assertTrue();
      expect(frame!.data).assertEqual('{"a":1}');
    });

    it('sse_leading_bom_is_stripped_and_first_frame_survives', 0, () => {
      const decoder: SseDecoder = new SseDecoder();
      // U+FEFF（EF BB BF）与首字段同行。
      decoder.push(encodeUtf8('\uFEFFid: epoch-1:conversation:7\nevent: turn_started\n'));
      decoder.push(bytesOf('data: {"x":1}\n\n'));
      const frame = decoder.nextFrame();
      expect(frame !== undefined).assertTrue();
      expect(frame!.id).assertEqual('epoch-1:conversation:7');
      expect(frame!.data).assertEqual('{"x":1}');
      expect(decoder.nextFrame() === undefined).assertTrue();
    });

    it('open_request_json_matches_wire', 0, () => {
      const request: RingingV2OpenRequest = new RingingV2OpenRequest('instance-1');
      const json: string = JSON.stringify(request.toWire());
      expect(json).assertEqual('{"schema":"qaqh.Ringing","version":2,' +
        '"client_instance_id":"instance-1"}');
    });

    it('open_response_parses_and_validates', 0, () => {
      const text: string = '{"schema":"qaqh.Ringing","version":2,"accepted":true,' +
        '"client_session_id":"cs-1","server_epoch":"epoch-1","lease_ttl_ms":30000,' +
        '"renew_interval_ms":10000,"capabilities":{"subscribe":true,"interact":true,' +
        '"drive":true,"timeline":true,"service":true,"content":true,"single_stream":true}}';
      const response: RingingV2OpenResponse = RingingV2OpenResponse.parse(text);
      expect(response.clientSessionId).assertEqual('cs-1');
      expect(response.capabilities.singleStream).assertTrue();
      // accepted=false 是结构合法的响应（是否拒绝由客户端层决定，对齐 Rust validate）
      const rejected: RingingV2OpenResponse =
        RingingV2OpenResponse.parse(text.replace('"accepted":true', '"accepted":false'));
      expect(rejected.accepted).assertFalse();
      // schema 不符才是结构非法
      let threw: boolean = false;
      try {
        RingingV2OpenResponse.parse(text.replace('"qaqh.Ringing"', '"qaqh.ringing"'));
      } catch (error) {
        threw = error instanceof ProtocolError &&
          (error as ProtocolError).code === 'invalid_open_response';
      }
      expect(threw).assertTrue();
    });

    it('envelope_reliable_round_trips', 0, () => {
      const token: string = CursorToken.encodeReliable(new CanonicalCursor('log-1', 42, 1))
        .asString();
      const text: string = '{"schema":"qaqh.Ringing","version":2,"server_epoch":"epoch-1",' +
        '"session_id":"seed-1","event_id":"event-1",' +
        '"stream_key":{"kind":"channel","data":"control"},' +
        '"delivery":"reliable","cursor":"' + token + '","log_id":"log-1","fact_seq":42,' +
        '"projection_index":1,"revision":7,"causation_id":"cmd-1","ts_ms":1789830000000,' +
        '"payload":{"kind":"control_delta"}}';
      const envelope: RingingV2EventEnvelope = RingingV2EventEnvelope.parse(text);
      expect(envelope.eventId).assertEqual('event-1');
      expect((envelope.streamKey as StreamKeyChannel).channel).assertEqual('control');
      expect(envelope.tsMs).assertEqual(1789830000000);
    });

    it('envelope_delivery_constraints_are_enforced', 0, () => {
      const token: string = CursorToken.encodeReliable(new CanonicalCursor('log-1', 42, 1))
        .asString();
      const base: string = '{"schema":"qaqh.Ringing","version":2,"server_epoch":"epoch-1",' +
        '"session_id":"seed-1","event_id":"event-1",' +
        '"stream_key":{"kind":"channel","data":"control"},';
      // reliable：cursor 与字段不一致 → reliable_cursor_mismatch
      expectProtocolError('reliable_cursor_mismatch', () => RingingV2EventEnvelope.parse(
        base + '"delivery":"reliable","cursor":"' + token + '","log_id":"log-1","fact_seq":43,' +
        '"projection_index":1,"revision":7,"payload":{}}'));
      // replaceable：带 cursor → invalid_replaceable_envelope
      expectProtocolError('invalid_replaceable_envelope', () => RingingV2EventEnvelope.parse(
        base + '"delivery":"replaceable","cursor":"' + token +
        '","revision":7,"payload":{}}'));
      // replaceable：revision 缺失 → invalid_replaceable_envelope
      expectProtocolError('invalid_replaceable_envelope', () => RingingV2EventEnvelope.parse(
        base + '"delivery":"replaceable","payload":{}}'));
      // ephemeral：带 fact_seq → invalid_ephemeral_envelope
      expectProtocolError('invalid_ephemeral_envelope', () => RingingV2EventEnvelope.parse(
        base + '"delivery":"ephemeral","fact_seq":1,"payload":{}}'));
      // ephemeral：干净形态通过
      RingingV2EventEnvelope.parse(base + '"delivery":"ephemeral","event_id2":1,"payload":{}}');
    });

    it('reset_required_parses', 0, () => {
      const token: string = CursorToken.encodeSnapshot(CanonicalCursor.snapshot('log-1', 42))
        .asString();
      const text: string = '{"schema":"qaqh.Ringing","version":2,"server_epoch":"epoch-1",' +
        '"session_id":"seed-1","log_id":"log-1","snapshot_cursor":"' + token + '",' +
        '"reason":"cursor_expired"}';
      const reset: RingingV2ResetRequired = RingingV2ResetRequired.parse(text);
      expect(reset.reason).assertEqual('cursor_expired');
      // log_id 与快照 cursor 不一致 → reset_log_mismatch
      const mismatch: string = text.replace('"log_id":"log-1"', '"log_id":"log-2"');
      expectProtocolError('reset_log_mismatch', () => RingingV2ResetRequired.parse(mismatch));
    });

    it('bootstrap_json_matches_frozen_shape', 0, () => {
      const token: string = CursorToken.encodeSnapshot(CanonicalCursor.snapshot('log-1', 42))
        .asString();
      const text: string = '{"schema":"qaqh.Ringing","version":2,"server_epoch":"epoch-1",' +
        '"session_id":"seed-1","snapshot_cursor":"' + token + '",' +
        '"control":{"channel":"control","state_revision":7,"snapshot_version":1,' +
        '"state":{"session_id":"seed-1","revision":7,"last_fact_seq":42,' +
        '"interactions":[{"interaction_id":"i1","call_id":"c1","turn_id":"t1",' +
        '"kind":"plan","request":{"kind":"ref","data":{"content_ref":"cnt_1"}}}],' +
        '"driver":{"holder":null,"driver_epoch":3,"can_claim":true}}},' +
        '"conversation":{"channel":"conversation","state_revision":19,"snapshot_version":1,' +
        '"state":{"revision":19,"messages":[]}},' +
        '"tool":{"channel":"tool","state_revision":11,"snapshot_version":1,' +
        '"state":{"tools":[]}}}';
      const bootstrap: RingingV2Bootstrap = RingingV2Bootstrap.parse(text);
      expect(bootstrap.logId()).assertEqual('log-1');
      expect(bootstrap.controlState.interactions.length).assertEqual(1);
      expect(bootstrap.controlState.interactions[0].kind).assertEqual('plan');
      const request = bootstrap.controlState.interactions[0].request;
      expect(request !== undefined).assertTrue();
      expect(request instanceof ContentValueRef).assertTrue();
      expect((request as ContentValueRef).contentRef).assertEqual('cnt_1');
      expect(bootstrap.controlState.driver !== undefined).assertTrue();
      expect(bootstrap.controlState.driver!.driverEpoch).assertEqual(3);
      expect(bootstrap.controlState.driver!.canClaim).assertTrue();
    });

    it('command_ack_carries_typed_existing_result', 0, () => {
      const text: string = '{"command_id":"cmd-1","status":"accepted",' +
        '"message":"duplicate command_id (already completed)",' +
        '"existing":{"source":"command_receipt","state":"succeeded",' +
        '"terminal_event_id":"evt-1","result":{"kind":"ask_resolved",' +
        '"interaction_id":"i1","outcome":"answered"}}}';
      const ack: RingingV2CommandAck = RingingV2CommandAck.parse(text);
      expect(ack.commandId).assertEqual('cmd-1');
      expect(ack.existing !== undefined).assertTrue();
      const receipt: CommandReceiptExisting = ack.existing as CommandReceiptExisting;
      expect(receipt.result instanceof AskResolvedResult).assertTrue();
      expect((receipt.result as AskResolvedResult).outcome).assertEqual('answered');
    });

    it('command_ack_carries_winning_interaction_verdict', 0, () => {
      const text: string = '{"command_id":"cmd-2","status":"rejected",' +
        '"code":"interaction_already_resolved","message":"interaction was already resolved",' +
        '"existing":{"source":"interaction_resolved","result":' +
        '{"kind":"permission_resolved","interaction_id":"int_1","approved":false}}}';
      const ack: RingingV2CommandAck = RingingV2CommandAck.parse(text);
      expect(ack.status).assertEqual('rejected');
      const resolved: InteractionResolvedExisting =
        ack.existing as InteractionResolvedExisting;
      expect(resolved.result instanceof PermissionResolvedResult).assertTrue();
      expect((resolved.result as PermissionResolvedResult).approved).assertFalse();
    });

    it('payload_control_delta_interaction_requested', 0, () => {
      const text: string = '{"kind":"control_delta","data":{"kind":"interaction_requested",' +
        '"data":{"revision":9,"interaction_id":"int_1","call_id":"call_1","kind":"permission",' +
        '"request":{"kind":"ref","data":{"content_ref":"cnt_9"}},"expires_at_ms":null}}}';
      const payload: ProjectionPayload = ProjectionPayload.parse(JSON.parse(text) as object);
      expect(payload.interactionRequested !== undefined).assertTrue();
      expect(payload.interactionRequested!.interactionId).assertEqual('int_1');
      expect(payload.interactionRequested!.kind).assertEqual('permission');
      const request = payload.interactionRequested!.request;
      expect(request instanceof ContentValueRef).assertTrue();
    });

    it('payload_timeline_input_and_tool_result_golden', 0, () => {
      // input 变体（inline 正文）。
      const input: ProjectionPayload = ProjectionPayload.parse(JSON.parse(
        '{"kind":"timeline_delta","data":{"kind":"input","data":{"revision":3,' +
        '"input_id":"in-1","content":{"kind":"inline","data":{"text":"跑个测试"}}}}}') as object);
      expect(input.timeline instanceof TimelineInput).assertTrue();
      const inputDelta = input.timeline as TimelineInput;
      expect(inputDelta.inputId).assertEqual('in-1');
      expect((inputDelta.content as ContentValueInline).text).assertEqual('跑个测试');
      // tool_result 变体（后端 projection_event_contract.rs 黄金向量，output=null）。
      const toolResult: ProjectionPayload = ProjectionPayload.parse(JSON.parse(
        '{"kind":"timeline_delta","data":{"kind":"tool_result","data":{"revision":3,' +
        '"call_id":"call_01J00000000000000000000000","terminal_status":"indeterminate",' +
        '"output":null,"error":{"code":"indeterminate_after_crash",' +
        '"message":"non-idempotent execution not replayed","retryable":false}}}}') as object);
      expect(toolResult.timeline instanceof TimelineToolResult).assertTrue();
      const result = toolResult.timeline as TimelineToolResult;
      expect(result.terminalStatus).assertEqual('indeterminate');
      expect(result.output).assertUndefined();
      expect(result.error !== undefined).assertTrue();
    });

    it('payload_timeline_block_and_enum_failures', 0, () => {
      const block: ProjectionPayload = ProjectionPayload.parse(JSON.parse(
        '{"kind":"timeline_delta","data":{"kind":"block","data":{"revision":5,' +
        '"block_id":"b-1","block_kind":"answer","content":{"kind":"ref",' +
        '"data":{"content_ref":"sha256:abc"}}}}}') as object);
      const blockDelta = block.timeline as TimelineDeltaBlock;
      expect(blockDelta.blockKind).assertEqual('answer');
      expect((blockDelta.content as ContentValueRef).contentRef).assertEqual('sha256:abc');
      // 非法枚举值响亮失败。
      expectProtocolError('invalid_enum_value', () => ProjectionPayload.parse(JSON.parse(
        '{"kind":"timeline_delta","data":{"kind":"block","data":{"revision":5,' +
        '"block_id":"b-1","block_kind":"prose","content":{"kind":"inline",' +
        '"data":{"text":"x"}}}}}') as object));
      // 未知 timeline 变体同 ControlDelta：不显示但不断流，并打出漂移标记。
      const future: ProjectionPayload = ProjectionPayload.parse(JSON.parse(
        '{"kind":"timeline_delta","data":{"kind":"mystery","data":{"revision":1}}}') as object);
      expect(future.unrecognizedTimelineKind).assertEqual('mystery');
      expect(future.timeline !== undefined).assertTrue();
      expect(future.timeline!.kind()).assertEqual('mystery');
      expect(future.timeline!.revision).assertEqual(1);
      // 变体已知、正文畸形仍然响亮失败（容忍的是 kind，不是坏数据）。
      expectProtocolError('missing_field', () => ProjectionPayload.parse(JSON.parse(
        '{"kind":"timeline_delta","data":{"kind":"block","data":{"revision":5,' +
        '"block_kind":"answer"}}}') as object));
    });

    it('payload_unknown_kinds_fail_loudly', 0, () => {
      expectProtocolError('invalid_payload_kind', () =>
        ProjectionPayload.parse(JSON.parse('{"kind":"mystery"}') as object));
      // ControlDelta 的未知 kind **不再**断流（见 unknown_control_delta_does_not_kill_the_stream）：
      // 后端加变体是常态，但结构畸形仍然响亮失败——缺内层 data 就是这个形态。
      expectProtocolError('missing_field', () =>
        ProjectionPayload.parse(JSON.parse(
          '{"kind":"control_delta","data":{"kind":"mystery"}}') as object));
    });

    it('command_envelope_requires_v2_identity', 0, () => {
      const command: RingingCommand = ControlCommands.sessionResume('seed-1');
      const missingIdentity: RingingV2CommandEnvelope =
        RingingV2CommandEnvelope.create('cmd-1', 'instance-1', '', 'seed-1', command);
      expectProtocolError('invalid_v2_command_envelope', () => missingIdentity.toWire());
      const missingSession: RingingV2CommandEnvelope =
        RingingV2CommandEnvelope.create('cmd-1', 'instance-1', 'cs-1', '', command);
      expectProtocolError('missing_session_id', () => missingSession.toWire());
      const valid: RingingV2CommandEnvelope =
        RingingV2CommandEnvelope.create('cmd-1', 'instance-1', 'cs-1', 'seed-1', command);
      valid.toWire();
    });

    it('command_envelope_wire_shape', 0, () => {
      const command: RingingCommand = ControlCommands.sessionResume('seed-1');
      const envelope: RingingV2CommandEnvelope = RingingV2CommandEnvelope.create(
        'cmd-1', 'instance-1', 'cs-1', 'seed-1', command);
      const json: string = JSON.stringify(envelope.toWire());
      // command 对象内部带 channel tag(内部 tag 枚举),与信封顶层 channel 并存。
      expect(json).assertEqual('{"schema":"qaqh.Ringing","version":2,"channel":"control",' +
        '"command_id":"cmd-1","client_instance_id":"instance-1","client_session_id":"cs-1",' +
        '"command":{"channel":"control","type":"session_resume","session_id":"seed-1"},' +
        '"session_id":"seed-1"}');
    });

    it('session_create_allows_missing_session_id', 0, () => {
      const envelope: RingingV2CommandEnvelope = RingingV2CommandEnvelope.create(
        'cmd-2', 'instance-1', 'cs-1', '', ControlCommands.sessionCreate(true));
      const json: string = JSON.stringify(envelope.toWire());
      expect(json.includes('"session_id"')).assertFalse();
      expect(json.includes('"command":{"channel":"control","type":"session_create"'))
        .assertTrue();
    });

    it('interaction_commands_match_wire_values', 0, () => {
      const ask: RingingV2CommandEnvelope = RingingV2CommandEnvelope.create(
        'cmd-3', 'instance-1', 'cs-1', 'seed-1',
        ControlCommands.interactionAskRespond('int_1', [new AskAnswer('q1', 'yes')]));
      const askJson: string = JSON.stringify(ask.toWire());
      expect(askJson.includes('"command":{"channel":"control",' +
        '"type":"interaction_ask_respond",')).assertTrue();
      expect(askJson.includes('"answers":[{"question_id":"q1","answer":"yes"}]')).assertTrue();

      const plan: RingingV2CommandEnvelope = RingingV2CommandEnvelope.create(
        'cmd-4', 'instance-1', 'cs-1', 'seed-1',
        ControlCommands.planReviewRespond('int_2', false, '', false));
      expect(JSON.stringify(plan.toWire())
        .includes('"type":"plan_review_respond","interaction_id":"int_2","approved":false'))
        .assertTrue();

      const permission: RingingV2CommandEnvelope = RingingV2CommandEnvelope.create(
        'cmd-5', 'instance-1', 'cs-1', 'seed-1',
        ToolCommands.toolPermissionRespond('call_1', true, false));
      expect(JSON.stringify(permission.toWire())
        .includes('"command":{"channel":"tool","type":"tool_permission_respond",' +
          '"tool_call_id":"call_1",' +
          '"approved":true,"trust_folder":false}')).assertTrue();
    });

    it('conversation_and_driver_commands_match_wire_values', 0, () => {
      const send: RingingV2CommandEnvelope = RingingV2CommandEnvelope.create(
        'cmd-6', 'instance-1', 'cs-1', 'seed-1', ConversationCommands.sendMessage('你好'));
      expect(JSON.stringify(send.toWire())
        .includes('"channel":"conversation"')).assertTrue();

      const claim: RingingV2CommandEnvelope = RingingV2CommandEnvelope.create(
        'cmd-7', 'instance-1', 'cs-1', 'seed-1', ControlCommands.driverClaim('cs-1', ''));
      expect(JSON.stringify(claim.toWire())
        .includes('"command":{"channel":"control","type":"driver_claim",' +
          '"client_session_id":"cs-1"}')).assertTrue();
    });

    it('assert_ack_matches_guards_id', 0, () => {
      assertAckMatches('cmd-1', 'cmd-1');
      expectProtocolError('ack_mismatch', () => assertAckMatches('cmd-1', 'cmd-2'));
    });

    it('driver_claim_response_parses', 0, () => {
      const busy = RingingV2DriverClaimResponse.parse(
        '{"accepted":false,"holder":"cs-other","driver_epoch":3,"reason":"driver_busy"}');
      expect(busy.accepted).assertFalse();
      expect(busy.holder).assertEqual('cs-other');
      expect(busy.driverEpoch).assertEqual(3);
      expect(busy.reason).assertEqual('driver_busy');

      const granted = RingingV2DriverClaimResponse.parse(
        '{"accepted":true,"holder":null,"driver_epoch":0,"reason":"claim_requested"}');
      expect(granted.accepted).assertTrue();
      expect(granted.holder === undefined).assertTrue();
      expect(granted.reason).assertEqual('claim_requested');

      const held = RingingV2DriverClaimResponse.parse(
        '{"accepted":true,"holder":"cs-1","driver_epoch":4,"reason":"already_holder"}');
      expect(held.accepted).assertTrue();
      expect(held.driverEpoch).assertEqual(4);
    });

    it('interaction_body_ask_and_permission_parse', 0, () => {
      // ask 正文（interaction_body.rs 单一来源格式）。
      const ask: InteractionBody = InteractionBody.parse(
        '{"kind":"ask","mode":"batch","questions":[{"id":"q1","question":"选一个？",' +
        '"options":["方案 A","方案 B"],"allow_custom":false}]}');
      expect(ask.kind).assertEqual('ask');
      expect(ask.ask !== undefined).assertTrue();
      expect(ask.ask!.mode).assertEqual(AskModeWire.BATCH);
      expect(ask.ask!.questions.length).assertEqual(1);
      expect(ask.ask!.questions[0].id).assertEqual('q1');
      expect(ask.ask!.questions[0].options.length).assertEqual(2);
      expect(ask.ask!.questions[0].allowCustom).assertFalse();
      // permission 正文（纯 v2 后壳层必须从 canonical ref 渲染授权面板）。
      const permission: InteractionBody = InteractionBody.parse(
        '{"kind":"permission","tool_name":"Bash","action_summary":"rm -rf /tmp/x",' +
        '"reason":"clean temp","paths":["/tmp/x"],"category":"write","level":2,' +
        '"risk":"medium","consequence":"删除目录"}');
      expect(permission.permission !== undefined).assertTrue();
      expect(permission.permission!.toolName).assertEqual('Bash');
      expect(permission.permission!.paths.length).assertEqual(1);
      expect(permission.permission!.risk).assertEqual('medium');
      // 展示面容忍策略：未知 kind 不抛错，保留 raw 供 UI 降级。
      const mystery: InteractionBody = InteractionBody.parse(
        '{"kind":"mystery","x":1}');
      expect(mystery.kind).assertEqual('mystery');
      expect(mystery.ask).assertUndefined();
      // 畸形 JSON 才响亮失败。
      expectProtocolError('bad_json', () => InteractionBody.parse('not-json'));
    });

    it('session_list_parses_and_prefers_running', 0, () => {
      const entries: RingingSessionListEntry[] = RingingSessionListEntry.parseArray(
        '[{"session_id":"s1","updated_at":100,"message_count":3},' +
        '{"session_id":"s2","updated_at":50,"running":true,"last_summary":"跑测试"}]');
      expect(entries.length).assertEqual(2);
      expect(entries[0].sessionId).assertEqual('s1');
      expect(entries[0].running).assertFalse();
      expect(entries[1].lastSummary).assertEqual('跑测试');
      // running 优先于 updated_at 最新。
      expect(pickPreferredSession(entries)).assertEqual('s2');
      // 无 running → updated_at 最新。
      expect(pickPreferredSession(RingingSessionListEntry.parseArray(
        '[{"session_id":"a","updated_at":1},{"session_id":"b","updated_at":9}]')))
        .assertEqual('b');
      // 空列表 → 空串。
      expect(pickPreferredSession(RingingSessionListEntry.parseArray('[]')))
        .assertEqual('');
    });

    it('session_list_display_title_mirrors_g2_fallback_chain', 0, () => {
      // G2 口径：title → cwd 尾段 → 短 id；last_summary 永不参与标题。
      const titled: RingingSessionListEntry = RingingSessionListEntry.parseArray(
        '[{"session_id":"0123456789abcdef","title":"修复登录超时","cwd":"/home/u/proj",' +
        '"last_summary":"模型最近说的话","model":"deepseek-chat"}]')[0];
      expect(titled.displayTitle()).assertEqual('修复登录超时');
      const cwdOnly: RingingSessionListEntry = RingingSessionListEntry.parseArray(
        '[{"session_id":"0123456789abcdef","cwd":"C:\\\\repos\\\\qaqh","title":null}]')[0];
      expect(cwdOnly.displayTitle()).assertEqual('qaqh');
      const bare: RingingSessionListEntry = RingingSessionListEntry.parseArray(
        '[{"session_id":"0123456789abcdef"}]')[0];
      expect(bare.displayTitle()).assertEqual('01234567');
      // title 空串视为未生成（后端 filter(|s| !s.is_empty()) 同语义）。
      const emptyTitle: RingingSessionListEntry = RingingSessionListEntry.parseArray(
        '[{"session_id":"0123456789abcdef","title":"","cwd":"/tmp/ws/"}]')[0];
      expect(emptyTitle.displayTitle()).assertEqual('ws');
    });

    it('session_list_wire_keys_mirror_backend_lock_table', 0, () => {
      // 后端 qaqh-types 的 session_list_entry_wire_keys_are_locked 是本表唯一的
      // 权威源；两侧各自「显式过一次评审」，任何一侧悄悄漂走都要在这里响。
      const sorted: string = SESSION_LIST_WIRE_KEYS.slice(0).sort().join(',');
      expect(sorted).assertEqual(
        'archived,cache_reported_requests,compact_covered_through_msg_id,compact_skip,' +
        'context_stats,created_at,custom_tools,cwd,effort,ephemeral,frozen_annotation,' +
        'last_summary,last_usage,message_count,mode,model,profile,running,session_id,' +
        'skills,title,tool_mode,turn_count,updated_at,usage_requests,usage_totals,' +
        'workspace_id');
      expect(SESSION_LIST_WIRE_KEYS.length).assertEqual(27);
      // 建模键必须都在表内（加了字段忘了登记 = 锁表失效）。
      for (const key of SESSION_LIST_MODELED_KEYS) {
        expect(SESSION_LIST_WIRE_KEYS.includes(key)).assertTrue();
      }
      // 后端 #[serde(skip)] 的运行期字段：永不出线，也不许被认成有效键。
      for (const key of SESSION_LIST_NEVER_ON_WIRE_KEYS) {
        expect(SESSION_LIST_WIRE_KEYS.includes(key)).assertFalse();
      }
    });

    it('session_list_archived_and_ephemeral_stay_out_of_active_surfaces', 0, () => {
      // 后端 list_sessions 不过滤（归档会话照发），且 set_archived 会把
      // updated_at 刷成当下——不过滤就等于让刚归档那条恒占「最新」位。
      const entries: RingingSessionListEntry[] = RingingSessionListEntry.parseArray(
        '[{"session_id":"old","updated_at":10},' +
        '{"session_id":"arch","updated_at":99,"running":true,"archived":true},' +
        '{"session_id":"sub","updated_at":98,"ephemeral":true},' +
        '{"session_id":"live","updated_at":20,"running":true}]');
      // 旧 meta 缺键 = 未归档/非临时（后端 #[serde(default)] 同语义）。
      expect(entries[0].archived).assertFalse();
      expect(entries[0].ephemeral).assertFalse();
      expect(entries[1].archived).assertTrue();
      expect(entries[2].ephemeral).assertTrue();
      expect(entries[1].isListable()).assertFalse();
      expect(entries[2].isListable()).assertFalse();
      expect(entries[3].isListable()).assertTrue();
      expect(visibleSessions(entries).length).assertEqual(2);
      // running 优先只在可展示会话里成立。
      expect(pickPreferredSession(entries)).assertEqual('live');
      // 全归档/全临时 → 空串（与「无可见会话」同一路径）。
      expect(pickPreferredSession(RingingSessionListEntry.parseArray(
        '[{"session_id":"a","archived":true},{"session_id":"b","ephemeral":true}]')))
        .assertEqual('');
    });

    it('session_list_drift_keys_are_recorded_not_fatal', 0, () => {
      // 表内（已知未建模）收下不留痕；表外（后端未经评审的新键）记进
      // unmodeledKeys——绝不让整条流/整张列表作废。
      const entry: RingingSessionListEntry = RingingSessionListEntry.parseArray(
        '[{"session_id":"s1","updated_at":5,"model":"m",' +
        '"usage_totals":{"prompt_tokens":1},"skills":{"version":2},' +
        '"subagent_of":"p1","tokens":8}]')[0];
      expect(entry.sessionId).assertEqual('s1');
      expect(entry.running).assertFalse();
      expect(entry.unmodeledKeys.length).assertEqual(2);
      expect(entry.unmodeledKeys[0]).assertEqual('subagent_of');
      expect(entry.unmodeledKeys[1]).assertEqual('tokens');
      // 全表条目 = 零漂移。
      const clean: RingingSessionListEntry = RingingSessionListEntry.parseArray(
        '[{"session_id":"s1","archived":false,"ephemeral":false,"cwd":"/tmp",' +
        '"title":"t","workspace_id":null,"running":true}]')[0];
      expect(clean.unmodeledKeys.length).assertEqual(0);
      // workspace_id 未分组是 null 而非缺键（后端历史形状），解析为 undefined。
      expect(clean.workspaceId).assertUndefined();
    });

    it('pairing_wire_parses_and_validates', 0, () => {
      const issued: RingingV2PairTokenResponse = RingingV2PairTokenResponse.parse(
        '{"pairing_token":"01M47AXG00000000000000000001M47AXG000000000000000001",' +
        '"expires_in_ms":120000,' +
        '"tls_fp":"sha256:5ec75e5ff53bc0b51599ea1e0241f79b944513ea027a0d0f7a0b639d06b54ed5"}');
      expect(issued.pairingToken.length).assertEqual(52);
      expect(issued.expiresInMs).assertEqual(120000);
      expect(issued.tlsFingerprint.startsWith('sha256:')).assertTrue();
      // 回环 daemon 无 TLS 时 tls_fp 为空串——字段可缺省。
      expect(RingingV2PairTokenResponse.parse(
        '{"pairing_token":"t","expires_in_ms":120000}').tlsFingerprint).assertEqual('');

      const paired: RingingV2PairResponse = RingingV2PairResponse.parse(
        '{"device_id":"01M47AXHRDEXAR6MSWE4291W6G","device_token":"dt",' +
        '"scope":"interact","daemon_version":"2.0.0-beta.2","protocol_version":2}');
      expect(paired.deviceId).assertEqual('01M47AXHRDEXAR6MSWE4291W6G');
      expect(paired.scope).assertEqual(DeviceScope.INTERACT);

      let thrown: string = '';
      try {
        // scope 不在 view|interact|admin 之内说明对拍错位，必须响亮失败。
        RingingV2PairResponse.parse('{"device_id":"d","device_token":"t",' +
          '"scope":"root","daemon_version":"x","protocol_version":2}');
      } catch (error) {
        thrown = (error as ProtocolError).code;
      }
      expect(thrown).assertEqual('invalid_pair_response');

      // 请求体字段名与 Rust 侧一致（snake_case）。
      expect(new RingingV2PairTokenRequest(DeviceScope.INTERACT, 'phone', 'harmony')
        .toWire()['scope_grant']).assertEqual('interact');
      expect(new RingingV2PairRequest('pt', 'phone', 'harmony')
        .toWire()['pairing_token']).assertEqual('pt');
    });

    it('wire_error_body_is_tolerant', 0, () => {
      expect(WireErrorBody.parse('{"code":"pairing_used","message":"x"}').code)
        .assertEqual('pairing_used');
      // 未鉴权时 daemon 回纯文本 `unauthorized`，不能因此再抛一次。
      const plain: WireErrorBody = WireErrorBody.parse('unauthorized');
      expect(plain.code).assertEqual('');
      expect(plain.message).assertEqual('');
    });

    it('driver_changed_delta_parses', 0, () => {
      // 后端 ControlDelta::DriverChanged：holder 缺省即已释放席位。
      const held: ProjectionPayload = ProjectionPayload.parse(JSON.parse(
        '{"kind":"control_delta","data":{"kind":"driver_changed","data":' +
        '{"revision":12,"holder":"01M47AXHRDEXAR6MSWE4291W6G","driver_epoch":4}}}') as object);
      expect(held.driverChanged !== undefined).assertTrue();
      expect(held.driverChanged!.holder).assertEqual('01M47AXHRDEXAR6MSWE4291W6G');
      expect(held.driverChanged!.driverEpoch).assertEqual(4);
      expect(held.driverChanged!.released()).assertFalse();

      const released: ProjectionPayload = ProjectionPayload.parse(JSON.parse(
        '{"kind":"control_delta","data":{"kind":"driver_changed","data":' +
        '{"revision":13,"driver_epoch":5}}}') as object);
      expect(released.driverChanged!.released()).assertTrue();
      // holder 走 skip_serializing_if，显式 null 也必须收下。
      const nulled: ProjectionPayload = ProjectionPayload.parse(JSON.parse(
        '{"kind":"control_delta","data":{"kind":"driver_changed","data":' +
        '{"revision":14,"holder":null,"driver_epoch":6}}}') as object);
      expect(nulled.driverChanged!.released()).assertTrue();

      let thrown: string = '';
      try {
        ProjectionPayload.parse(JSON.parse('{"kind":"control_delta","data":' +
          '{"kind":"driver_changed","data":{"revision":1,"driver_epoch":-3}}}') as object);
      } catch (error) {
        thrown = (error as ProtocolError).code;
      }
      expect(thrown).assertEqual('invalid_driver_epoch');
    });

    it('unknown_control_delta_does_not_kill_the_stream', 0, () => {
      // 真机教训（2026-10-06）：driver_changed 未建模时整条监视流被响亮硬停。
      // 展示面对未知 kind 必须容忍；只有结构畸形才响亮失败。
      const unknown: ProjectionPayload = ProjectionPayload.parse(JSON.parse(
        '{"kind":"control_delta","data":{"kind":"quantum_leap","data":' +
        '{"revision":9,"whatever":[1,2]}}}') as object);
      expect(unknown.interactionRequested === undefined).assertTrue();
      expect(unknown.opaqueControl !== undefined).assertTrue();
      expect(unknown.opaqueControl!.kind).assertEqual('quantum_leap');
      expect(unknown.opaqueControl!.revision).assertEqual(9);
      // 漂移要看得见：未列入全集的 kind 由 UI 提示，而不是靠断流暴露。
      expect(unknown.unrecognizedControlKind).assertEqual('quantum_leap');

      // 全集内但未建模的变体（后端已有的 subagent_*）不算漂移，不提示。
      const knownUnmodeled: ProjectionPayload = ProjectionPayload.parse(JSON.parse(
        '{"kind":"control_delta","data":{"kind":"subagent_finished","data":' +
        '{"revision":3,"child_session_id":"c1","parent_call_id":"call_1",' +
        '"status":"completed"}}}') as object);
      expect(knownUnmodeled.unrecognizedControlKind).assertEqual('');
      expect(knownUnmodeled.opaqueControl!.kind).assertEqual('subagent_finished');

      let thrown: string = '';
      try {
        ProjectionPayload.parse(JSON.parse(
          '{"kind":"control_delta","data":{"kind":"round"}}') as object);
      } catch (error) {
        thrown = (error as ProtocolError).code;
      }
      expect(thrown === 'missing_field' || thrown === 'bad_field').assertTrue();
    });

    it('inline_content_value_parses', 0, () => {
      const payload: ProjectionPayload = ProjectionPayload.parse(JSON.parse(
        '{"kind":"control_delta","data":{"kind":"interaction_requested","data":' +
        '{"revision":1,"interaction_id":"int_1","kind":"ask",' +
        '"request":{"kind":"inline","data":{"text":"选一个？"}}}}}') as object);
      const request = payload.interactionRequested!.request;
      expect(request instanceof ContentValueInline).assertTrue();
      expect((request as ContentValueInline).text).assertEqual('选一个？');
    });

    it('command_id_survives_causation_lane', 0, () => {
      // 后端 canonical/identity.rs:219 + validation.rs:950：只有 26 位大写
      // Crockford（is_ulid_text）的 id 才原样进因果链，其它形态被 SHA-256
      // 派生成另一个 ULID，事件里的 causation_id 就对不上本端 command_id。
      const alphabet: string = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
      const id: string = newCommandId();
      expect(id.length).assertEqual(26);
      for (let i = 0; i < id.length; i++) {
        expect(alphabet.indexOf(id.charAt(i)) >= 0).assertTrue();
      }
      expect(newCommandId() === id).assertFalse();
    });

    it('stream_terminated_frame_parses', 0, () => {
      // 后端 v2.rs:596 的终止帧是裸 json!，没有 schema/version。
      const terminated: RingingV2StreamTerminated = RingingV2StreamTerminated.parse(
        '{"code":"revoked","session_id":"seed-1",' +
        '"message":"client lease revoked or expired; reconnect after re-auth"}');
      expect(terminated.code).assertEqual(RingingV2StreamTerminated.CODE_REVOKED);
      expect(terminated.sessionId).assertEqual('seed-1');
      expect(terminated.message.length > 0).assertTrue();

      const bare: RingingV2StreamTerminated =
        RingingV2StreamTerminated.parse('{"code":"revoked","session_id":"s"}');
      expect(bare.message).assertEqual('');

      let thrown: string = '';
      try {
        RingingV2StreamTerminated.parse('{"session_id":"s"}');
      } catch (error) {
        thrown = (error as ProtocolError).code;
      }
      expect(thrown).assertEqual('missing_field');
    });
  });
}
