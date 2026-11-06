use limelink_runtime::{Exchange, Store};
use ring::{
    rand::SystemRandom,
    signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_ASN1_SIGNING},
};
use serde_json::{json, Value};
const SPACE: &str = "space-demo";
const DEVICE: &str = "desktop-test";
const REV: &str = "sha256:1234567890";
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
fn store() -> Store {
    Store::open(std::path::Path::new(":memory:"), "test").unwrap()
}
fn response(value: Value) -> Value {
    serde_json::from_str(value["evidence"]["output"]["response"].as_str().unwrap()).unwrap()
}
fn execute(
    s: &mut Store,
    k: &EcdsaKeyPair,
    c: &str,
    kind: &str,
    payload: Value,
    now: i64,
) -> Value {
    let e = input(k, c, kind, payload, now);
    response(
        s.execute(
            &uuid::Uuid::new_v4().to_string(),
            &e,
            SPACE,
            DEVICE,
            REV,
            now,
        )
        .unwrap(),
    )
}
fn paired(s: &mut Store, k: &EcdsaKeyPair, c: &str) {
    assert_eq!(
        execute(s, k, c, "pair", json!({"name":"测试手机"}), 100)["ok"],
        true
    );
    s.approve(c, true, 101).unwrap();
}
#[test]
fn explicit_approval_expiry_and_revocation() {
    let mut s = store();
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "card",
            json!({"text":"hello","ttl":60}),
            100
        )["error"],
        "pairing_required"
    );
    execute(&mut s, &k, &c, "pair", json!({"name":"手机"}), 100);
    assert!(s.approve(&c, true, 221).is_err());
    assert_eq!(
        execute(&mut s, &k, &c, "status", json!({}), 222)["value"]["state"],
        "expired"
    );
    let c = uuid::Uuid::new_v4().to_string();
    paired(&mut s, &k, &c);
    execute(
        &mut s,
        &k,
        &c,
        "card",
        json!({"text":"only text","ttl":60}),
        102,
    );
    s.revoke(&c).unwrap();
    assert_eq!(s.view(103).unwrap()["cards"][0]["state"], "cancelled");
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "card",
            json!({"text":"blocked","ttl":60}),
            104
        )["error"],
        "pairing_not_approved"
    );
}
#[test]
fn original_command_and_nonce_are_not_reexecuted() {
    let mut s = store();
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    paired(&mut s, &k, &c);
    let e = input(&k, &c, "card", json!({"text":"once","ttl":60}), 102);
    let a = s.execute("command-1", &e, SPACE, DEVICE, REV, 102).unwrap();
    assert_eq!(
        s.execute("command-1", &e, SPACE, DEVICE, REV, 200).unwrap(),
        a
    );
    assert_eq!(
        s.execute("command-2", &e, SPACE, DEVICE, REV, 103)
            .unwrap_err(),
        "nonce_replayed"
    );
    assert_eq!(s.view(103).unwrap()["cards"].as_array().unwrap().len(), 1);
    let other = input(&k, &c, "card", json!({"text":"different","ttl":60}), 103);
    assert_eq!(
        s.execute("command-1", &other, SPACE, DEVICE, REV, 103)
            .unwrap_err(),
        "duplicate_conflict"
    );
}
#[test]
fn signature_freezes_target_content_and_identity() {
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let mut e = input(&k, &c, "pair", json!({"name":"手机"}), 100);
    assert!(e.verify(SPACE, "wrong-device", REV, 100).is_err());
    assert!(e.verify("wrong-space", DEVICE, REV, 100).is_err());
    assert!(e.verify(SPACE, DEVICE, "changed-revision", 100).is_err());
    e.payload = "{\"name\":\"attacker\"}".into();
    assert!(e.verify(SPACE, DEVICE, REV, 100).is_err());
}
#[test]
fn presentation_is_separate_from_submission() {
    let mut s = store();
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    paired(&mut s, &k, &c);
    let result = execute(
        &mut s,
        &k,
        &c,
        "card",
        json!({"text":"<script>plain data</script>","ttl":60}),
        102,
    );
    let id = result["value"]["id"].as_str().unwrap();
    assert_eq!(s.view(103).unwrap()["cards"][0]["state"], "queued");
    s.presented(id, 104).unwrap();
    assert_eq!(s.view(105).unwrap()["cards"][0]["state"], "presented");
    s.expire_content(200).unwrap();
    assert_eq!(s.view(200).unwrap()["cards"][0]["text"], "");
}
#[test]
fn session_cas_lease_and_content_budget() {
    let mut s = store();
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    paired(&mut s, &k, &c);
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "session_create",
            json!({"id":"s1","text":"draft","ttl":100}),
            102
        )["ok"],
        true
    );
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "session_claim",
            json!({"id":"s1","revision":1}),
            103
        )["value"]["revision"],
        2
    );
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "session_write",
            json!({"id":"s1","revision":1,"text":"old"}),
            104
        )["error"],
        "revision_conflict"
    );
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "session_write",
            json!({"id":"s1","revision":2,"text":"next"}),
            104
        )["ok"],
        true
    );
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "session_write",
            json!({"id":"s1","revision":3,"text":"late"}),
            134
        )["error"],
        "lease_expired"
    );
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "content_put",
            json!({"id":"content","text":"safe","sha256":"bad","ttl":10}),
            110
        )["error"],
        "invalid_content"
    );
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "content_put",
            json!({"id":"content","text":"safe","sha256":limelink_runtime::hash(b"safe"),"ttl":10}),
            111
        )["ok"],
        true
    );
    s.expire_content(122).unwrap();
    assert_eq!(s.view(122).unwrap()["contents"][0]["stale"], true);
}
#[test]
fn phone_and_desktop_cannot_overwrite_each_other() {
    let mut s = store();
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    paired(&mut s, &k, &c);
    execute(
        &mut s,
        &k,
        &c,
        "session_create",
        json!({"id":"shared","text":"first","ttl":200}),
        102,
    );
    execute(
        &mut s,
        &k,
        &c,
        "session_claim",
        json!({"id":"shared","revision":1}),
        103,
    );
    assert_eq!(
        s.local_session("shared", 2, "session_claim", None, 104)
            .unwrap_err(),
        "writer_busy"
    );
    s.local_session("shared", 2, "session_claim", None, 134)
        .unwrap();
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "session_write",
            json!({"id":"shared","revision":2,"text":"stale"}),
            135
        )["error"],
        "revision_conflict"
    );
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "session_write",
            json!({"id":"shared","revision":3,"text":"wrong writer"}),
            135
        )["error"],
        "lease_expired"
    );
    s.local_session("shared", 3, "session_write", Some("from desktop"), 135)
        .unwrap();
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "session_release",
            json!({"id":"shared","revision":4}),
            136
        )["error"],
        "writer_busy"
    );
    assert_eq!(s.view(136).unwrap()["sessions"][0]["text"], "from desktop");
    s.local_session("shared", 4, "session_release", None, 136)
        .unwrap();
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "session_claim",
            json!({"id":"shared","revision":5}),
            137
        )["value"]["text"],
        "from desktop"
    );
}
#[test]
fn diagnostics_never_exports_content_or_identity() {
    let directory = std::env::temp_dir().join(format!("limelink-check-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let path = directory.join("state.sqlite");
    let mut s = Store::open(&path, "private-identity").unwrap();
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    paired(&mut s, &k, &c);
    execute(
        &mut s,
        &k,
        &c,
        "card",
        json!({"text":"private-body","ttl":60}),
        102,
    );
    let report = limelink_runtime::diagnostics(&path).unwrap();
    let text = report.to_string();
    assert_eq!(report["counts"]["cards"], 1);
    assert_eq!(report["schema_version"], 2);
    for secret in [
        "private-body",
        "private-identity",
        &c,
        &hex::encode(k.public_key().as_ref()),
    ] {
        assert!(!text.contains(secret));
    }
    assert_eq!(s.view(103).unwrap()["cards"][0]["text"], "private-body");
    drop(s);
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn expired_session_text_is_removed_from_original_command_receipts() {
    let mut s = store();
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    paired(&mut s, &k, &c);
    execute(
        &mut s,
        &k,
        &c,
        "session_create",
        json!({"id":"private-session","text":"private-cached-session-body","ttl":10}),
        102,
    );
    let claim = input(
        &k,
        &c,
        "session_claim",
        json!({"id":"private-session","revision":1}),
        103,
    );
    let original = s
        .execute("private-claim", &claim, SPACE, DEVICE, REV, 103)
        .unwrap();
    assert_eq!(
        response(original.clone())["value"]["text"],
        "private-cached-session-body"
    );
    assert_eq!(
        s.execute("private-claim", &claim, SPACE, DEVICE, REV, 111)
            .unwrap(),
        original
    );
    s.expire_content(112).unwrap();
    let expired = s
        .execute("private-claim", &claim, SPACE, DEVICE, REV, 112)
        .unwrap();
    let value = response(expired.clone());
    assert_eq!(value["value"]["text"], "");
    assert_eq!(value["value"]["content_expired"], true);
    assert_eq!(value["value"]["revision"], 2);
    assert_eq!(expired["command_id"], original["command_id"]);
    assert_eq!(
        expired["evidence"]["input_digest"],
        original["evidence"]["input_digest"]
    );
    assert_eq!(s.view(112).unwrap()["sessions"][0]["revision"], 2);
    assert_eq!(s.view(112).unwrap()["sessions"][0]["text"], "");
    let conflict = input(
        &k,
        &c,
        "session_claim",
        json!({"id":"other","revision":1}),
        112,
    );
    assert_eq!(
        s.execute("private-claim", &conflict, SPACE, DEVICE, REV, 112)
            .unwrap_err(),
        "duplicate_conflict"
    );
    assert_eq!(
        s.execute("different-command", &claim, SPACE, DEVICE, REV, 112)
            .unwrap_err(),
        "nonce_replayed"
    );
}

#[test]
fn original_receipt_query_enforces_expiry_without_waiting_for_a_heartbeat() {
    let mut s = store();
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    paired(&mut s, &k, &c);
    execute(
        &mut s,
        &k,
        &c,
        "session_create",
        json!({"id":"short","text":"expired-body","ttl":1}),
        102,
    );
    let claim = input(
        &k,
        &c,
        "session_claim",
        json!({"id":"short","revision":1}),
        102,
    );
    s.execute("short-claim", &claim, SPACE, DEVICE, REV, 102)
        .unwrap();
    let expired = response(
        s.execute("short-claim", &claim, SPACE, DEVICE, REV, 103)
            .unwrap(),
    );
    assert_eq!(expired["value"]["text"], "");
    assert_eq!(expired["value"]["content_expired"], true);
    assert_eq!(s.view(103).unwrap()["sessions"][0]["revision"], 2);
}

fn legacy_receipt_columns(db: &rusqlite::Connection) {
    db.execute_batch(
        "BEGIN IMMEDIATE;
        DROP INDEX receipt_content_expiry;
        ALTER TABLE receipts DROP COLUMN content_purged;
        ALTER TABLE receipts DROP COLUMN content_expires;
        ALTER TABLE metadata DROP COLUMN content_compaction_pending;
        PRAGMA user_version=1;
        COMMIT;",
    )
    .unwrap();
}

#[test]
fn version_one_receipts_require_explicit_migration_and_do_not_reuse_new_session_deadlines() {
    for session_state in ["original", "removed", "recreated"] {
        let directory =
            std::env::temp_dir().join(format!("limelink-retention-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("state.sqlite");
        let mut s = Store::open(&path, "test").unwrap();
        let k = key();
        let c = uuid::Uuid::new_v4().to_string();
        paired(&mut s, &k, &c);
        execute(
            &mut s,
            &k,
            &c,
            "session_create",
            json!({"id":"legacy","text":"legacy-session-body","ttl":10}),
            102,
        );
        let claim = input(
            &k,
            &c,
            "session_claim",
            json!({"id":"legacy","revision":1}),
            103,
        );
        let original = s
            .execute("legacy-claim", &claim, SPACE, DEVICE, REV, 103)
            .unwrap();
        drop(s);
        let db = rusqlite::Connection::open(&path).unwrap();
        legacy_receipt_columns(&db);
        if session_state == "removed" {
            db.execute("DELETE FROM sessions", []).unwrap();
        } else if session_state == "recreated" {
            db.execute(
                "UPDATE sessions SET text='new-session-body',expires=1000,revision=1",
                [],
            )
            .unwrap();
        }
        drop(db);
        assert_eq!(
            Store::open(&path, "test").err().unwrap(),
            "storage_migration_required"
        );
        assert_eq!(
            limelink_runtime::diagnostics(&path).unwrap()["schema_version"],
            1
        );
        let mut s = Store::migrate(&path, "test", 104).unwrap();
        let expired = s
            .execute("legacy-claim", &claim, SPACE, DEVICE, REV, 104)
            .unwrap();
        let value = response(expired.clone());
        assert_eq!(value["value"]["text"], "");
        assert_eq!(value["value"]["content_expired"], true);
        assert_eq!(
            expired["evidence"]["input_digest"],
            original["evidence"]["input_digest"]
        );
        assert_eq!(
            limelink_runtime::diagnostics(&path).unwrap()["schema_version"],
            2
        );
        if session_state == "original" {
            assert_eq!(
                s.view(104).unwrap()["sessions"][0]["text"],
                "legacy-session-body"
            );
        } else if session_state == "recreated" {
            assert_eq!(
                s.view(104).unwrap()["sessions"][0]["text"],
                "new-session-body"
            );
        }
        s.expire_content(112).unwrap();
        drop(s);
        assert!(!std::fs::read(&path)
            .unwrap()
            .windows(b"legacy-session-body".len())
            .any(|bytes| bytes == b"legacy-session-body"));
        std::fs::remove_dir_all(directory).unwrap();
    }
}

#[test]
fn failed_migration_preserves_the_previous_format_and_identity() {
    let directory =
        std::env::temp_dir().join(format!("limelink-migration-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let path = directory.join("state.sqlite");
    drop(Store::open(&path, "original-identity").unwrap());
    let db = rusqlite::Connection::open(&path).unwrap();
    legacy_receipt_columns(&db);
    assert_eq!(
        Store::migrate(&path, "different-identity", 100)
            .err()
            .unwrap(),
        "identity_mismatch"
    );
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    db.execute(
        "INSERT INTO receipts VALUES('corrupted','unchanged-digest','invalid-json')",
        [],
    )
    .unwrap();
    assert_eq!(
        Store::migrate(&path, "original-identity", 100)
            .err()
            .unwrap(),
        "invalid_payload"
    );
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM pragma_table_info('receipts')",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        3
    );
    assert_eq!(
        db.query_row("SELECT result FROM receipts", [], |r| r.get::<_, String>(0))
            .unwrap(),
        "invalid-json"
    );
    db.execute_batch("PRAGMA user_version=3").unwrap();
    assert_eq!(
        Store::open(&path, "original-identity").err().unwrap(),
        "unsupported_storage_version"
    );
    assert_eq!(
        db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        3
    );
    drop(db);
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn wal_cleanup_waits_for_readers_and_retries_after_restart() {
    let directory = std::env::temp_dir().join(format!("limelink-wal-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let path = directory.join("state.sqlite");
    let mut s = Store::open(&path, "test").unwrap();
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    paired(&mut s, &k, &c);
    let marker = "PRIVATE_BODY_FOR_WAL_RETENTION_CHECK";
    execute(
        &mut s,
        &k,
        &c,
        "session_create",
        json!({"id":"wal-session","text":marker,"ttl":10}),
        102,
    );
    execute(
        &mut s,
        &k,
        &c,
        "session_claim",
        json!({"id":"wal-session","revision":1}),
        103,
    );
    let reader =
        rusqlite::Connection::open_with_flags(&path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
    reader.execute_batch("BEGIN").unwrap();
    assert_eq!(
        reader
            .query_row("SELECT text FROM sessions", [], |r| r.get::<_, String>(0))
            .unwrap(),
        marker
    );
    let started = std::time::Instant::now();
    s.expire_content(112).unwrap();
    assert!(
        started.elapsed() < std::time::Duration::from_secs(1),
        "读者不应阻塞控制通道等待 checkpoint"
    );
    assert_eq!(s.view(112).unwrap()["content_cleanup_pending"], true);
    assert_eq!(s.view(112).unwrap()["sessions"][0]["text"], "");
    let wal = path.with_extension("sqlite-wal");
    assert!(std::fs::read(&wal)
        .unwrap()
        .windows(marker.len())
        .any(|bytes| bytes == marker.as_bytes()));
    drop(s);
    let mut s = Store::open(&path, "test").unwrap();
    s.expire_content(113).unwrap();
    assert_eq!(s.view(113).unwrap()["content_cleanup_pending"], true);
    reader.execute_batch("ROLLBACK").unwrap();
    drop(reader);
    s.expire_content(114).unwrap();
    assert_eq!(s.view(114).unwrap()["content_cleanup_pending"], false);
    for file in [&path, &wal] {
        let bytes = std::fs::read(file).unwrap();
        assert!(
            !bytes
                .windows(marker.len())
                .any(|bytes| bytes == marker.as_bytes()),
            "活动数据库文件仍包含过期正文"
        );
    }
    drop(s);
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn migration_command_exits_without_connecting_or_starting_an_agent_and_respects_the_runtime_lock() {
    let directory =
        std::env::temp_dir().join(format!("limelink-migration-cli-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let path = directory.join("state.sqlite");
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let revision = format!("sha256:{}", "a".repeat(64));
    let identity = format!("space-test\ndevice-test\n{revision}");
    drop(Store::open(&path, &identity).unwrap());
    let db = rusqlite::Connection::open(&path).unwrap();
    legacy_receipt_columns(&db);
    drop(db);
    let configuration = directory.join("device.json");
    std::fs::write(&configuration,json!({"mqtt_host":"127.0.0.1","mqtt_port":listener.local_addr().unwrap().port(),"space":"space-test","device":"device-test","model_revision":revision,"database":path}).to_string()).unwrap();
    let lock = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(path.with_extension("lock"))
        .unwrap();
    fs2::FileExt::try_lock_exclusive(&lock).unwrap();
    let blocked = std::process::Command::new(env!("CARGO_BIN_EXE_limelink-runtime"))
        .arg("--migrate-storage")
        .arg(&configuration)
        .output()
        .unwrap();
    assert!(!blocked.status.success());
    assert!(String::from_utf8(blocked.stderr)
        .unwrap()
        .contains("runtime_already_running"));
    assert_eq!(
        limelink_runtime::diagnostics(&path).unwrap()["schema_version"],
        1
    );
    drop(lock);
    let migrated = std::process::Command::new(env!("CARGO_BIN_EXE_limelink-runtime"))
        .arg("--migrate-storage")
        .arg(&configuration)
        .output()
        .unwrap();
    assert!(
        migrated.status.success(),
        "{}",
        String::from_utf8_lossy(&migrated.stderr)
    );
    let report: Value = serde_json::from_slice(&migrated.stdout).unwrap();
    assert_eq!(report["type"], "storage_migration");
    assert_eq!(report["schema_version"], 2);
    assert_eq!(report["content_cleanup_pending"], false);
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    assert!(!path.with_extension("agent.sqlite").exists());
    drop(listener);
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn reapply_is_explicit_and_never_extends_live_approval() {
    let mut s = store();
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    execute(&mut s, &k, &c, "pair", json!({"name":"原名称"}), 100);
    let live = execute(
        &mut s,
        &k,
        &c,
        "pair",
        json!({"name":"新名称","reapply":true}),
        200,
    );
    assert_eq!(live["value"]["expires_at"], 220);
    assert_eq!(s.view(200).unwrap()["peers"][0]["name"], "原名称");
    assert_eq!(
        execute(&mut s, &k, &c, "pair", json!({"name":"手机"}), 221)["value"]["state"],
        "expired"
    );
    let retry = execute(
        &mut s,
        &k,
        &c,
        "pair",
        json!({"name":"重新申请","reapply":true}),
        222,
    );
    assert_eq!(retry["value"]["state"], "pending");
    assert_eq!(retry["value"]["expires_at"], 342);
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "card",
            json!({"text":"still blocked","ttl":60}),
            223
        )["error"],
        "pairing_not_approved"
    );
    s.approve(&c, true, 224).unwrap();
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "pair",
            json!({"name":"不能降级","reapply":true}),
            225
        )["value"]["state"],
        "approved"
    );
    assert_eq!(s.view(225).unwrap()["peers"][0]["name"], "重新申请");
}

#[test]
fn reapply_after_rejection_preserves_original_denial_and_identity() {
    let mut s = store();
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    execute(&mut s, &k, &c, "pair", json!({"name":"手机"}), 100);
    s.approve(&c, false, 101).unwrap();
    let e = input(
        &k,
        &c,
        "card",
        json!({"text":"original denied","ttl":60}),
        102,
    );
    let denied = s
        .execute("denied-before-reapply", &e, SPACE, DEVICE, REV, 102)
        .unwrap();
    assert_eq!(response(denied.clone())["error"], "pairing_not_approved");
    assert_eq!(
        execute(
            &mut s,
            &key(),
            &c,
            "pair",
            json!({"name":"冒名","reapply":true}),
            103
        )["error"],
        "identity_conflict"
    );
    assert_eq!(
        execute(&mut s, &k, &c, "pair", json!({"name":"手机"}), 104)["value"]["state"],
        "rejected"
    );
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "pair",
            json!({"name":"手机","reapply":true}),
            105
        )["value"]["state"],
        "pending"
    );
    s.approve(&c, true, 106).unwrap();
    assert_eq!(
        s.execute("denied-before-reapply", &e, SPACE, DEVICE, REV, 107)
            .unwrap(),
        denied
    );
    assert!(s.view(107).unwrap()["cards"].as_array().unwrap().is_empty());
}

#[test]
fn reapply_does_not_resurrect_old_sessions_or_other_peers_content() {
    let mut s = store();
    let k = key();
    let c = uuid::Uuid::new_v4().to_string();
    let other = uuid::Uuid::new_v4().to_string();
    paired(&mut s, &k, &c);
    paired(&mut s, &k, &other);
    for (client, id) in [(&c, "old"), (&other, "other")] {
        execute(
            &mut s,
            &k,
            client,
            "session_create",
            json!({"id":id,"text":"draft","ttl":200}),
            102,
        );
        execute(
            &mut s,
            &k,
            client,
            "content_put",
            json!({"id":id,"text":"note","sha256":limelink_runtime::hash(b"note"),"ttl":200}),
            103,
        );
    }
    execute(
        &mut s,
        &k,
        &c,
        "card",
        json!({"text":"cancelled","ttl":60}),
        104,
    );
    s.local_session("old", 1, "session_claim", None, 105)
        .unwrap();
    s.revoke(&c).unwrap();
    assert_eq!(
        execute(&mut s, &k, &c, "pair", json!({"name":"手机"}), 106)["value"]["state"],
        "revoked"
    );
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "pair",
            json!({"name":"手机","reapply":true}),
            107
        )["value"]["state"],
        "pending"
    );
    s.approve(&c, true, 108).unwrap();
    assert_eq!(
        execute(
            &mut s,
            &k,
            &c,
            "session_claim",
            json!({"id":"old","revision":2}),
            109
        )["error"],
        "session_not_found"
    );
    let view = s.view(109).unwrap();
    assert_eq!(view["cards"][0]["state"], "cancelled");
    assert_eq!(view["sessions"].as_array().unwrap().len(), 1);
    assert_eq!(view["sessions"][0]["id"], "other");
    assert_eq!(view["contents"].as_array().unwrap().len(), 1);
    assert_eq!(view["contents"][0]["id"], "other");
}
