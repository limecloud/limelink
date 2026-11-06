#![cfg(unix)]
use limelink_runtime::agent::{codex, tools::ToolReply, Config, Job, Update, Workspace};
use serde_json::json;
use std::os::unix::fs::PermissionsExt;
use tokio::sync::{mpsc, watch};

async fn exercise(case: &str, resume: bool) -> Vec<Update> {
    let directory =
        std::env::temp_dir().join(format!("limelink-protocol-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let executable = directory.join("server");
    std::fs::write(&executable, include_bytes!("support/codex_fixture.py")).unwrap();
    std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
    let workspace = Workspace {
        id: "work".into(),
        name: "测试目录".into(),
        path: directory.clone(),
        allow_write: true,
    };
    let iot_enabled = case.starts_with("tool-") && case != "tool-disabled";
    let config = Config {
        executable,
        workspaces: vec![workspace.clone()],
        timeout_seconds: 30,
        allow_iot_tools: iot_enabled,
    };
    let job = Job {
        id: "run-test".into(),
        client: "client".into(),
        text: case.into(),
        workspace,
        sandbox: "read-only".into(),
        thread: resume.then(|| "resumed-thread".into()),
        config_digest: "fixture".into(),
        iot_devices: if iot_enabled {
            vec!["lamp-test".into()]
        } else {
            Vec::new()
        },
    };
    let (cancel, receiver) = watch::channel(false);
    let (sender, mut updates) = mpsc::channel(32);
    let task = tokio::spawn(codex::run(config, job, receiver, sender));
    let mut values = Vec::new();
    while let Some((id, value)) = updates.recv().await {
        assert_eq!(id, "run-test");
        if matches!(&value, Update::Session { .. }) && case.contains("interrupt") && !iot_enabled {
            // 让半行先进入读取器，再打断 read future。
            tokio::time::sleep(std::time::Duration::from_millis(80)).await;
            cancel.send(true).unwrap();
        }
        if let Update::Tool { call, reply } = &value {
            if case == "tool-interrupt" {
                cancel.send(true).unwrap();
            } else if case != "tool-complete-pending" {
                let output = if case == "tool-bad-result" {
                    json!({"device_id":"another-device"})
                } else if call.tool == "limeiot_read" {
                    json!({"device_id":"lamp-test","model_revision":format!("sha256:{}","a".repeat(64)),"ready":true,"properties":[]})
                } else {
                    json!({"device_id":"lamp-test","model_revision":format!("sha256:{}","a".repeat(64)),"path":"light.power","value":true,"command_id":"original-command","status":if case=="tool-unknown" {"unknown"}else{"confirmed"},"observed_at":if case=="tool-unknown" {None}else{Some("2026-11-06T00:00:00Z")}})
                };
                reply
                    .send(ToolReply {
                        call: if case == "tool-reply-mismatch" {
                            "unrelated".into()
                        } else {
                            call.call.clone()
                        },
                        success: case != "tool-unknown",
                        output,
                    })
                    .await
                    .unwrap();
            }
        }
        values.push(value);
    }
    task.await.unwrap();
    std::fs::remove_dir_all(directory).unwrap();
    values
}
fn terminal(values: &[Update]) -> (&str, Option<&str>) {
    match values.last().unwrap() {
        Update::Finished { state, error } => (state, error.as_deref()),
        _ => panic!("missing durable terminal"),
    }
}
#[tokio::test]
async fn start_resume_scoped_events_and_utf8_chunks() {
    for resume in [false, true] {
        let values = exercise("normal", resume).await;
        assert_eq!(terminal(&values), ("succeeded", None));
        let text: String = values
            .iter()
            .filter_map(|u| {
                if let Update::Event { text, .. } = u {
                    assert!(text.len() <= 400);
                    Some(text.as_str())
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(text, "真实协议夹具".repeat(100));
        assert!(values.iter().any(|v| matches!(v, Update::Session {thread, ..} if thread == if resume {"resumed-thread"}else{"thread-fixture"})));
    }
}
#[tokio::test]
async fn interrupt_requires_matching_turn_confirmation() {
    for case in ["interrupt", "partial-line-interrupt"] {
        assert_eq!(terminal(&exercise(case, false).await), ("cancelled", None));
    }
}
#[tokio::test]
async fn unconfirmed_interrupt_is_unknown() {
    assert_eq!(
        terminal(&exercise("interrupt-no-confirmation", false).await),
        ("unknown", Some("agent_interrupt_unknown"))
    );
}
#[tokio::test]
async fn lost_transport_and_wrong_turn_never_report_completion() {
    for (case, error) in [
        ("lost-before-turn-response", "agent_transport_lost"),
        ("wrong-turn", "agent_turn_mismatch"),
        ("oversized-line", "agent_protocol_budget"),
    ] {
        assert_eq!(
            terminal(&exercise(case, false).await),
            ("unknown", Some(error))
        );
    }
}

#[tokio::test]
async fn iot_tools_use_current_turn_and_return_only_checked_outputs() {
    for resume in [false, true] {
        let values = exercise("tool-read-command", resume).await;
        assert_eq!(terminal(&values), ("succeeded", None));
        assert_eq!(
            values
                .iter()
                .filter(|v| matches!(v, Update::Tool { .. }))
                .count(),
            2
        );
    }
}

#[tokio::test]
async fn disabled_foreign_or_out_of_scope_tools_do_not_reach_the_client() {
    for case in [
        "tool-disabled",
        "tool-wrong-target",
        "tool-foreign-request",
        "tool-namespace",
    ] {
        let values = exercise(case, false).await;
        assert_eq!(terminal(&values), ("succeeded", None), "{case}");
        assert!(
            !values.iter().any(|v| matches!(v, Update::Tool { .. })),
            "{case}"
        );
    }
}

#[tokio::test]
async fn interrupted_pending_or_unknown_iot_results_remain_unknown() {
    for case in ["tool-interrupt", "tool-complete-pending", "tool-unknown"] {
        assert_eq!(
            terminal(&exercise(case, false).await),
            ("unknown", Some("agent_tool_result_unknown")),
            "{case}"
        );
    }
}

#[tokio::test]
async fn replayed_calls_and_bad_results_are_never_accepted() {
    for (case, error) in [
        ("tool-replayed", "agent_tool_call_replayed"),
        ("tool-id-replayed", "agent_tool_request_replayed"),
        ("tool-reply-mismatch", "agent_tool_reply_mismatch"),
        ("tool-bad-result", "agent_tool_result_target_mismatch"),
        ("tool-budget", "agent_tool_budget"),
    ] {
        assert_eq!(
            terminal(&exercise(case, false).await),
            ("unknown", Some(error)),
            "{case}"
        );
    }
}
