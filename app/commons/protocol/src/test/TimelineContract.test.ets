/**
 * Timeline 通道契约测试（M7）。
 *
 * 夹具形态取自真 daemon 抓包（timeline_api.rs handle_timeline_snapshot +
 * sse.rs timeline_entry_to_event）逐字段对拍：快照摊平文本、游标
 * `{epoch}:timeline:{seq}`、事件 tag 是 `type`。
 * 夹具用对象构造 + JSON.stringify：手写转义一旦出错会伪装成「协议不符」，
 * 而真正要验的是解析器对字段形态的态度。
 */

import { describe, it, expect } from '@ohos/hypium';

import { ProtocolError } from '../main/ets/wire/Json';
import {
  encodeTimelineCursor, parseTimelineCursor, timelineEventsPath, timelinePath,
  RingingV2TimelineFrame, TimelineBlockKind, TimelineEntry, TimelineEventType,
  TimelineSnapshotResponse, TimelineToolState, TimelineTurn, TimelineFailure,
  TimelineFailureCode
} from '../main/ets/wire/Timeline';

const EPOCH: string = '814155bfa1808ab5c73a58512372e40c35039d960707f8421ba32a46e1099ffe';

/** 一页快照：1 个回合，reasoning / text / tool 三块（正文已摊平）。 */
function snapshotPage(withTurnIndex: boolean): Record<string, Object> {
  const reasoning: Record<string, Object> = { 'block_id': 'round-0:reasoning:0',
    'block_order': 0, 'kind': 'reasoning', 'state': 'sealed', 'text': 'thinking…' };
  const answer: Record<string, Object> = { 'block_id': 'round-0:text:1',
    'block_order': 1, 'kind': 'text', 'state': 'sealed', 'text': 'answer text' };
  const tool: Record<string, Object> = { 'tool_call_id': 'call_1', 'name': 'bash',
    'state': 'succeeded', 'args_json': '{ "cmd": "ls" }', 'output': 'a.txt',
    'progress': '', 'progress_truncated': false };
  const toolBlock: Record<string, Object> = { 'block_id': 'round-0:tool:2',
    'block_order': 2, 'kind': 'tool', 'state': 'sealed', 'tool': tool };
  const round: Record<string, Object> = { 'round_num': 0, 'sealed': true,
    'is_final': true, 'blocks': [reasoning, answer, toolBlock] };
  const turn: Record<string, Object> = { 'turn_id': 't1', 'created_seq': 10,
    'user_text': 'hello', 'sealed': true, 'state': 'completed', 'rounds': [round] };
  if (withTurnIndex) {
    turn['turn_index'] = 0;
  }
  const snapshot: Record<string, Object> = { 'watermark': 13683, 'turns': [turn] };
  return {
    'schema': 'qaqh.Ringing', 'version': 2, 'server_epoch': EPOCH,
    'session_id': 'seed-1', 'snapshot': snapshot, 'has_more': true,
    'total_turns': 4, 'truncated_before': false
  };
}

/** 一帧 `timeline.entry` 的 data 体；roundNum < 0 表示 turn 级事件不带它。 */
function frameData(seq: number, event: Record<string, Object>,
  roundNum: number, turnId: string): string {
  const entry: Record<string, Object> = { 'timeline_seq': seq, 'turn_id': turnId,
    'event': event };
  if (roundNum >= 0) {
    entry['round_num'] = roundNum;
  }
  const frame: Record<string, Object> = {
    'schema': 'qaqh.Ringing', 'version': 2, 'server_epoch': EPOCH,
    'session_id': 'seed-1', 'entry': entry
  };
  return JSON.stringify(frame);
}

export default function timelineContractTest() {
  describe('timeline_contract', () => {
    it('timeline_paths_carry_paging_and_cursor', 0, () => {
      expect(timelinePath('seed-1'))
        .assertEqual('/ringing/v2/sessions/seed-1/timeline');
      expect(timelinePath('seed-1', 50))
        .assertEqual('/ringing/v2/sessions/seed-1/timeline?limit=50');
      expect(timelinePath('seed-1', 50, 2))
        .assertEqual('/ringing/v2/sessions/seed-1/timeline?limit=50&before_index=2');
      // 游标里的冒号必须转义，否则 daemon 的 query 解析拿不到完整 id。
      expect(timelineEventsPath('seed-1', encodeTimelineCursor(EPOCH, 13683)))
        .assertEqual('/ringing/v2/sessions/seed-1/timeline/events?last_event_id=' +
          encodeURIComponent(encodeTimelineCursor(EPOCH, 13683)));
      expect(timelineEventsPath('seed-1'))
        .assertEqual('/ringing/v2/sessions/seed-1/timeline/events');
    });

    it('timeline_cursor_roundtrip', 0, () => {
      expect(encodeTimelineCursor(EPOCH, 13683)).assertEqual(`${EPOCH}:timeline:13683`);
      expect(parseTimelineCursor(`${EPOCH}:timeline:13683`, EPOCH)).assertEqual(13683);
      // 非法 seq / 别的通道 / epoch 不符 / 空串：一律解不出，交调用方回退重放。
      expect(parseTimelineCursor(`${EPOCH}:timeline:abc`, EPOCH) === undefined).assertTrue();
      expect(parseTimelineCursor('other-epoch:timeline:12', EPOCH) === undefined).assertTrue();
      expect(parseTimelineCursor(`${EPOCH}:control:12`, EPOCH) === undefined).assertTrue();
      expect(parseTimelineCursor('', EPOCH) === undefined).assertTrue();
    });

    it('timeline_snapshot_parses_flattened_turns', 0, () => {
      const page: TimelineSnapshotResponse = TimelineSnapshotResponse.parse(
        JSON.stringify(snapshotPage(true)));
      expect(page.watermark).assertEqual(13683);
      expect(page.turns.length).assertEqual(1);
      const turn: TimelineTurn = page.turns[0];
      expect(turn.turnId).assertEqual('t1');
      expect(turn.turnIndex).assertEqual(0);
      expect(turn.userText).assertEqual('hello');
      expect(turn.state).assertEqual('completed');
      expect(turn.rounds.length).assertEqual(1);
      expect(turn.rounds[0].blocks.length).assertEqual(3);
      expect(turn.rounds[0].isFinal).assertTrue();
      const reasoning = turn.rounds[0].blocks[0];
      expect(reasoning.kind).assertEqual(TimelineBlockKind.REASONING);
      // 正文由服务端摊平：客户端不再解 content ref。
      expect(reasoning.text).assertEqual('thinking…');
      const tool = turn.rounds[0].blocks[2].tool;
      expect(tool !== undefined).assertTrue();
      expect(tool!.name).assertEqual('bash');
      expect(tool!.state).assertEqual(TimelineToolState.SUCCEEDED);
      expect(tool!.argsText).assertEqual('{ "cmd": "ls" }');
      expect(tool!.output).assertEqual('a.txt');
      expect(tool!.progressTruncated).assertFalse();
      expect(page.hasMore).assertTrue();
      expect(page.totalTurns).assertEqual(4);
      expect(page.truncatedBefore).assertFalse();
      expect(page.oldestIndex()).assertEqual(0);
    });

    it('timeline_snapshot_survives_missing_turn_index', 0, () => {
      // 真 daemon 实测：rehydrate 把回填过的 turn_index 覆盖成 null
      // （4 个回合全 null），客户端必须还能算出深翻页游标。
      const page: TimelineSnapshotResponse = TimelineSnapshotResponse.parse(
        JSON.stringify(snapshotPage(false)));
      expect(page.turns[0].turnIndex === undefined).assertTrue();
      expect(page.oldestIndex()).assertEqual(3);
    });

    it('timeline_entry_events_parse_by_type_tag', 0, () => {
      const opened: RingingV2TimelineFrame = RingingV2TimelineFrame.parse(frameData(13684,
        { 'type': 'turn_opened', 'user_text': 'next question' }, -1, 't2'));
      expect(opened.entry.timelineSeq).assertEqual(13684);
      expect(opened.entry.event.type).assertEqual(TimelineEventType.TURN_OPENED);
      expect(opened.entry.event.userText).assertEqual('next question');
      expect(opened.entry.turnId).assertEqual('t2');
      expect(opened.serverEpoch).assertEqual(EPOCH);
      expect(opened.entry.roundNum === undefined).assertTrue();

      const delta: RingingV2TimelineFrame = RingingV2TimelineFrame.parse(frameData(13686,
        { 'type': 'text_delta', 'block_id': 'round-0:text:1', 'fragment_seq': 7,
          'delta': 'chunk' }, 0, 't2'));
      expect(delta.entry.event.type).assertEqual(TimelineEventType.TEXT_DELTA);
      expect(delta.entry.event.blockId).assertEqual('round-0:text:1');
      expect(delta.entry.event.fragmentSeq).assertEqual(7);
      expect(delta.entry.event.delta).assertEqual('chunk');
      expect(delta.entry.roundNum).assertEqual(0);

      // block_checkpoint：arg 是增量、text 是整体覆盖，两者都可缺省。
      const checkpoint: RingingV2TimelineFrame = RingingV2TimelineFrame.parse(frameData(13687,
        { 'type': 'block_checkpoint', 'block_id': 'round-0:reasoning:0', 'arg': '' },
        0, 't2'));
      expect(checkpoint.entry.event.arg).assertEqual('');
      expect(checkpoint.entry.event.text).assertEqual('');

      const sealed: RingingV2TimelineFrame = RingingV2TimelineFrame.parse(frameData(13855,
        { 'type': 'turn_sealed', 'state': 'completed' }, -1, 't2'));
      expect(sealed.entry.event.type).assertEqual(TimelineEventType.TURN_SEALED);
      expect(sealed.entry.event.state).assertEqual('completed');

      const failure: Record<string, Object> = { 'code': 'provider_error',
        'message': 'boom' };
      const failed: RingingV2TimelineFrame = RingingV2TimelineFrame.parse(frameData(13856,
        { 'type': 'turn_sealed', 'state': 'failed', 'failure': failure }, -1, 't2'));
      expect(failed.entry.event.failure !== undefined).assertTrue();
      expect(failed.entry.event.failure!.code).assertEqual('provider_error');

      const block: Record<string, Object> = { 'block_id': 'round-0:tool:2',
        'block_order': 2, 'kind': 'tool', 'state': 'open' };
      const openedBlock: RingingV2TimelineFrame = RingingV2TimelineFrame.parse(frameData(13685,
        { 'type': 'block_opened', 'block': block }, 0, 't2'));
      expect(openedBlock.entry.event.block !== undefined).assertTrue();
      expect(openedBlock.entry.event.block!.kind).assertEqual(TimelineBlockKind.TOOL);
    });

    it('timeline_frame_rejects_wrong_version', 0, () => {
      // 服务端注释：版本不符会让每一帧被判协议违例，1s 重连死循环。
      const frame: string = frameData(1, { 'type': 'block_sealed', 'block_id': 'b' },
        0, 't2');
      const bad: string = frame.replace('"version":2', '"version":1');
      let code: string = '';
      try {
        RingingV2TimelineFrame.parse(bad);
      } catch (error) {
        code = (error as ProtocolError).code;
      }
      expect(code).assertEqual('invalid_timeline_frame');
    });

    it('timeline_unknown_event_type_is_tolerated', 0, () => {
      const future: RingingV2TimelineFrame = RingingV2TimelineFrame.parse(frameData(42,
        { 'type': 'hologram_updated', 'block_id': 'round-0:text:1' }, 0, 't2'));
      expect(future.entry.event.known()).assertFalse();
      expect(future.entry.event.type).assertEqual('hologram_updated');
      expect(future.entry.timelineSeq).assertEqual(42);
      // 结构畸形仍然响亮失败（容忍的是变体名，不是坏数据）。
      const broken: Record<string, Object> = { 'timeline_seq': 1, 'turn_id': 't' };
      let code: string = '';
      try {
        new TimelineEntry(broken);
      } catch (error) {
        code = (error as ProtocolError).code;
      }
      expect(code).assertEqual('missing_field');
    });

    it('timeline_failure_code_is_structured_error_kind', 0, () => {
      // 模型请求失败槽：code = gate 统一 ErrorKind 的 snake_case 码。
      const gateWire: Record<string, Object> =
        { 'code': 'context_length_exceeded', 'message': '上下文超限' };
      const gateFailure: TimelineFailure = new TimelineFailure(gateWire);
      expect(gateFailure.code).assertEqual('context_length_exceeded');
      expect(TimelineFailureCode.isKnownGateKind(gateFailure.code)).assertTrue();
      expect(TimelineFailureCode.isKnownGateKind('stream_protocol')).assertTrue();

      // 本地构造失败（未到 gate）保留历史字面量。
      const localWire: Record<string, Object> =
        { 'code': TimelineFailureCode.MODEL_REQUEST_FAILED, 'message': 'Model request failed' };
      const localFailure: TimelineFailure = new TimelineFailure(localWire);
      expect(localFailure.code).assertEqual('model_request_failed');
      expect(TimelineFailureCode.isKnownGateKind(localFailure.code)).assertFalse();

      // 未知未来码仍在展示面容忍策略内（收下、不断流、不特殊处理）。
      const futureWire: Record<string, Object> = { 'code': 'quantum_flux', 'message': '?' };
      const future: TimelineFailure = new TimelineFailure(futureWire);
      expect(TimelineFailureCode.isKnownGateKind(future.code)).assertFalse();
    });
  });
}
