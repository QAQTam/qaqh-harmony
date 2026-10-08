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
  TimelineFailureCode, TimelineTool, TimelineToolBody, TimelineToolBodyKind,
  TimelineToolHeaderKind
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

    // 类型化展示投影（跨仓展示契约 §3.3）。夹具取自真机会话快照的 tool.display，
    // 就是此前被整块忽略、导致工具卡呈现裸 JSON 的那几个字段。
    it('tool_display_projection_is_parsed_over_legacy_strings', 0, () => {
      const header: Record<string, Object> = { 'kind': 'other', 'label': 'process check' };
      const body: Record<string, Object> = {
        'kind': 'text', 'text': 'process 15: running', 'truncated': false };
      const metrics: Record<string, Object> = {
        'elapsed_ms': 5, 'output_bytes': 217, 'retry_count': 0, 'user_initiated': false };
      const outcome: Record<string, Object> = {
        'state': 'succeeded', 'exit_code': 0, 'duration_ms': 5, 'output_bytes': 217,
        'truncated': false };
      const display: Record<string, Object> = {
        'header': header, 'body': body, 'metrics': metrics, 'outcome': outcome };
      // 扁平兜底槽：旧路径显示给用户的就是这一坨裸 JSON。
      const wire: Record<string, Object> = {
        'tool_call_id': 'call_process_1', 'name': 'process', 'state': 'succeeded',
        'output': '{"id":15,"name":"pwsh.exe","status":"running"}', 'display': display };

      const tool: TimelineTool = new TimelineTool(wire);
      expect(tool.display !== undefined).assertTrue();
      expect(tool.display!.header!.kind).assertEqual(TimelineToolHeaderKind.OTHER);
      expect(tool.display!.header!.label).assertEqual('process check');
      expect(tool.display!.body!.kind).assertEqual(TimelineToolBodyKind.TEXT);
      expect(tool.display!.body!.text).assertEqual('process 15: running');
      expect(tool.display!.body!.hasContent()).assertTrue();
      expect(tool.display!.metrics!.elapsedMs).assertEqual(5);
      expect(tool.resolvedExitCode()).assertEqual(0);
    });

    it('tool_display_streams_split_and_exit_code_precedence', 0, () => {
      // streams：stdout/stderr 分离（扁平 output 里两者已拼接，拿不回来）。
      const shellHeader: Record<string, Object> = { 'kind': 'shell', 'command': 'pwsh -c ls' };
      const streamsBody: Record<string, Object> = {
        'kind': 'streams', 'stdout': 'a.txt\n', 'stderr': 'warn\n', 'exit_code': 2,
        'interleaved': false };
      const streamsDisplay: Record<string, Object> = {
        'header': shellHeader, 'body': streamsBody };
      const streamsWire: Record<string, Object> = {
        'tool_call_id': 'call_exec_1', 'name': 'exec', 'state': 'failed',
        'output': '{"status":"completed","exit_code":2}', 'display': streamsDisplay };

      const streams: TimelineToolBody = new TimelineTool(streamsWire).display!.body!;
      expect(streams.kind).assertEqual(TimelineToolBodyKind.STREAMS);
      expect(streams.stdout).assertEqual('a.txt\n');
      expect(streams.stderr).assertEqual('warn\n');
      expect(streams.exitCode).assertEqual(2);
      expect(new TimelineTool(streamsWire).resolvedExitCode()).assertEqual(2);
      expect(new TimelineTool(streamsWire).display!.header!.command).assertEqual('pwsh -c ls');

      // 退出码优先级：body → 顶层槽 → outcome。
      const textBody: Record<string, Object> = { 'kind': 'text', 'text': 'ok' };
      const nineOutcome: Record<string, Object> = { 'state': 'succeeded', 'exit_code': 9 };
      const textDisplay: Record<string, Object> = {
        'body': textBody, 'outcome': nineOutcome };
      const topOnly: Record<string, Object> = {
        'tool_call_id': 'c', 'name': 'exec', 'state': 'succeeded', 'exit_code': 7,
        'display': textDisplay };
      expect(new TimelineTool(topOnly).resolvedExitCode()).assertEqual(7);

      const outcomeOnly: Record<string, Object> = {
        'tool_call_id': 'c', 'name': 'exec', 'state': 'succeeded',
        'display': textDisplay };
      expect(new TimelineTool(outcomeOnly).resolvedExitCode()).assertEqual(9);
    });

    it('tool_without_display_falls_back_to_legacy_fields', 0, () => {
      // H16：display 缺失（自定义工具）必须完整回退扁平字段，不能丢块。
      const legacy: Record<string, Object> = {
        'tool_call_id': 'call_custom', 'name': 'custom_tool', 'state': 'succeeded',
        'summary': 'did a thing', 'args_json': '{"x":1}', 'output': 'plain output',
        'progress_stream': 'stderr', 'progress_bytes_total': 128, 'exit_code': 0
      };
      const tool: TimelineTool = new TimelineTool(legacy);
      expect(tool.display === undefined).assertTrue();
      expect(tool.output).assertEqual('plain output');
      expect(tool.argsText).assertEqual('{"x":1}');
      expect(tool.progressStream).assertEqual('stderr');
      expect(tool.progressBytesTotal).assertEqual(128);
      expect(tool.resolvedExitCode()).assertEqual(0);

      // 未知 header/body 变体不得抛：收下、标 unknown、由展示端兜底。
      const futureHeader: Record<string, Object> = { 'kind': 'quantum' };
      const futureBody: Record<string, Object> = { 'kind': 'hologram', 'weird': true };
      const futureDisplay: Record<string, Object> = {
        'header': futureHeader, 'body': futureBody };
      const future: Record<string, Object> = {
        'tool_call_id': 'c', 'name': 'x', 'state': 'succeeded', 'display': futureDisplay };
      const parsed: TimelineTool = new TimelineTool(future);
      expect(parsed.display!.header!.kind).assertEqual('quantum');
      expect(parsed.display!.body!.kind).assertEqual('hologram');
      expect(parsed.display!.body!.hasContent()).assertFalse();
    });
  });
}
