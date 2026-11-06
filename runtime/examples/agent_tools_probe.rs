//! 真实模型与合成设备结果的协议探针；不连接网关、不执行真实设备操作。
use limelink_runtime::agent::{codex, tools::ToolReply, Config, Job, Update, Workspace};
use serde_json::json;
use tokio::sync::{mpsc, watch};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args_os().skip(1);
    let executable = args.next().ok_or("missing_executable")?.into();
    let path = std::path::PathBuf::from(args.next().ok_or("missing_isolated_workspace")?)
        .canonicalize()?;
    if args.next().is_some() || path.read_dir()?.next().is_some() {
        return Err("workspace_must_be_empty".into());
    }
    let workspace = Workspace {
        id: "probe".into(),
        name: "隔离协议验收".into(),
        path,
        allow_write: false,
    };
    let config = Config {
        executable,
        workspaces: vec![workspace.clone()],
        timeout_seconds: 120,
        allow_iot_tools: true,
    }
    .validate()?;
    let mut thread = None;
    let mut counts = Vec::new();
    for index in 0..2 {
        let prompt = if index == 0 {
            "This is a synthetic protocol check. Use limeiot_read exactly once for device_id lamp-probe. Then use limeiot_command exactly once for lamp-probe, using the returned model_revision, path light.power, value true. The host supplies synthetic results; there is no real device. Do not use other tools or read files. If both calls succeed, reply exactly LIMELINK_IOT_TOOLS_OK."
        } else {
            "This is a synthetic protocol resume check. Use the same limeiot_read tool exactly once for lamp-probe. Do not use other tools or read files. If it succeeds, reply exactly LIMELINK_IOT_RESUME_OK."
        };
        let job = Job {
            id: format!("tools-probe-{index}"),
            client: "local-probe".into(),
            text: prompt.into(),
            workspace: workspace.clone(),
            sandbox: "read-only".into(),
            thread: thread.clone(),
            config_digest: "probe".into(),
            iot_devices: vec!["lamp-probe".into()],
        };
        let (_cancel, receiver) = watch::channel(false);
        let (sender, mut updates) = mpsc::channel(32);
        let task = tokio::spawn(codex::run(config.clone(), job, receiver, sender));
        let mut calls = Vec::new();
        let mut final_message = String::new();
        let mut state = String::new();
        let mut error = None;
        while let Some((_, value)) = updates.recv().await {
            match value {
                Update::Session { thread: next, .. } => {
                    if thread.as_ref().is_some_and(|old| *old != next) {
                        return Err("probe_session_changed".into());
                    }
                    thread = Some(next);
                }
                Update::Event { kind, text: part } if kind == "message" => final_message = part,
                Update::Tool { call, reply } => {
                    calls.push(call.tool.clone());
                    let revision = format!("sha256:{}", "a".repeat(64));
                    let output = if call.tool == "limeiot_read" {
                        json!({"device_id":"lamp-probe","model_revision":revision,"ready":true,"properties":[{"path":"light.power","value":false,"schema":{"type":"boolean"},"writable":true,"observed_at":"2026-11-06T00:00:00Z","quality":"good"}]})
                    } else {
                        json!({"device_id":"lamp-probe","model_revision":revision,"path":"light.power","value":true,"command_id":"synthetic-command","status":"confirmed","observed_at":"2026-11-06T00:00:00Z"})
                    };
                    reply
                        .send(ToolReply {
                            call: call.call,
                            success: true,
                            output,
                        })
                        .await?;
                }
                Update::Finished {
                    state: next,
                    error: next_error,
                } => {
                    state = next;
                    error = next_error;
                }
                _ => {}
            }
        }
        task.await?;
        let expected = if index == 0 {
            vec!["limeiot_read", "limeiot_command"]
        } else {
            vec!["limeiot_read"]
        };
        let marker = if index == 0 {
            "LIMELINK_IOT_TOOLS_OK"
        } else {
            "LIMELINK_IOT_RESUME_OK"
        };
        let passed = state == "succeeded"
            && error.is_none()
            && calls == expected
            && final_message.trim() == marker;
        // 协议包含执行前进度文字，验证最后一条回复，不能把进度与最终答案拼接比较。
        counts.push(json!({"resumed":index==1,"passed":passed,"state":state,"error":error,"calls":calls,"expected_reply":final_message.trim()==marker}));
        if !passed {
            println!(
                "{}",
                json!({"passed":false,"real_model":true,"real_gateway":false,"synthetic_device_results":true,"runs":counts})
            );
            std::process::exit(1);
        }
    }
    println!(
        "{}",
        json!({"passed":true,"real_model":true,"real_gateway":false,"synthetic_device_results":true,"scope":"真实 Codex 动态工具调用与会话恢复；设备结果为合成夹具，不证明网关、授权界面或真实设备可用","runs":counts})
    );
    Ok(())
}
