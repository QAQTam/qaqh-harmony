#!/usr/bin/env bash
# Ringing v2 wire 冒烟：对**真 daemon** 逐条打鸿蒙客户端用到的上行面，断言状态码
# 与关键字段。存在的意义是防后端改造期的契约漂移——M0 的命令信封漏 channel、
# M5.1 的 not_driver 空 command_id 这类坑，假件契约测试永远发现不了。
#
# 用法：
#   scripts/wire-smoke.sh                          # 默认 60.0.0.65:64413 + token 11
#   BASE=https://ip:port TOKEN=xx CA=/path/cert.pem scripts/wire-smoke.sh
# 非回环 bind 的 daemon 是 HTTPS（自签证书在 <数据根>/tls/cert.pem），这里按标准
# 主机名校验打——证书 SAN 必须含服务端 IP，否则本脚本第一步就会报 SSL 错误。
set -uo pipefail

BASE="${BASE:-https://60.0.0.65:64413}"
TOKEN="${TOKEN:-11}"
CA="${CA:-$HOME/.qaqh/tls/cert.pem}"
DEVICE_NAME="${DEVICE_NAME:-harmony-wire-smoke}"
PY="${PY:-python}"
PASS=0
FAIL=0
CSID=''

if [[ ! -f "$CA" ]]; then
  echo "wire-smoke: 找不到证书 $CA（用 CA=... 指定，或先起 daemon）" >&2
  exit 2
fi

# json <body> <python 表达式，data 为解析结果> -> 打印结果（异常时打印空串）
json() {
  $PY -c '
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
try:
    print(eval(sys.argv[2], {"data": data, "json": json}))
except Exception:
    pass
' "$1" "$2" 2>/dev/null
}

# request <method> <path> <bearer|-> [body] —— 输出 "<status>\n<body>"
request() {
  local method="$1" path="$2" bearer="$3" body="${4:-}"
  local args=(-s -m 10 -X "$method" --cacert "$CA" "$BASE$path"
    -H 'Content-Type: application/json' -w $'\n%{http_code}')
  [[ "$bearer" != '-' ]] && args+=(-H "Authorization: Bearer $bearer")
  [[ -n "$CSID" ]] && args+=(-H "X-QAQH-Client-Session-Id: $CSID")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}"
}

# send <name> <expect_status> <method> <path> <bearer> [body]；结果置 STATUS/BODY
send() {
  local name="$1" expect="$2" method="$3" path="$4" bearer="$5" body="${6:-}"
  local response status out
  response="$(request "$method" "$path" "$bearer" "$body")"
  status="${response##*$'\n'}"
  out="${response%$'\n'*}"
  STATUS="$status"
  BODY="$out"
  if [[ "$status" == "$expect" ]]; then
    PASS=$((PASS + 1))
    printf '  ok   %-44s %s\n' "$name" "$status"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %-44s want=%s got=%s body=%.240s\n' "$name" "$expect" "$status" "$out"
  fi
}

expect_field() { # expect_field <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1))
    printf '  ok   %-44s %s\n' "$1" "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %-44s want=%s got=%s\n' "$1" "$2" "$3"
  fi
}

expect_bool() { # expect_bool <name> <expected true|false> <python 表达式>
  local actual
  actual="$(json "$BODY" "$3")"
  case "$actual" in
    True|true) actual=true ;;
    False|false) actual=false ;;
  esac
  expect_field "$1" "$2" "$actual"
}

note() { printf '       %s\n' "$1"; }

# 租约 TTL 只有 30s，而两条订阅要跑完一次真实模型往返再撑到吊销验证。
# 静默续期，不计断言（吊销之后另有 renew_after_revoke 断言 401，那时须先停）。
quiet_renew() {
  curl -s -m 6 --cacert "$CA" -X POST "$BASE/ringing/v2/leases/renew" \
    -H "Authorization: Bearer $DEVICE_TOKEN" \
    -H "X-QAQH-Client-Session-Id: $CSID_A" >/dev/null 2>&1 || true
}

echo "== wire-smoke @ $BASE (ca=$CA)"

# ---- 传输与鉴权面 ----
send health_public 200 GET /health -
send no_token_rejected 401 GET "/ringing/v2/sessions/none/bootstrap" -

# ---- admin 侧：open + 签发配对令牌 ----
send admin_open 200 POST /ringing/v2/clients/open "$TOKEN" \
  '{"schema":"qaqh.Ringing","version":2,"client_instance_id":"smoke-admin"}'
ADMIN_CSID="$(json "$BODY" "data['client_session_id']")"
CSID="$ADMIN_CSID"
expect_field admin_caps_pairing true "$(json "$BODY" "str(data['capabilities']['pairing']).lower()")"

send pairing_token_issue 200 POST /ringing/v2/pairing/tokens "$TOKEN" \
  "{\"scope_grant\":\"interact\",\"device_name\":\"$DEVICE_NAME\",\"platform\":\"harmony\"}"
PAIRING_TOKEN="$(json "$BODY" "data['pairing_token']")"
note "tls_fp=$(json "$BODY" "data['tls_fp']")  pairing_token=${PAIRING_TOKEN:0:8}…（52 位=2×ULID）"

# 配对令牌只能被消费一次；先给第二个设备留一份，用于归属门禁取证。
send pairing_token_issue_second 200 POST /ringing/v2/pairing/tokens "$TOKEN" \
  "{\"scope_grant\":\"interact\",\"device_name\":\"$DEVICE_NAME-b\",\"platform\":\"harmony\"}"
PAIRING_TOKEN_B="$(json "$BODY" "data['pairing_token']")"

# ---- 设备侧：免 Bearer 配对（/pair 属公开面） ----
CSID=''
send pair_ok 200 POST /ringing/v2/pair - \
  "{\"pairing_token\":\"$PAIRING_TOKEN\",\"device_name\":\"$DEVICE_NAME\",\"platform\":\"harmony\"}"
DEVICE_TOKEN="$(json "$BODY" "data['device_token']")"
DEVICE_ID="$(json "$BODY" "data['device_id']")"
expect_field pair_scope interact "$(json "$BODY" "data['scope']")"
note "device_id=$DEVICE_ID"

send pair_replay_rejected 403 POST /ringing/v2/pair - \
  "{\"pairing_token\":\"$PAIRING_TOKEN\",\"device_name\":\"x\",\"platform\":\"harmony\"}"
expect_field pair_replay_code pairing_used "$(json "$BODY" "data['code']")"

send pair_bogus_rejected 403 POST /ringing/v2/pair - \
  '{"pairing_token":"01BOGUS0000000000000000000BOGUS00000000000000000000000","device_name":"x","platform":"harmony"}'

# 归属由「谁创建/谁 attach」决定，因此用第二个设备来取证：它对同一会话未
# attach 前必须 403 forbidden_not_owner（admin 豁免，本端不豁免）。
send pair_second 200 POST /ringing/v2/pair - \
  "{\"pairing_token\":\"$PAIRING_TOKEN_B\",\"device_name\":\"$DEVICE_NAME-b\",\"platform\":\"harmony\"}"
DEVICE_TOKEN_B="$(json "$BODY" "data['device_token']")"
DEVICE_ID_B="$(json "$BODY" "data['device_id']")"

# ---- 设备 open：lease 以 device_id 登记，自报 instance 仅诊断 ----
send device_open 200 POST /ringing/v2/clients/open "$DEVICE_TOKEN" \
  '{"schema":"qaqh.Ringing","version":2,"client_instance_id":"harmony-self-reported"}'
CSID="$(json "$BODY" "data['client_session_id']")"
CSID_A="$CSID"

send device_open_second 200 POST /ringing/v2/clients/open "$DEVICE_TOKEN_B" \
  '{"schema":"qaqh.Ringing","version":2,"client_instance_id":"harmony-self-reported-b"}'
CSID_B="$(json "$BODY" "data['client_session_id']")"

# 信封必须顶层 channel + command.channel 并存（M0 埋雷，真机首日暴露过）。
envelope() { # envelope <channel> <command-id> <session-id> <command-json>
  printf '{"schema":"qaqh.Ringing","version":2,"channel":"%s","command_id":"%s","client_instance_id":"%s","client_session_id":"%s"%s,"command":%s}' \
    "$1" "$2" "$DEVICE_ID" "$CSID" "$( [[ -n "$3" ]] && printf ',"session_id":"%s"' "$3" )" "$4"
}

# 鸿蒙侧 newCommandId() 同款 ULID 形态（26 位大写 Crockford），后端原样进因果链。
ULID() { $PY -c '
import time, os
A = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
value = int(time.time() * 1000)
head = ""
for _ in range(10):
    head = A[value % 32] + head
    value //= 32
print(head + "".join(A[b % 32] for b in os.urandom(16)), end="")'; }

send device_session_create 200 POST /ringing/v2/commands/control "$DEVICE_TOKEN" \
  "$(envelope control "$(ULID)" '' '{"channel":"control","type":"session_create","close_current":false}')"

send device_session_list 200 POST /ringing/v2/service/session.list "$DEVICE_TOKEN" '{}'
SESSION_ID="$(json "$BODY" "data[0]['session_id'] if data else ''")"
note "session_id=$SESSION_ID"

# ---- 归属只由 session_attach 建立：第二个设备未 attach 直接读会话必须 403 ----
CSID="$CSID_B"
send bootstrap_before_attach 403 GET "/ringing/v2/sessions/$SESSION_ID/bootstrap" "$DEVICE_TOKEN_B"
expect_field bootstrap_before_attach_code forbidden_not_owner "$(json "$BODY" "data.get('code','')")"
# 未 attach 的设备既看不到 event 流，也读不到正文（同一道归属门禁；
# timeline 侧返回 401 lease_required，与 bootstrap 的 403 不同码，别混）。
send events_before_attach 403 GET "/ringing/v2/sessions/$SESSION_ID/events" "$DEVICE_TOKEN_B"
send timeline_before_attach 401 GET "/ringing/v2/sessions/$SESSION_ID/timeline?limit=2" "$DEVICE_TOKEN_B"

CSID="$CSID_B"
send session_attach 200 POST /ringing/v2/commands/control "$DEVICE_TOKEN_B" \
  "{\"schema\":\"qaqh.Ringing\",\"version\":2,\"channel\":\"control\",\"command_id\":\"$(printf 'A%s' "$(ULID)" | cut -c1-26)\",\"client_instance_id\":\"$DEVICE_ID_B\",\"client_session_id\":\"$CSID_B\",\"session_id\":\"$SESSION_ID\",\"command\":{\"channel\":\"control\",\"type\":\"session_attach\",\"session_id\":\"$SESSION_ID\"}}"

send bootstrap_after_attach 200 GET "/ringing/v2/sessions/$SESSION_ID/bootstrap" "$DEVICE_TOKEN_B"
expect_bool bootstrap_has_snapshot_cursor true "'snapshot_cursor' in data"

# ---- 会话列表按归属过滤（attach 后才可见） ----
send device_session_list_after_attach 200 POST /ringing/v2/service/session.list "$DEVICE_TOKEN" '{}'
expect_field session_visible_after_attach "$SESSION_ID" \
  "$(json "$BODY" "data[0]['session_id'] if data else ''")"

# ---- Timeline 通道：正文与历史在这里，**不在** /events（真机定性） ----
CSID="$CSID_A"
send timeline_snapshot 200 GET "/ringing/v2/sessions/$SESSION_ID/timeline?limit=2" "$DEVICE_TOKEN"
expect_bool timeline_has_watermark true "isinstance(data['snapshot'].get('watermark'), int)"
expect_bool timeline_has_total true "isinstance(data.get('total_turns'), int)"

TL_FILE="${TL_FILE:-/tmp/qaqh-wire-timeline.txt}"
rm -f "$TL_FILE"
curl -N -s -m 40 --cacert "$CA" \
  -H "Authorization: Bearer $DEVICE_TOKEN" \
  -H "X-QAQH-Client-Session-Id: $CSID_A" \
  -H 'Accept: text/event-stream' \
  "$BASE/ringing/v2/sessions/$SESSION_ID/timeline/events" > "$TL_FILE" 2>&1 &
TL_PID=$!

# 投影单流也在同一时刻挂上：与 timeline 同拍对照，才能断言「正文只在 timeline」。
SSE_FILE="${SSE_FILE:-/tmp/qaqh-wire-sse.txt}"
rm -f "$SSE_FILE"
curl -N -s -m 90 --cacert "$CA" \
  -H "Authorization: Bearer $DEVICE_TOKEN" \
  -H "X-QAQH-Client-Session-Id: $CSID_A" \
  -H 'Accept: text/event-stream' \
  "$BASE/ringing/v2/sessions/$SESSION_ID/events" > "$SSE_FILE" 2>&1 &
SSE_PID=$!

# 租约 TTL 只有 30s，而两条流要跑完一次真实模型往返再撑到吊销验证。
# 保活循环 6s 一次；吊销前必须停掉，否则后面的 renew_after_revoke 断言会被抢跑。
( while :; do sleep 6; quiet_renew; done ) &
KEEPALIVE_PID=$!
sleep 2

# ---- ACK 原样回显提交的 command_id（ULID 车道不派生） ----
# 设备 A 的 token 必须配设备 A 的 client_session_id：串到 B 的 cs 会被判无 lease
# （身份由 token 反推，见 caller_lease_bound_to_identity）。
CSID="$CSID_A"
PROBE_ID="$(ULID)"
send conversation_send 200 POST /ringing/v2/commands/conversation "$DEVICE_TOKEN" \
  "$(envelope conversation "$PROBE_ID" "$SESSION_ID" \
    '{"channel":"conversation","type":"conversation_send_message","text":"wire smoke"}')"
expect_field ack_echoes_ulid_command_id "$PROBE_ID" "$(json "$BODY" "data['command_id']")"

send command_status 200 GET "/ringing/v2/commands/$PROBE_ID" "$DEVICE_TOKEN"
note "state=$(json "$BODY" "data['state']")"

# KNOWN-GAP（后端）：`/leases/renew` 只做 `is_active_session`，未过
# `caller_lease_bound_to_identity`——A 的 token 配 B 的 client_session_id 仍能续
# B 的租约（其余面如 commands/bootstrap/events 都已绑身份）。这里记录现状而非
# 断言 401：v2.rs:129 handle_renew_v2 补身份绑定后，把期望改回 401 即可。
CSID="$CSID_B"
send cross_identity_renew_current_behaviour 200 POST /ringing/v2/leases/renew "$DEVICE_TOKEN" ''
CSID="$CSID_A"

# ---- 驱动席专用端点 ----
send driver_claim 200 POST "/ringing/v2/sessions/$SESSION_ID/driver/claim" "$DEVICE_TOKEN" ''
note "accepted=$(json "$BODY" "str(data.get('accepted')).lower()") reason=$(json "$BODY" "data.get('reason','')")"

send lease_renew 200 POST /ringing/v2/leases/renew "$DEVICE_TOKEN" ''
expect_bool lease_renew_ok true "data['ok']"

# 席位交接是异步的：claim 之后 release 一次，DriverChanged 一定会落一条。
send driver_release 200 POST "/ringing/v2/sessions/$SESSION_ID/driver/release" "$DEVICE_TOKEN" ''

# ---- Timeline 增量：正文只在这条通道上（/events 里没有 text_delta） ----
wait "$TL_PID" 2>/dev/null || true
if grep -q 'event: timeline.entry' "$TL_FILE"; then
  PASS=$((PASS + 1))
  printf '  ok   %-44s %s frames\n' 'timeline_events_stream_delivers' "$(grep -c '^event: timeline.entry' "$TL_FILE")"
else
  FAIL=$((FAIL + 1)); printf '  FAIL %-44s body=%.200s\n' 'timeline_events_stream_delivers' "$(tr -d '\n' < "$TL_FILE")"
fi
# 游标形态必须是 `{epoch}:timeline:{seq}`，否则续传参数会被 daemon 判不可用并全量重放。
if grep -qE '^id: [0-9a-f]{6,}:timeline:[0-9]+$' "$TL_FILE"; then
  PASS=$((PASS + 1)); printf '  ok   %-44s epoch:timeline:seq\n' 'timeline_cursor_shape'
else
  FAIL=$((FAIL + 1)); printf '  FAIL %-44s no usable id: line\n' 'timeline_cursor_shape'
fi
# KNOWN-GAP（后端）：`handle_timeline_snapshot` 回填的 `turn_index` 会被
# `rehydrate_timeline_page` 整体替换掉（实测整页为 null），深翻页游标因此不可
# 依赖；客户端用 `total_turns - 页长` 兜底（Timeline.oldestIndex）。这里只如实
# 报告有无，不判红绿——补上后端再把它变成断言。
send timeline_probe 200 GET "/ringing/v2/sessions/$SESSION_ID/timeline?limit=2" "$DEVICE_TOKEN"
note "turn_index 缺失的回合数：$(json "$BODY" "sum(1 for t in data['snapshot']['turns'] if 'turn_index' not in t)")/$(json "$BODY" "len(data['snapshot']['turns'])")"

# ---- 吊销：Admin 面 + 设备侧 lease 立即失效 ----
kill "$KEEPALIVE_PID" 2>/dev/null || true
# 投影流早在发送前就挂着（同拍对照）：后端逐事件复查租约，撤销即下发
# ringing.stream_terminated 后断流——鸿蒙两条流都必须认这个帧名。

CSID="$ADMIN_CSID"
send devices_list 200 GET /ringing/v2/devices "$TOKEN"
expect_bool devices_contains_device true "any(d['device_id']=='$DEVICE_ID' for d in data['devices'])"

send device_revoke 204 POST "/ringing/v2/devices/$DEVICE_ID/revoke" "$TOKEN" ''
# 设备 B 也收掉：留着会污染真实 daemon 的设备注册表（每台跑一次多一条）。
send device_revoke_b 204 POST "/ringing/v2/devices/$DEVICE_ID_B/revoke" "$TOKEN" ''
# 服务端 15s 一次 keepalive 复查租约：吊销后最迟一个 keepalive 周期出终止帧。
sleep 18
wait "$SSE_PID" 2>/dev/null || true

if grep -q 'event: ringing.event' "$SSE_FILE"; then
  PASS=$((PASS + 1)); printf '  ok   %-44s %s\n' 'sse_delivers_ringing_event' "$(grep -c '^event: ringing.event' "$SSE_FILE") frames"
else
  FAIL=$((FAIL + 1)); printf '  FAIL %-44s body=%.240s\n' 'sse_delivers_ringing_event' "$(tr -d '\n' < "$SSE_FILE")"
fi
if grep -q 'event: ringing.stream_terminated' "$SSE_FILE"; then
  PASS=$((PASS + 1)); printf '  ok   %-44s revoked frame seen\n' 'sse_stream_terminated_on_revoke'
else
  FAIL=$((FAIL + 1)); printf '  FAIL %-44s no terminated frame after revoke\n' 'sse_stream_terminated_on_revoke'
fi
# 席位交接是会话 actor 异步落地的：同一脚本两次跑出过「8 帧里有 driver_changed」
# 和「一次都没有」。所以这里只如实报告，不判红绿——`driver_changed` 的**线形**
# 由协议层单测钉住（ProtocolContract: driver_changed_delta_parses），那才是断的地方。
if grep -q '"kind":"driver_changed"' "$SSE_FILE"; then
  note "driver_changed 出现在投影单流：$(grep -c '"kind":"driver_changed"' "$SSE_FILE") 帧"
else
  note "本轮投影单流没有出现 driver_changed（席位交接异步，非断言项）"
fi

CSID="$CSID_A"
send renew_after_revoke 401 POST /ringing/v2/leases/renew "$DEVICE_TOKEN" ''
send reopen_after_revoke 401 POST /ringing/v2/clients/open "$DEVICE_TOKEN" \
  '{"schema":"qaqh.Ringing","version":2,"client_instance_id":"harmony-retry"}'

echo "== pass=$PASS fail=$FAIL"
[[ "$FAIL" -eq 0 ]]
