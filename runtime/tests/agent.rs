use limelink_runtime::{
    agent::{
        tools::{self, ToolCall},
        AgentStore, Config, Update, Workspace,
    },
    Exchange, Store,
};
use ring::{
    rand::SystemRandom,
    signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_ASN1_SIGNING},
};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
const SPACE: &str = "space-demo";
const DEVICE: &str = "desktop-test";
const REV: &str = "sha256:test";
fn config() -> Config {
    Config {
        executable: std::env::current_exe().unwrap(),
        workspaces: vec![Workspace {
            id: "work".into(),
            name: "测试目录".into(),
            path: std::env::current_dir().unwrap(),
            allow_write: true,
        }],
        timeout_seconds: 30,
        allow_iot_tools: false,
    }
}
fn key() -> EcdsaKeyPair {
    let rng = SystemRandom::new();
    let pk = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &rng).unwrap();
    EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, pk.as_ref(), &rng).unwrap()
}
fn input(key: &EcdsaKeyPair, client: &str, kind: &str, payload: Value, now: i64) -> Exchange {
    let mut e = Exchange {
        client_id: client.into(),
        public_key: hex::encode(key.public_key().as_ref()),
        kind: kind.into(),
        nonce: uuid::Uuid::new_v4().to_string(),
        expires_at: now + 20,
        payload: payload.to_string(),
        signature: String::new(),
    };
    e.signature = hex::encode(
        key.sign(&SystemRandom::new(), &e.message(SPACE, DEVICE, REV))
            .unwrap()
            .as_ref(),
    );
    e
}
fn paired(k: &EcdsaKeyPair, c: &str) -> Store {
    let mut s = Store::open(Path::new(":memory:"), "test").unwrap();
    s.execute(
        "pair",
        &input(k, c, "pair", json!({"name":"手机"}), 100),
        SPACE,
        DEVICE,
        REV,
        100,
    )
    .unwrap();
    s.approve(c, true, 101).unwrap();
    s
}
fn response(v: Value) -> Value {
    serde_json::from_str(v["evidence"]["output"]["response"].as_str().unwrap()).unwrap()
}
fn action(
    s: &mut AgentStore,
    p: &Store,
    k: &EcdsaKeyPair,
    c: &str,
    kind: &str,
    payload: Value,
    now: i64,
) -> Value {
    response(
        s.execute(
            &uuid::Uuid::new_v4().to_string(),
            &input(k, c, kind, payload, now),
            p,
            SPACE,
            DEVICE,
            REV,
            now,
        )
        .unwrap(),
    )
}
fn submit(id: &str) -> Value {
    json!({"id":id,"workspace_id":"work","text":"读取目录并说明用途","sandbox":"workspace-write"})
}
fn memory() -> AgentStore {
    AgentStore::open(Path::new(":memory:"), "test", config(), 100).unwrap()
}

#[test]
fn pairing_does_not_grant_agent_execution() {
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = memory();
    let id = uuid::Uuid::new_v4().to_string();
    assert_eq!(
        action(&mut s, &p, &k, &c, "agent.submit", submit(&id), 102)["value"]["state"],
        "awaiting_approval"
    );
    assert!(s.next(&p, 103).unwrap().is_none());
    s.approve(&id, true, 104).unwrap();
    assert_eq!(s.next(&p, 105).unwrap().unwrap().id, id);
    assert!(s.next(&p, 106).unwrap().is_none());
    assert!(s.approve(&id, true, 106).is_err());
}
#[test]
fn original_run_and_command_are_not_restarted() {
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = memory();
    let id = uuid::Uuid::new_v4().to_string();
    let e = input(&k, &c, "agent.submit", submit(&id), 102);
    let first = s
        .execute("original", &e, &p, SPACE, DEVICE, REV, 102)
        .unwrap();
    assert_eq!(
        s.execute("original", &e, &p, SPACE, DEVICE, REV, 200)
            .unwrap(),
        first
    );
    assert_eq!(
        s.execute("replay", &e, &p, SPACE, DEVICE, REV, 103)
            .unwrap_err(),
        "nonce_replayed"
    );
    assert_eq!(
        action(&mut s, &p, &k, &c, "agent.submit", submit(&id), 103)["value"]["id"],
        id
    );
    let mut conflict = submit(&id);
    conflict["text"] = json!("另一个任务");
    assert_eq!(
        action(&mut s, &p, &k, &c, "agent.submit", conflict, 104)["error"],
        "agent_run_conflict"
    );
    assert_eq!(s.view(105).unwrap()["runs"].as_array().unwrap().len(), 1);
}
#[test]
fn workspace_and_resume_cannot_be_selected_by_remote_path() {
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut settings = config();
    settings.workspaces[0].allow_write = false;
    let mut s = AgentStore::open(Path::new(":memory:"), "test", settings, 100).unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    assert_eq!(
        action(&mut s, &p, &k, &c, "agent.submit", submit(&id), 102)["error"],
        "agent_sandbox_not_allowed"
    );
    let mut v = submit(&id);
    v["sandbox"] = json!("read-only");
    v["workspace_id"] = json!("../../other");
    assert_eq!(
        action(&mut s, &p, &k, &c, "agent.submit", v, 103)["error"],
        "agent_workspace_not_allowed"
    );
    let mut v = submit(&id);
    v["sandbox"] = json!("read-only");
    v["resume_from"] = json!(uuid::Uuid::new_v4().to_string());
    assert_eq!(
        action(&mut s, &p, &k, &c, "agent.submit", v, 104)["error"],
        "agent_session_not_resumable"
    );
    let mut v = submit(&id);
    v["sandbox"] = json!("danger-full-access");
    assert_eq!(
        action(&mut s, &p, &k, &c, "agent.submit", v, 105)["error"],
        "agent_sandbox_not_allowed"
    );
}
#[test]
fn revocation_before_dispatch_prevents_spawn() {
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let mut p = paired(&k, &c);
    let mut s = memory();
    let id = uuid::Uuid::new_v4().to_string();
    action(&mut s, &p, &k, &c, "agent.submit", submit(&id), 102);
    s.approve(&id, true, 103).unwrap();
    p.revoke(&c).unwrap();
    assert!(s.next(&p, 104).unwrap().is_none());
    assert_eq!(s.view(105).unwrap()["runs"][0]["state"], "rejected");
}
#[test]
fn cancelled_queue_and_running_interrupt_are_distinct() {
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = memory();
    let first = uuid::Uuid::new_v4().to_string();
    action(&mut s, &p, &k, &c, "agent.submit", submit(&first), 102);
    assert_eq!(
        action(&mut s, &p, &k, &c, "agent.cancel", json!({"id":first}), 103)["value"]["state"],
        "cancelled"
    );
    assert!(s.next(&p, 104).unwrap().is_none());
    let id = uuid::Uuid::new_v4().to_string();
    action(&mut s, &p, &k, &c, "agent.submit", submit(&id), 105);
    s.approve(&id, true, 106).unwrap();
    s.next(&p, 107).unwrap();
    assert_eq!(
        action(&mut s, &p, &k, &c, "agent.cancel", json!({"id":id}), 108)["value"]["state"],
        "cancelling"
    );
    assert!(s.cancelling(&id).unwrap());
    s.update(
        &id,
        Update::Finished {
            state: "unknown".into(),
            error: Some("agent_transport_lost".into()),
        },
    )
    .unwrap();
    assert_eq!(
        action(&mut s, &p, &k, &c, "agent.status", json!({"id":id}), 109)["value"]["state"],
        "unknown"
    );
}
#[test]
fn running_is_unknown_after_host_restart() {
    let path: PathBuf =
        std::env::temp_dir().join(format!("limelink-agent-{}.sqlite", uuid::Uuid::new_v4()));
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let id = uuid::Uuid::new_v4().to_string();
    let mut s = AgentStore::open(&path, "test", config(), 100).unwrap();
    action(&mut s, &p, &k, &c, "agent.submit", submit(&id), 102);
    s.approve(&id, true, 103).unwrap();
    s.next(&p, 104).unwrap();
    drop(s);
    let mut reopened = AgentStore::open(&path, "test", config(), 105).unwrap();
    assert!(reopened.next(&p, 106).unwrap().is_none());
    assert_eq!(reopened.view(106).unwrap()["runs"][0]["state"], "unknown");
    assert!(AgentStore::open(&path, "other-host", config(), 107).is_err());
    drop(reopened);
    std::fs::remove_file(path).unwrap();
}
#[test]
fn transcript_is_paginated_scoped_and_expires_in_cached_receipts() {
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = memory();
    let id = uuid::Uuid::new_v4().to_string();
    action(&mut s, &p, &k, &c, "agent.submit", submit(&id), 102);
    s.approve(&id, true, 103).unwrap();
    s.next(&p, 104).unwrap();
    for _ in 0..6 {
        s.update(
            &id,
            Update::Event {
                kind: "message".into(),
                text: "private-reply".into(),
            },
        )
        .unwrap();
    }
    let e = input(&k, &c, "agent.status", json!({"id":id}), 105);
    let reply = response(
        s.execute("status", &e, &p, SPACE, DEVICE, REV, 105)
            .unwrap(),
    );
    assert_eq!(reply["value"]["events"].as_array().unwrap().len(), 4);
    assert_eq!(reply["value"]["cursor"], 4);
    let next = action(
        &mut s,
        &p,
        &k,
        &c,
        "agent.status",
        json!({"id":id,"after":4}),
        106,
    );
    assert_eq!(next["value"]["events"].as_array().unwrap().len(), 2);
    let stranger = uuid::Uuid::new_v4().to_string();
    let other = paired(&k, &stranger);
    assert_eq!(
        action(
            &mut s,
            &other,
            &k,
            &stranger,
            "agent.status",
            json!({"id":id}),
            107
        )["error"],
        "agent_run_not_found"
    );
    assert_eq!(s.view(4000).unwrap()["runs"][0]["reply"], "");
    s.expire(4000).unwrap();
    assert!(!s
        .execute("status", &e, &p, SPACE, DEVICE, REV, 4000)
        .unwrap()
        .to_string()
        .contains("private-reply"));
    assert_eq!(s.view(4000).unwrap()["runs"][0]["text"], "");
    assert_eq!(s.view(4000).unwrap()["runs"][0]["reply"], "");
}

fn tool_settings() -> Config {
    let mut settings = config();
    settings.allow_iot_tools = true;
    settings
}
fn tools_memory() -> AgentStore {
    AgentStore::open(Path::new(":memory:"), "test", tool_settings(), 100).unwrap()
}
fn start_with_tools(s: &mut AgentStore, p: &Store, k: &EcdsaKeyPair, c: &str) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let mut payload = submit(&id);
    payload["iot_devices"] = json!(["lamp-test"]);
    assert_eq!(
        action(s, p, k, c, "agent.submit", payload, 102)["value"]["state"],
        "awaiting_approval"
    );
    s.approve(&id, true, 103).unwrap();
    assert_eq!(
        s.next(p, 104).unwrap().unwrap().iot_devices,
        vec!["lamp-test"]
    );
    s.update(
        &id,
        Update::Session {
            thread: "thread-test".into(),
            turn: "turn-test".into(),
        },
    )
    .unwrap();
    id
}
fn read_call(call: &str) -> ToolCall {
    ToolCall {
        call: call.into(),
        tool: "limeiot_read".into(),
        arguments: json!({"device_id":"lamp-test"}),
    }
}
fn command_call(call: &str) -> ToolCall {
    ToolCall {
        call: call.into(),
        tool: "limeiot_command".into(),
        arguments: json!({"device_id":"lamp-test","model_revision":format!("sha256:{}","a".repeat(64)),"path":"light.power","value":true}),
    }
}
fn read_output() -> Value {
    json!({"device_id":"lamp-test","model_revision":format!("sha256:{}","a".repeat(64)),"ready":true,"properties":[{"path":"light.power","value":false,"writable":true,"schema":{"type":"boolean"},"observed_at":"2026-11-06T00:00:00Z","quality":"good"}]})
}
fn command_output(status: &str) -> Value {
    let mut value = command_call("unused").arguments;
    value["command_id"] = json!("original-iot-command");
    value["status"] = json!(status);
    value["observed_at"] = if status == "confirmed" {
        json!("2026-11-06T00:00:00Z")
    } else {
        Value::Null
    };
    value
}
fn complete_tool(
    s: &mut AgentStore,
    p: &Store,
    k: &EcdsaKeyPair,
    c: &str,
    id: &str,
    call: &str,
    success: bool,
    output: Value,
    now: i64,
) -> Value {
    action(
        s,
        p,
        k,
        c,
        "agent.tool_result",
        json!({"id":id,"call_id":call,"success":success,"output":output}),
        now,
    )
}

#[test]
fn iot_grants_require_configuration_and_cannot_include_the_execution_device() {
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut disabled = memory();
    let id = uuid::Uuid::new_v4().to_string();
    let mut payload = submit(&id);
    payload["iot_devices"] = json!(["lamp-test"]);
    assert_eq!(
        action(&mut disabled, &p, &k, &c, "agent.submit", payload, 102)["error"],
        "agent_iot_tools_not_allowed"
    );
    assert_eq!(
        action(
            &mut disabled,
            &p,
            &k,
            &c,
            "agent.tool_capabilities",
            json!({}),
            103
        )["value"]["enabled"],
        false
    );
    let mut s = tools_memory();
    for devices in [
        json!([DEVICE]),
        json!(["lamp-test", "lamp-test"]),
        json!(["a", "b", "c", "d", "e"]),
        json!(["https://untrusted.example"]),
    ] {
        let mut payload = submit(&id);
        payload["iot_devices"] = devices;
        assert_eq!(
            action(&mut s, &p, &k, &c, "agent.submit", payload, 104)["ok"],
            false
        );
    }
    assert!(s.view(105).unwrap()["runs"].as_array().unwrap().is_empty());
    // 默认关闭不改变旧配置摘要。
    assert!(!serde_json::to_string(&config())
        .unwrap()
        .contains("allow_iot_tools"));
}

#[test]
fn tool_proposals_and_results_are_scoped_to_the_original_requester() {
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = tools_memory();
    let id = start_with_tools(&mut s, &p, &k, &c);
    let call = s.register_tool(&id, &read_call("read-1"), 105).unwrap();
    let pending = action(
        &mut s,
        &p,
        &k,
        &c,
        "agent.tool_pending",
        json!({"id":id}),
        106,
    );
    assert_eq!(pending["value"]["calls"][0]["id"], call);
    assert_eq!(pending["value"]["devices"], json!(["lamp-test"]));
    let other_id = uuid::Uuid::new_v4().to_string();
    let other = paired(&k, &other_id);
    assert_eq!(
        action(
            &mut s,
            &other,
            &k,
            &other_id,
            "agent.tool_pending",
            json!({"id":id}),
            107
        )["error"],
        "agent_run_not_found"
    );
    assert_eq!(
        complete_tool(
            &mut s,
            &other,
            &k,
            &other_id,
            &id,
            &call,
            true,
            read_output(),
            107
        )["error"],
        "agent_tool_call_not_found"
    );
    let mut wrong = read_output();
    wrong["device_id"] = json!("another-device");
    assert_eq!(
        complete_tool(&mut s, &p, &k, &c, &id, &call, true, wrong, 108)["error"],
        "agent_tool_result_target_mismatch"
    );
    assert_eq!(
        complete_tool(&mut s, &p, &k, &c, &id, &call, true, read_output(), 109)["value"]
            ["recorded"],
        true
    );
    assert_eq!(
        complete_tool(&mut s, &p, &k, &c, &id, &call, true, read_output(), 110)["value"]
            ["recorded"],
        true
    );
    assert_eq!(
        complete_tool(
            &mut s,
            &p,
            &k,
            &c,
            &id,
            &call,
            false,
            json!({"error":"user_rejected"}),
            111
        )["error"],
        "agent_tool_result_conflict"
    );
    assert!(action(
        &mut s,
        &p,
        &k,
        &c,
        "agent.tool_pending",
        json!({"id":id}),
        112
    )["value"]["calls"]
        .as_array()
        .unwrap()
        .is_empty());
    s.update(
        &id,
        Update::Finished {
            state: "succeeded".into(),
            error: None,
        },
    )
    .unwrap();
    assert_eq!(s.view(113).unwrap()["runs"][0]["state"], "succeeded");
}

#[test]
fn tool_arguments_results_and_request_count_are_bounded() {
    let allowed = vec!["lamp-test".to_string()];
    for (key, value) in [
        ("device_id", json!("other")),
        ("url", json!("https://example.com")),
        ("value", json!({"shell":"no"})),
        ("value", Value::Null),
        ("path", json!("../../command")),
        ("model_revision", json!("sha256:bad")),
    ] {
        let mut call = command_call("write");
        call.arguments[key] = value;
        assert!(tools::validate_call(&call, &allowed).is_err());
    }
    let mut unknown = read_call("read");
    unknown.tool = "shell".into();
    assert!(tools::validate_call(&unknown, &allowed).is_err());
    let args = command_call("write").arguments;
    assert!(
        tools::validate_output("limeiot_command", &args, true, &command_output("unknown")).is_err()
    );
    let mut wrong = command_output("confirmed");
    wrong["path"] = json!("light.brightness");
    assert!(tools::validate_output("limeiot_command", &args, true, &wrong).is_err());
    wrong = command_output("confirmed");
    wrong["observed_at"] = json!("not-a-timestamp");
    assert!(tools::validate_output("limeiot_command", &args, true, &wrong).is_err());
    let mut large = read_output();
    large["properties"][0]["value"] = json!("private".repeat(1000));
    assert!(
        tools::validate_output("limeiot_read", &read_call("read").arguments, true, &large).is_err()
    );
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = tools_memory();
    let id = start_with_tools(&mut s, &p, &k, &c);
    s.register_tool(&id, &read_call("first"), 105).unwrap();
    assert_eq!(
        s.register_tool(&id, &read_call("first"), 106).unwrap_err(),
        "agent_tool_call_replayed"
    );
    for i in 1..16 {
        s.register_tool(&id, &read_call(&format!("read-{i}")), 106)
            .unwrap();
    }
    assert_eq!(
        s.register_tool(&id, &read_call("overflow"), 107)
            .unwrap_err(),
        "agent_tool_budget"
    );
}

#[test]
fn unknown_or_pending_device_effect_cannot_be_overwritten_by_model_completion() {
    for status in ["pending", "unknown", "expired"] {
        let k = key();
        let c = uuid::Uuid::new_v4().to_string();
        let p = paired(&k, &c);
        let mut s = tools_memory();
        let id = start_with_tools(&mut s, &p, &k, &c);
        let call = s.register_tool(&id, &command_call("write"), 105).unwrap();
        if status == "unknown" {
            assert_eq!(
                complete_tool(
                    &mut s,
                    &p,
                    &k,
                    &c,
                    &id,
                    &call,
                    false,
                    command_output("unknown"),
                    106
                )["ok"],
                true
            );
        }
        if status == "expired" {
            s.expire(226).unwrap();
        }
        s.update(
            &id,
            Update::Finished {
                state: "succeeded".into(),
                error: None,
            },
        )
        .unwrap();
        assert_eq!(s.view(227).unwrap()["runs"][0]["state"], "unknown");
        assert_eq!(
            s.view(227).unwrap()["runs"][0]["error"],
            "agent_tool_result_unknown"
        );
        assert!(action(
            &mut s,
            &p,
            &k,
            &c,
            "agent.tool_pending",
            json!({"id":id}),
            228
        )["value"]["calls"]
            .as_array()
            .unwrap()
            .is_empty());
    }
}

#[test]
fn cancellation_hides_proposals_and_does_not_erase_unknown_device_effects() {
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = tools_memory();
    let id = start_with_tools(&mut s, &p, &k, &c);
    let call = s.register_tool(&id, &command_call("write"), 105).unwrap();
    assert_eq!(
        action(&mut s, &p, &k, &c, "agent.cancel", json!({"id":id}), 106)["value"]["state"],
        "cancelling"
    );
    assert!(action(
        &mut s,
        &p,
        &k,
        &c,
        "agent.tool_pending",
        json!({"id":id}),
        107
    )["value"]["calls"]
        .as_array()
        .unwrap()
        .is_empty());
    assert_eq!(
        complete_tool(
            &mut s,
            &p,
            &k,
            &c,
            &id,
            &call,
            true,
            command_output("confirmed"),
            108
        )["ok"],
        false
    );
    s.update(
        &id,
        Update::Finished {
            state: "cancelled".into(),
            error: None,
        },
    )
    .unwrap();
    assert_eq!(s.view(109).unwrap()["runs"][0]["state"], "unknown");
}

#[test]
fn continuation_keeps_the_exact_iot_grant() {
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = tools_memory();
    let id = start_with_tools(&mut s, &p, &k, &c);
    s.update(
        &id,
        Update::Finished {
            state: "succeeded".into(),
            error: None,
        },
    )
    .unwrap();
    let next = uuid::Uuid::new_v4().to_string();
    let mut payload = submit(&next);
    payload["resume_from"] = json!(id);
    assert_eq!(
        action(&mut s, &p, &k, &c, "agent.submit", payload.clone(), 106)["error"],
        "agent_tool_scope_changed"
    );
    payload["iot_devices"] = json!(["lamp-test", "other"]);
    assert_eq!(
        action(&mut s, &p, &k, &c, "agent.submit", payload.clone(), 107)["error"],
        "agent_tool_scope_changed"
    );
    payload["iot_devices"] = json!(["lamp-test"]);
    assert_eq!(
        action(&mut s, &p, &k, &c, "agent.submit", payload, 108)["value"]["state"],
        "awaiting_approval"
    );
}

#[test]
fn expired_tool_content_is_removed_from_storage_and_original_request_cache() {
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = tools_memory();
    let id = start_with_tools(&mut s, &p, &k, &c);
    let mut call = command_call("write");
    call.arguments["value"] = json!("private-tool-value");
    s.register_tool(&id, &call, 105).unwrap();
    let e = input(&k, &c, "agent.tool_pending", json!({"id":id}), 106);
    assert!(s
        .execute("pending-proposal", &e, &p, SPACE, DEVICE, REV, 106)
        .unwrap()
        .to_string()
        .contains("private-tool-value"));
    s.expire(4000).unwrap();
    let cached = s
        .execute("pending-proposal", &e, &p, SPACE, DEVICE, REV, 4000)
        .unwrap()
        .to_string();
    assert!(!cached.contains("private-tool-value"));
    assert!(!cached.contains("lamp-test"));
    assert_eq!(s.view(4000).unwrap()["runs"][0]["iot_devices"], json!([]));
}

#[test]
fn agent_content_expiry_rolls_back_if_a_cached_receipt_is_corrupt() {
    let directory =
        std::env::temp_dir().join(format!("limelink-agent-atomic-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let path = directory.join("agent.sqlite");
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = AgentStore::open(&path, "test", tool_settings(), 100).unwrap();
    let id = start_with_tools(&mut s, &p, &k, &c);
    let mut call = command_call("atomic-write");
    call.arguments["value"] = json!("PRIVATE_ATOMIC_TOOL_BODY");
    s.register_tool(&id, &call, 105).unwrap();
    s.update(
        &id,
        Update::Event {
            kind: "message".into(),
            text: "PRIVATE_ATOMIC_REPLY".into(),
        },
    )
    .unwrap();
    let query = input(&k, &c, "agent.status", json!({"id":id}), 106);
    s.execute("atomic-receipt", &query, &p, SPACE, DEVICE, REV, 106)
        .unwrap();
    let db = rusqlite::Connection::open(&path).unwrap();
    let receipt: String = db
        .query_row(
            "SELECT result FROM receipts WHERE id='atomic-receipt'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    db.execute(
        "UPDATE receipts SET result='invalid-json' WHERE id='atomic-receipt'",
        [],
    )
    .unwrap();
    assert!(s.expire(4000).is_err());
    let prompt: String = db
        .query_row("SELECT prompt FROM runs WHERE id=?", [&id], |r| r.get(0))
        .unwrap();
    assert!(!prompt.is_empty(), "回执损坏时不能只清理部分主表");
    let event: String = db
        .query_row("SELECT text FROM events WHERE run=?", [&id], |r| r.get(0))
        .unwrap();
    assert_eq!(event, "PRIVATE_ATOMIC_REPLY");
    let arguments: String = db
        .query_row("SELECT arguments FROM tool_calls WHERE run=?", [&id], |r| {
            r.get(0)
        })
        .unwrap();
    assert!(arguments.contains("PRIVATE_ATOMIC_TOOL_BODY"));
    let devices: String = db
        .query_row("SELECT devices FROM tool_grants WHERE run=?", [&id], |r| {
            r.get(0)
        })
        .unwrap();
    assert!(devices.contains("lamp-test"));
    db.execute(
        "UPDATE receipts SET result=? WHERE id='atomic-receipt'",
        [receipt],
    )
    .unwrap();
    s.expire(4000).unwrap();
    assert_eq!(s.view(4000).unwrap()["runs"][0]["reply"], "");
    drop(db);
    drop(s);
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn agent_wal_cleanup_retries_after_readers_and_restart_without_replaying_requests() {
    let directory =
        std::env::temp_dir().join(format!("limelink-agent-wal-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let path = directory.join("agent.sqlite");
    let marker = "PRIVATE_AGENT_BODY_FOR_WAL_RETENTION_CHECK";
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = AgentStore::open(&path, "test", tool_settings(), 100).unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    let mut payload = submit(&id);
    payload["text"] = json!(marker);
    payload["iot_devices"] = json!(["lamp-test"]);
    action(&mut s, &p, &k, &c, "agent.submit", payload, 102);
    s.approve(&id, true, 103).unwrap();
    s.next(&p, 104).unwrap();
    s.update(
        &id,
        Update::Session {
            thread: "thread-test".into(),
            turn: "turn-test".into(),
        },
    )
    .unwrap();
    s.update(
        &id,
        Update::Event {
            kind: "message".into(),
            text: marker.into(),
        },
    )
    .unwrap();
    let mut call = command_call("private-write");
    call.arguments["path"] = json!("light.label");
    call.arguments["value"] = json!(marker);
    let call_id = s.register_tool(&id, &call, 105).unwrap();
    let mut output = command_output("confirmed");
    output["path"] = json!("light.label");
    output["value"] = json!(marker);
    assert_eq!(
        complete_tool(&mut s, &p, &k, &c, &id, &call_id, true, output, 106)["ok"],
        true
    );
    let query = input(&k, &c, "agent.status", json!({"id":id}), 107);
    let original = s
        .execute("private-status", &query, &p, SPACE, DEVICE, REV, 107)
        .unwrap();
    let reader =
        rusqlite::Connection::open_with_flags(&path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
    reader.execute_batch("BEGIN").unwrap();
    assert_eq!(
        reader
            .query_row("SELECT prompt FROM runs WHERE id=?", [&id], |r| r
                .get::<_, String>(0))
            .unwrap(),
        marker
    );
    let started = std::time::Instant::now();
    s.expire(4000).unwrap();
    assert!(
        started.elapsed() < std::time::Duration::from_secs(1),
        "读者不能阻塞执行端等待 WAL 清理"
    );
    assert_eq!(s.view(4000).unwrap()["content_cleanup_pending"], true);
    assert_eq!(s.view(4000).unwrap()["runs"][0]["text"], "");
    let wal = path.with_extension("sqlite-wal");
    assert!(std::fs::read(&wal)
        .unwrap()
        .windows(marker.len())
        .any(|bytes| bytes == marker.as_bytes()));
    drop(s);
    let mut s = AgentStore::open(&path, "test", tool_settings(), 4001).unwrap();
    assert_eq!(s.view(4001).unwrap()["content_cleanup_pending"], true);
    reader.execute_batch("ROLLBACK").unwrap();
    drop(reader);
    s.expire(4002).unwrap();
    assert_eq!(s.view(4002).unwrap()["content_cleanup_pending"], false);
    assert_eq!(
        s.update(
            &id,
            Update::Event {
                kind: "message".into(),
                text: marker.into()
            }
        )
        .unwrap_err(),
        "agent_run_content_expired"
    );
    let replay = s
        .execute("private-status", &query, &p, SPACE, DEVICE, REV, 4002)
        .unwrap();
    assert_eq!(replay["command_id"], original["command_id"]);
    assert_eq!(
        replay["evidence"]["input_digest"],
        original["evidence"]["input_digest"]
    );
    assert!(!replay.to_string().contains(marker));
    assert!(s.next(&p, 4002).unwrap().is_none());
    for file in [&path, &wal] {
        let bytes = std::fs::read(file).unwrap();
        assert!(
            !bytes
                .windows(marker.len())
                .any(|bytes| bytes == marker.as_bytes()),
            "活动 Agent 数据库文件仍有过期正文"
        );
    }
    drop(s);
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn reopening_agent_storage_compacts_legacy_free_pages_and_preserves_queued_work() {
    let directory =
        std::env::temp_dir().join(format!("limelink-agent-legacy-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let path = directory.join("agent.sqlite");
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = AgentStore::open(&path, "test", config(), 100).unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    action(&mut s, &p, &k, &c, "agent.submit", submit(&id), 102);
    s.approve(&id, true, 103).unwrap();
    drop(s);
    let marker = "PRIVATE_AGENT_LEGACY_DELETED_BODY";
    let db = rusqlite::Connection::open(&path).unwrap();
    db.execute_batch("PRAGMA secure_delete=OFF; CREATE TABLE legacy_deleted(text TEXT);")
        .unwrap();
    db.execute(
        "INSERT INTO legacy_deleted VALUES(?)",
        [marker.repeat(4096)],
    )
    .unwrap();
    db.execute_batch("DROP TABLE legacy_deleted; PRAGMA wal_checkpoint(TRUNCATE);")
        .unwrap();
    drop(db);
    assert!(std::fs::read(&path)
        .unwrap()
        .windows(marker.len())
        .any(|bytes| bytes == marker.as_bytes()));
    let mut s = AgentStore::open(&path, "test", config(), 104).unwrap();
    assert_eq!(s.view(104).unwrap()["content_cleanup_pending"], false);
    assert!(
        !std::fs::read(&path)
            .unwrap()
            .windows(marker.len())
            .any(|bytes| bytes == marker.as_bytes()),
        "旧版空闲页中的已删除正文仍未整理"
    );
    assert_eq!(s.next(&p, 105).unwrap().unwrap().id, id);
    drop(s);
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn restarting_a_host_does_not_reissue_a_pending_device_tool() {
    let path = std::env::temp_dir().join(format!("limelink-tools-{}.sqlite", uuid::Uuid::new_v4()));
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = AgentStore::open(&path, "test", tool_settings(), 100).unwrap();
    let id = start_with_tools(&mut s, &p, &k, &c);
    s.register_tool(&id, &command_call("write"), 105).unwrap();
    drop(s);
    let mut reopened = AgentStore::open(&path, "test", tool_settings(), 106).unwrap();
    assert!(reopened.next(&p, 107).unwrap().is_none());
    assert_eq!(reopened.view(107).unwrap()["runs"][0]["state"], "unknown");
    assert!(action(
        &mut reopened,
        &p,
        &k,
        &c,
        "agent.tool_pending",
        json!({"id":id}),
        108
    )["value"]["calls"]
        .as_array()
        .unwrap()
        .is_empty());
    drop(reopened);
    std::fs::remove_file(path).unwrap();
}

#[tokio::test]
async fn completed_results_survive_reply_channel_backpressure() {
    use limelink_runtime::agent::tools::ToolReply;
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = tools_memory();
    let now = chrono::Utc::now().timestamp();
    let id = uuid::Uuid::new_v4().to_string();
    let mut payload = submit(&id);
    payload["iot_devices"] = json!(["lamp-test"]);
    action(&mut s, &p, &k, &c, "agent.submit", payload, now);
    s.approve(&id, true, now).unwrap();
    s.next(&p, now).unwrap();
    s.update(
        &id,
        Update::Session {
            thread: "thread".into(),
            turn: "turn".into(),
        },
    )
    .unwrap();
    let (sender, mut receiver) = tokio::sync::mpsc::channel(1);
    sender
        .send(ToolReply {
            call: "filled".into(),
            success: false,
            output: json!({"error":"fixture"}),
        })
        .await
        .unwrap();
    s.update(
        &id,
        Update::Tool {
            call: read_call("read"),
            reply: sender,
        },
    )
    .unwrap();
    let pending = action(
        &mut s,
        &p,
        &k,
        &c,
        "agent.tool_pending",
        json!({"id":id}),
        now,
    );
    let call = pending["value"]["calls"][0]["id"].as_str().unwrap();
    assert_eq!(
        complete_tool(&mut s, &p, &k, &c, &id, call, true, read_output(), now)["ok"],
        true
    );
    assert_eq!(receiver.recv().await.unwrap().call, "filled");
    s.deliver_tool_replies().unwrap();
    let reply = receiver.try_recv().unwrap();
    assert_eq!(reply.call, "read");
    assert!(reply.success);
    s.deliver_tool_replies().unwrap();
    assert!(receiver.try_recv().is_err());
}

#[test]
fn version_one_agent_storage_upgrades_without_changing_queued_tasks() {
    let path = std::env::temp_dir().join(format!(
        "limelink-migration-{}.sqlite",
        uuid::Uuid::new_v4()
    ));
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let p = paired(&k, &c);
    let mut s = AgentStore::open(&path, "test", config(), 100).unwrap();
    let id = uuid::Uuid::new_v4().to_string();
    action(&mut s, &p, &k, &c, "agent.submit", submit(&id), 102);
    s.approve(&id, true, 103).unwrap();
    drop(s);
    // 在隔离夹具中还原 v1 的表布局；不触碰产品数据库。
    let db = rusqlite::Connection::open(&path).unwrap();
    db.execute_batch("DROP TABLE tool_calls; DROP TABLE tool_grants; PRAGMA user_version=1;")
        .unwrap();
    drop(db);
    let mut migrated = AgentStore::open(&path, "test", config(), 104).unwrap();
    let job = migrated.next(&p, 105).unwrap().unwrap();
    assert_eq!(job.id, id);
    assert!(job.iot_devices.is_empty());
    drop(migrated);
    let db = rusqlite::Connection::open(&path).unwrap();
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        2
    );
    db.execute_batch("PRAGMA user_version=3;").unwrap();
    drop(db);
    assert_eq!(
        AgentStore::open(&path, "test", config(), 106)
            .err()
            .unwrap(),
        "unsupported_agent_storage_version"
    );
    let db = rusqlite::Connection::open(&path).unwrap();
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        3
    );
    drop(db);
    std::fs::remove_file(path).unwrap();
}
