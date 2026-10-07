# OHOS 工具链冒烟报告（2026-10-05）

对应 `E:\qaqh-backend\docs\plan-mobile-remote-access.md` §9 守门点：
「`aarch64-unknown-linux-ohos` + napi-rs 的 CI 矩阵是新增维护面，M1' 排期前先做
工具链冒烟（core 编译过 + NAPI 双向调用通）」。

## 结果

| 项 | 结论 |
|---|---|
| ① qaqh-client core 交叉编译 | ✅ `cargo check`（27s）+ 完整 `cargo build`（含链接）通过，reqwest/tokio/rustls 全依赖树在 ohos 目标无阻塞 |
| ② 最小 NAPI 绑定出 .so | ✅ `smoke/napi-core`（napi-rs v3）链接出 `libqaqh_napi_smoke.so`，ELF aarch64，导出标准入口 `napi_register_module_v1`；内含对 `qaqh_ringing::v2::RingingV2OpenResponse` 的真实解析调用 |
| ③ 运行时双向调用 | ⏸ 未做——`hdc list targets` 为空，无真机/模拟器。设备接入后在一个最小 HAP 里 `import testNapi from 'libqaqh_napi_smoke.so'` 调 `echo()`/`parseOpenResponse()` 即闭环（装 HAP 需签名，`devecocli auth login` 那步本来就要用户操作） |

## 落地物

- `E:\qaqh-backend\.cargo\config.toml`：新增 `[target.aarch64-unknown-linux-ohos]` 链接器配置；
  `E:\qaqh-backend\.cargo\ohos-clang.cmd`：包装 CLT 自带 LLVM（`-target aarch64-linux-ohos --sysroot … -D__MUSL__`）。
  CLT 路径写死在 `E:\qaqh-harmony\commandline-tools-windows-x64-6.1.1.418\...`。
- `E:\qaqh-harmony\smoke\napi-core\`：冒烟 crate（napi 3 + napi-derive 3 + qaqh-client/qaqh-ringing path 依赖），
  自带 `.cargo/config.toml`（CC/AR/链接器，`[env]` 方式，免环境变量）。
- 工具链：rustup stable 1.99.0 + `rustup target add aarch64-unknown-linux-ohos`（本机此前无任何工具链）。

## 发现的一个真问题：TLS provider（aws-lc-rs 不适合 ohos 路径）

reqwest 0.13 的 `rustls` feature 硬绑 **aws-lc-rs**，而 `aws-lc-sys`：
1. 需要 cmake（本机没有，直接断在 build script）；
2. 即使装了 cmake，aws-lc 的 C/asm 在 ohos 目标上属无人维护路径，脆弱。

已把 `crates/qaqh-client/Cargo.toml` 改为 ring provider（**此改动留在后端工作区，待后端定夺**）：

```toml
reqwest = { version = "0.13.4", default-features = false, features = ["json", "stream", "rustls-no-provider", "query"] }
rustls = { version = "0.23", default-features = false, features = ["ring", "logging", "std", "tls12"] }
```

验证：宿主机 Windows 构建 `cargo check -p qaqh-client` 照常通过（ring 成为唯一 provider，
rustls 自动选它，宿主行为不变）。若后端只想要 ohos 走 ring、宿主保持 aws-lc，
可改成 target 门控：`[target.'cfg(target_os = "ohos")'.dependencies]` 单独给 ring 版 rustls。

## 结论

冒烟目标 ①② 达成，工具链路线（Rust core + napi-rs + CLT LLVM）**可行**，
napi-rs v3 上游直接支持 ohos target，不需要 ohos-rs 分叉。
剩下的 ③（真机调用）只是验收动作，无技术悬念。
建议按 plan §5.1 走共享 Rust core 路线：鸿蒙侧投入转向 NAPI 绑定 + 原生件
（扫码/HUKS/长时任务/通知/ArkUI），`@qaqh/client`（ArkTS）冻结在 M1 现状作为对拍基线。
