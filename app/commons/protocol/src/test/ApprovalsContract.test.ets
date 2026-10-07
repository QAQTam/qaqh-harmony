/**
 * 审批聚合面契约测试（M12）。
 *
 * 夹具镜像后端 axum_impl/challenge.rs 的 challenge view（device 形状）与
 * axum_impl/v2.rs 的 handle_pending_approvals_v2（admin canonical 形状）。
 * 核心契约：
 * - device 快照 `{challenges:[…]}`，challenge_id/kind 严格校验，details 原样保留
 *   （展示面容忍，畸形正文不响亮失败）；
 * - admin 快照 `{pending_permission, pending_interaction}` 归一化为同一条目形状
 *   （permission → tool_permission，respondId = tool_call_id / interaction id）；
 * - respond 请求体只含 challenge_id/decision/payload，decision 值域与后端
 *   command_for 同域。
 */

import { describe, it, expect } from '@ohos/hypium';

import { ProtocolError } from '../main/ets/wire/Json';
import { ApprovalKind, ApprovalDecision, RingingApprovalsSnapshot,
  RingingApprovalRespondRequest } from '../main/ets/wire/Approvals';

/** device 形状：permission + plan 两条 challenge（details 与 daemon 视图逐键一致）。 */
const DEVICE_CHALLENGES: string = '{"challenges":[' +
  '{"challenge_id":"' + 'a'.repeat(64) + '","kind":"tool_permission","expires_in":299,' +
  '"details":{"tool_name":"write_file","action_summary":null,"reason":"写入配置",' +
  '"paths":["/tmp/a.txt"],"category":"write","level":"standard","risk":"medium",' +
  '"consequence":"文件将被修改"}},' +
  '{"challenge_id":"' + 'b'.repeat(64) + '","kind":"plan","expires_in":120,' +
  '"details":{"plan_content":"# 计划","review_type":"plan"}}]}';

/** admin 形状：canonical 透传（id 形如 call_/int_）。 */
const ADMIN_PENDING: string = '{"pending_permission":{"tool_call_id":"call_01ABC",' +
  '"tool_name":"exec","action_summary":null,"reason":"跑测试","paths":[],' +
  '"category":"exec","level":"standard","risk":"high","consequence":"…",' +
  '"details_unavailable":false},' +
  '"pending_interaction":{"id":"int_01XYZ","kind":"ask",' +
  '"details":{"mode":"one_shot","questions":[{"id":"q1","question":"继续？",' +
  '"options":["是","否"],"allow_custom":false}]}}}';

const ADMIN_EMPTY: string = '{"pending_permission":null,"pending_interaction":null}';

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

export default function approvalsContractTest() {
  describe('approvals_contract', () => {
    it('approval_kind_wire_values_are_frozen', 0, () => {
      expect(ApprovalKind.TOOL_PERMISSION).assertEqual('tool_permission');
      expect(ApprovalKind.ASK).assertEqual('ask');
      expect(ApprovalKind.PLAN).assertEqual('plan');
      expect(ApprovalKind.isKnown('permission')).assertFalse();
      expect(ApprovalDecision.APPROVE).assertEqual('approve');
      expect(ApprovalDecision.DISMISS).assertEqual('dismiss');
    });

    it('device_challenge_snapshot_parses_and_keeps_details_raw', 0, () => {
      const snapshot: RingingApprovalsSnapshot = RingingApprovalsSnapshot.parse(DEVICE_CHALLENGES);
      expect(snapshot.items.length).assertEqual(2);
      const permission = snapshot.items[0];
      expect(permission.kind).assertEqual('tool_permission');
      expect(permission.respondId.length).assertEqual(64);
      expect(permission.expiresIn).assertEqual(299);
      // details 原样保留（含 null 值），畸形正文交给 UI 降级而不是解析器响亮失败。
      const details = permission.details as Record<string, Object>;
      expect(details['tool_name']).assertEqual('write_file');
      expect(details['risk']).assertEqual('medium');
      const plan = snapshot.items[1];
      expect(plan.kind).assertEqual('plan');
      expect(plan.respondId.length).assertEqual(64);
    });

    it('device_snapshot_rejects_unknown_kind_and_missing_challenge_id', 0, () => {
      // kind 非法 = 顶层形状错（响亮失败）；challenge_id 缺失走 Json 守卫的
      // missing_field（与其它 wire 契约同语义）。
      expectProtocolError('invalid_approvals_snapshot', () =>
        RingingApprovalsSnapshot.parse(
          '{"challenges":[{"challenge_id":"x","kind":"permission","expires_in":1}]}'));
      expectProtocolError('missing_field', () => RingingApprovalsSnapshot.parse(
        '{"challenges":[{"kind":"ask","expires_in":1}]}'));
      expectProtocolError('invalid_approvals_snapshot', () =>
        RingingApprovalsSnapshot.parse('{"challenges":{"challenge_id":"x"}}'));
    });

    it('admin_pending_snapshot_normalizes_to_same_item_shape', 0, () => {
      const snapshot: RingingApprovalsSnapshot = RingingApprovalsSnapshot.parse(ADMIN_PENDING);
      expect(snapshot.items.length).assertEqual(2);
      const permission = snapshot.items[0];
      expect(permission.kind).assertEqual('tool_permission');
      expect(permission.respondId).assertEqual('call_01ABC');
      const ask = snapshot.items[1];
      expect(ask.kind).assertEqual('ask');
      expect(ask.respondId).assertEqual('int_01XYZ');
      const details = ask.details as Record<string, Object>;
      expect(details['mode']).assertEqual('one_shot');
    });

    it('admin_empty_snapshot_parses_to_zero_items', 0, () => {
      const snapshot: RingingApprovalsSnapshot = RingingApprovalsSnapshot.parse(ADMIN_EMPTY);
      expect(snapshot.items.length).assertEqual(0);
    });

    it('admin_snapshot_missing_tool_call_id_fails_loud', 0, () => {
      expectProtocolError('invalid_approvals_snapshot', () =>
        RingingApprovalsSnapshot.parse(
          '{"pending_permission":{"tool_name":"exec"},"pending_interaction":null}'));
      expectProtocolError('invalid_approvals_snapshot', () =>
        RingingApprovalsSnapshot.parse(
          '{"pending_permission":null,"pending_interaction":{"id":"int_1","kind":"todo"}}'));
    });

    it('respond_request_serializes_id_decision_payload', 0, () => {
      const answers: Array<Object> = [];
      const answer: Record<string, Object> = { 'question_id': 'q1', 'answer': '是' };
      answers.push(answer);
      const payload: Record<string, Object> = { 'answers': answers };
      const submit: RingingApprovalRespondRequest =
        new RingingApprovalRespondRequest('ch-1', ApprovalDecision.SUBMIT, payload);
      expect(JSON.stringify(submit.toWire())).assertEqual(
        '{"challenge_id":"ch-1","decision":"submit","payload":{"answers":' +
        '[{"question_id":"q1","answer":"是"}]}}');
      const reject: RingingApprovalRespondRequest =
        new RingingApprovalRespondRequest('ch-1', ApprovalDecision.REJECT, undefined);
      expect(JSON.stringify(reject.toWire())).assertEqual(
        '{"challenge_id":"ch-1","decision":"reject"}');
      expect(RingingApprovalRespondRequest.validateDecision('approve')).assertTrue();
      expect(RingingApprovalRespondRequest.validateDecision('trust')).assertTrue();
      expect(RingingApprovalRespondRequest.validateDecision('maybe')).assertFalse();
    });
  });
}
