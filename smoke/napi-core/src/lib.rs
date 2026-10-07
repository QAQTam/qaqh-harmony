//! M1' 工具链冒烟：qaqh-client core + NAPI 双向调用。
//! ① core 类型在 ohos 目标可用 ② 链接出 .so ③ JS↔Rust 调用面。

use napi_derive::napi;

// 触碰 core 的真实类型：open 响应解析（wire contract）。
use qaqh_ringing::v2::RingingV2OpenResponse;

#[napi(object)]
pub struct SmokeProbe {
    pub version: u32,
    pub server_epoch: String,
    pub lease_ttl_ms: f64,
}

#[napi]
pub fn parse_open_response(text: String) -> napi::Result<SmokeProbe> {
    let parsed: RingingV2OpenResponse = serde_json::from_str(&text)
        .map_err(|e| napi::Error::from_reason(format!("parse failed: {e}")))?;
    Ok(SmokeProbe {
        version: parsed.version,
        server_epoch: parsed.server_epoch,
        lease_ttl_ms: parsed.lease_ttl_ms as f64,
    })
}

#[napi]
pub fn echo(greeting: String) -> String {
    format!("qaqh-napi-smoke: {greeting}")
}
