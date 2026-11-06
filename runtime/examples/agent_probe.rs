//! 仅用显式可执行文件与隔离目录验收真实适配器，不载入用户项目内容。
use limelink_runtime::agent::{codex, Config, Job, Update, Workspace};
use serde_json::json;
use tokio::sync::{mpsc, watch};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = std::env::args_os().skip(1);
    let executable = arguments.next().ok_or("missing_executable")?.into();
    let path = std::path::PathBuf::from(arguments.next().ok_or("missing_isolated_workspace")?)
        .canonicalize()?;
    if path.read_dir()?.next().is_some() {
        return Err("workspace_must_be_empty".into());
    }
    let workspace = Workspace {
        id: "probe".into(),
        name: "隔离验收".into(),
        path,
        allow_write: false,
    };
    let config = Config {
        executable,
        workspaces: vec![workspace.clone()],
        timeout_seconds: 60,
        allow_iot_tools: false,
    }
    .validate()?;
    let job=Job{id:"live-probe".into(),client:"local-probe".into(),text:"Reply with exactly LIMELINK_AGENT_OK. Do not use tools, read files, or access any external resource.".into(),workspace,sandbox:"read-only".into(),thread:None,config_digest:"probe".into(),iot_devices:Vec::new()};
    let (_cancel, receiver) = watch::channel(false);
    let (sender, mut updates) = mpsc::channel(32);
    let task = tokio::spawn(codex::run(config, job, receiver, sender));
    let mut output = String::new();
    let mut state = String::new();
    let mut error = None;
    while let Some((_, value)) = updates.recv().await {
        match value {
            Update::Event { kind, text } if kind == "message" => output.push_str(&text),
            Update::Finished { state: s, error: e } => {
                state = s;
                error = e;
            }
            _ => {}
        }
    }
    task.await?;
    let passed = state == "succeeded" && output.trim() == "LIMELINK_AGENT_OK";
    println!(
        "{}",
        json!({"scope":"真实 Codex App Server，空目录，固定非敏感输入，无工具任务","passed":passed,"state":state,"error":error,"expected_reply":output.trim()=="LIMELINK_AGENT_OK","fixture":false})
    );
    if !passed {
        std::process::exit(1);
    }
    Ok(())
}
