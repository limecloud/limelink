//! 产品配对与本机效果日志；平台命令状态始终由 LimeIoT 拥有。
use ring::signature::{UnparsedPublicKey, ECDSA_P256_SHA256_ASN1};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
pub mod agent;

pub type Result<T> = std::result::Result<T, String>;
pub fn digest(value: &impl Serialize) -> Result<String> {
    Ok(format!(
        "sha256:{}",
        hex::encode(Sha256::digest(
            serde_jcs::to_vec(value).map_err(|_| "invalid_json")?
        ))
    ))
}
pub fn hash(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn storage<T>(value: rusqlite::Result<T>) -> Result<T> {
    value.map_err(|_| "storage_unavailable".into())
}
/// 清理当前文件与 WAL；占用旧快照的读者由后续维护重试，不阻塞等待。
fn maintain_content(
    db: &Connection,
    compact: &mut bool,
    on_compacted: impl FnOnce() -> Result<()>,
) -> Result<bool> {
    storage(db.busy_timeout(std::time::Duration::ZERO))?;
    let cleanup = (|| {
        if *compact {
            match db.execute_batch("VACUUM") {
                Ok(()) => {
                    on_compacted()?;
                    *compact = false;
                }
                Err(error)
                    if matches!(
                        error.sqlite_error_code(),
                        Some(
                            rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked
                        )
                    ) =>
                {
                    return Ok(true)
                }
                Err(_) => return Err("storage_unavailable".into()),
            }
        }
        Ok(
            storage(db.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |r| {
                r.get::<_, i64>(0)
            }))? != 0,
        )
    })();
    storage(db.busy_timeout(std::time::Duration::from_secs(3)))?;
    cleanup
}
fn parse<T: serde::de::DeserializeOwned>(value: &str) -> Result<T> {
    serde_json::from_str(value).map_err(|_| "invalid_payload".into())
}
fn bounded(text: &str, max: usize) -> Result<()> {
    if text.trim().is_empty() || text.len() > max || text.chars().any(|c| c == '\0') {
        Err("invalid_text".into())
    } else {
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Exchange {
    pub client_id: String,
    pub public_key: String,
    pub kind: String,
    pub nonce: String,
    pub expires_at: i64,
    pub payload: String,
    pub signature: String,
}
impl Exchange {
    pub fn message(&self, space: &str, device: &str, revision: &str) -> Vec<u8> {
        format!(
            "limelink.exchange/v1\n{space}\n{device}\n{revision}\n{}\n{}\n{}\n{}\n{}",
            self.client_id,
            self.kind,
            self.nonce,
            self.expires_at,
            hash(self.payload.as_bytes())
        )
        .into_bytes()
    }
    pub fn verify(&self, space: &str, device: &str, revision: &str, now: i64) -> Result<()> {
        if uuid::Uuid::parse_str(&self.client_id).is_err()
            || uuid::Uuid::parse_str(&self.nonce).is_err()
            || self.expires_at <= now
            || self.expires_at > now + 30
            || self.payload.len() > 4096
            || self.public_key.len() != 130
            || self.signature.len() > 144
        {
            return Err("invalid_exchange".into());
        }
        let key = hex::decode(&self.public_key).map_err(|_| "invalid_key")?;
        let signature = hex::decode(&self.signature).map_err(|_| "invalid_signature")?;
        UnparsedPublicKey::new(&ECDSA_P256_SHA256_ASN1, key)
            .verify(&self.message(space, device, revision), &signature)
            .map_err(|_| "invalid_signature".into())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Pair {
    name: String,
    #[serde(default)]
    reapply: bool,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Card {
    text: String,
    ttl: i64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Target {
    id: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SessionCreate {
    id: String,
    text: String,
    ttl: i64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SessionChange {
    id: String,
    revision: i64,
    text: Option<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Content {
    id: String,
    text: String,
    sha256: String,
    ttl: i64,
}

pub struct Store {
    db: Connection,
    content_cleanup_pending: bool,
    legacy_compaction_pending: bool,
}
impl Store {
    /// Agent 请求复用配对身份，但每次运行还需要执行主机单独批准。
    pub fn authorize(&self, input: &Exchange) -> Result<()> {
        let peer: Option<(String, String)> = storage(
            self.db
                .query_row(
                    "SELECT public_key,state FROM peers WHERE id=?",
                    [&input.client_id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional(),
        )?;
        let (key, state) = peer.ok_or("pairing_required")?;
        if key != input.public_key {
            return Err("identity_conflict".into());
        }
        if state != "approved" {
            return Err("pairing_not_approved".into());
        }
        Ok(())
    }
    pub fn open(path: &std::path::Path, identity: &str) -> Result<Self> {
        Self::open_with_migration(path, identity, false)
    }
    /// 旧格式升级由用户明确发起；清理正文仍保留原命令、摘要和防重放记录。
    pub fn migrate(path: &std::path::Path, identity: &str, now: i64) -> Result<Self> {
        let mut store = Self::open_with_migration(path, identity, true)?;
        store.expire_content(now)?;
        Ok(store)
    }
    fn open_with_migration(
        path: &std::path::Path,
        identity: &str,
        allow_migration: bool,
    ) -> Result<Self> {
        let mut db = storage(Connection::open(path))?;
        storage(db.busy_timeout(std::time::Duration::from_secs(3)))?;
        storage(db.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON;",
        ))?;
        let version: i64 = storage(db.query_row("PRAGMA user_version", [], |r| r.get(0)))?;
        if version > 2 {
            return Err("unsupported_storage_version".into());
        }
        if version == 1 && !allow_migration {
            return Err("storage_migration_required".into());
        }
        let tx = storage(db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate))?;
        storage(tx.execute_batch("
            CREATE TABLE IF NOT EXISTS metadata(identity TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS peers(id TEXT PRIMARY KEY, public_key TEXT NOT NULL, name TEXT NOT NULL, state TEXT NOT NULL, deadline INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS receipts(id TEXT PRIMARY KEY, digest TEXT NOT NULL, result TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS nonces(client TEXT NOT NULL, nonce TEXT NOT NULL, command TEXT NOT NULL, PRIMARY KEY(client,nonce));
            CREATE TABLE IF NOT EXISTS cards(id TEXT PRIMARY KEY, client TEXT NOT NULL, text TEXT NOT NULL, state TEXT NOT NULL, created INTEGER NOT NULL, expires INTEGER NOT NULL, presented INTEGER);
            CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, client TEXT NOT NULL, revision INTEGER NOT NULL, text TEXT NOT NULL, writer TEXT, lease_until INTEGER NOT NULL, expires INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS contents(id TEXT PRIMARY KEY, client TEXT NOT NULL, text TEXT NOT NULL, sha256 TEXT NOT NULL, expires INTEGER NOT NULL);"))?;
        let previous: Option<String> = storage(
            tx.query_row("SELECT identity FROM metadata", [], |r| r.get(0))
                .optional(),
        )?;
        match previous {
            Some(value) if value != identity => return Err("identity_mismatch".into()),
            None => {
                storage(tx.execute("INSERT INTO metadata(identity) VALUES(?)", [identity]))?;
            }
            _ => {}
        }
        if version < 2 {
            storage(tx.execute_batch(
                "ALTER TABLE receipts ADD COLUMN content_expires INTEGER;
                ALTER TABLE receipts ADD COLUMN content_purged INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE metadata ADD COLUMN content_compaction_pending INTEGER NOT NULL DEFAULT 0;",
            ))?;
            if version == 1 {
                storage(tx.execute("UPDATE metadata SET content_compaction_pending=1", []))?;
            }
            // v1 没有缓存正文的原始期限，且同名会话可能已经重建；不能用当前会话续期旧正文。
            let rows = Self::rows(&tx, "SELECT id,result FROM receipts WHERE ?=''", "", |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })?;
            for (id, raw) in rows {
                let response = Self::receipt_response(&raw)?;
                if response["value"]["text"].is_string() {
                    storage(tx.execute("UPDATE receipts SET content_expires=0 WHERE id=?", [id]))?;
                }
            }
        }
        storage(tx.execute_batch("CREATE INDEX IF NOT EXISTS receipt_content_expiry ON receipts(content_expires) WHERE content_purged=0;
            PRAGMA user_version=2;"))?;
        let legacy_compaction_pending = storage(tx.query_row(
            "SELECT content_compaction_pending FROM metadata",
            [],
            |r| r.get::<_, bool>(0),
        ))?;
        storage(tx.commit())?;
        Ok(Self {
            db,
            content_cleanup_pending: true,
            legacy_compaction_pending,
        })
    }
    fn receipt_response(raw: &str) -> Result<Value> {
        let result: Value = parse(raw)?;
        parse(
            result["evidence"]["output"]["response"]
                .as_str()
                .ok_or("invalid_receipt")?,
        )
    }
    /// 同一平台命令只变更一次本机状态。结果与效果意图在同一耐久事务提交。
    pub fn execute(
        &mut self,
        command: &str,
        input: &Exchange,
        space: &str,
        device: &str,
        revision: &str,
        now: i64,
    ) -> Result<Value> {
        // 重放原命令同样遵守正文期限，不能在两次心跳之间读回已过期正文。
        self.expire_content(now)?;
        let request_digest = digest(input)?;
        let tx = storage(
            self.db
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate),
        )?;
        if let Some((old, result)) = storage(
            tx.query_row(
                "SELECT digest,result FROM receipts WHERE id=?",
                [command],
                |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
            )
            .optional(),
        )? {
            if old != request_digest {
                return Err("duplicate_conflict".into());
            }
            return parse(&result);
        }
        input.verify(space, device, revision, now)?;
        let count: i64 = storage(tx.query_row("SELECT count(*) FROM receipts", [], |r| r.get(0)))?;
        if count >= 4096 {
            return Err("receipt_capacity".into());
        }
        let used: Option<String> = storage(
            tx.query_row(
                "SELECT command FROM nonces WHERE client=? AND nonce=?",
                params![input.client_id, input.nonce],
                |r| r.get(0),
            )
            .optional(),
        )?;
        if used.is_some() {
            return Err("nonce_replayed".into());
        }
        storage(tx.execute_batch("SAVEPOINT product_effect"))?;
        let outcome = Self::apply(&tx, command, input, now);
        if outcome.is_err() {
            storage(tx.execute_batch("ROLLBACK TO product_effect"))?;
        }
        storage(tx.execute_batch("RELEASE product_effect"))?;
        if outcome
            .as_ref()
            .err()
            .is_some_and(|code| code == "storage_unavailable")
        {
            return Err("storage_unavailable".into());
        }
        // 拒绝也保留原结果，后续撤销/重新批准不能使原请求突然生效。
        let response = match outcome {
            Ok(value) => json!({"ok":true,"value":value}),
            Err(code) => json!({"ok":false,"error":code}),
        };
        let result = json!({"command_id":command,"status":"confirmed","evidence":{"type":"action_result","path":"link.exchange","input_digest":request_digest,"output":{"response":response.to_string()},"completion":"submitted","observed_at":chrono::DateTime::from_timestamp(now,0).ok_or("invalid_time")?}});
        let content_expires: Option<i64> = if response["value"]["text"].is_string() {
            let session = response["value"]["id"].as_str().ok_or("invalid_receipt")?;
            Some(storage(tx.query_row(
                "SELECT expires FROM sessions WHERE id=?",
                [session],
                |r| r.get(0),
            ))?)
        } else {
            None
        };
        storage(tx.execute(
            "INSERT INTO receipts(id,digest,result,content_expires) VALUES(?,?,?,?)",
            params![command, request_digest, result.to_string(), content_expires],
        ))?;
        storage(tx.execute(
            "INSERT INTO nonces VALUES(?,?,?)",
            params![input.client_id, input.nonce, command],
        ))?;
        storage(tx.commit())?;
        Ok(result)
    }
    fn apply(tx: &Transaction<'_>, command: &str, input: &Exchange, now: i64) -> Result<Value> {
        let peer: Option<(String, String, i64)> = storage(
            tx.query_row(
                "SELECT public_key,state,deadline FROM peers WHERE id=?",
                [&input.client_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional(),
        )?;
        if let Some((key, _, _)) = &peer {
            if key != &input.public_key {
                return Err("identity_conflict".into());
            }
        }
        if input.kind == "pair" {
            let pair: Pair = parse(&input.payload)?;
            bounded(&pair.name, 64)?;
            if let Some((_, state, deadline)) = peer {
                let inactive = state != "approved" && (state != "pending" || deadline <= now);
                if !pair.reapply || !inactive {
                    return Ok(
                        json!({"state":if state=="pending" && deadline<=now {"expired"} else {&state},"client_id":input.client_id,"expires_at":deadline,"fingerprint":hash(input.public_key.as_bytes())}),
                    );
                }
                // 明确重配建立新批准周期，不复活旧会话或内容；历史回执保持原事实。
                storage(tx.execute(
                    "UPDATE cards SET state='cancelled' WHERE client=? AND state='queued'",
                    [&input.client_id],
                ))?;
                storage(tx.execute("DELETE FROM sessions WHERE client=?", [&input.client_id]))?;
                storage(tx.execute("DELETE FROM contents WHERE client=?", [&input.client_id]))?;
                storage(tx.execute(
                    "UPDATE peers SET name=?,state='pending',deadline=? WHERE id=?",
                    params![pair.name, now + 120, input.client_id],
                ))?;
                return Ok(
                    json!({"state":"pending","client_id":input.client_id,"expires_at":now+120,"fingerprint":hash(input.public_key.as_bytes())}),
                );
            }
            let count: i64 = storage(tx.query_row("SELECT count(*) FROM peers", [], |r| r.get(0)))?;
            if count >= 16 {
                return Err("pairing_capacity".into());
            }
            storage(tx.execute(
                "INSERT INTO peers VALUES(?,?,?,'pending',?)",
                params![input.client_id, input.public_key, pair.name, now + 120],
            ))?;
            return Ok(
                json!({"state":"pending","client_id":input.client_id,"expires_at":now+120,"fingerprint":hash(input.public_key.as_bytes())}),
            );
        }
        let (_, state, deadline) = peer.ok_or("pairing_required")?;
        if input.kind == "status" {
            if input.payload != "{}" {
                return Err("invalid_payload".into());
            }
            let cards = Self::rows(
                tx,
                "SELECT id,state,expires FROM cards WHERE client=? ORDER BY created DESC LIMIT 12",
                &input.client_id,
                |r| {
                    Ok(
                        json!({"id":r.get::<_,String>(0)?,"state":r.get::<_,String>(1)?,"expires_at":r.get::<_,i64>(2)?}),
                    )
                },
            )?;
            let sessions = Self::rows(
                tx,
                "SELECT id,revision,expires FROM sessions WHERE client=? ORDER BY id LIMIT 12",
                &input.client_id,
                |r| {
                    Ok(
                        json!({"id":r.get::<_,String>(0)?,"revision":r.get::<_,i64>(1)?,"expires_at":r.get::<_,i64>(2)?}),
                    )
                },
            )?;
            return Ok(
                json!({"state":if state=="pending"&&deadline<=now {"expired"}else{&state},"cards":cards,"sessions":sessions}),
            );
        }
        if state != "approved" {
            return Err("pairing_not_approved".into());
        }
        match input.kind.as_str() {
            "revoke" => {
                if input.payload != "{}" {
                    return Err("invalid_payload".into());
                }
                storage(tx.execute(
                    "UPDATE peers SET state='revoked' WHERE id=?",
                    [&input.client_id],
                ))?;
                storage(tx.execute(
                    "UPDATE cards SET state='cancelled' WHERE client=? AND state='queued'",
                    [&input.client_id],
                ))?;
                storage(tx.execute(
                    "UPDATE sessions SET writer=NULL,lease_until=0 WHERE client=?",
                    [&input.client_id],
                ))?;
                Ok(json!({"state":"revoked"}))
            }
            "card" => {
                let card: Card = parse(&input.payload)?;
                bounded(&card.text, 2048)?;
                if !(1..=86400).contains(&card.ttl) {
                    return Err("invalid_ttl".into());
                }
                let count: i64 =
                    storage(tx.query_row("SELECT count(*) FROM cards", [], |r| r.get(0)))?;
                if count >= 256 {
                    return Err("card_capacity".into());
                }
                storage(tx.execute(
                    "INSERT INTO cards VALUES(?,?,?,'queued',?,?,NULL)",
                    params![command, input.client_id, card.text, now, now + card.ttl],
                ))?;
                Ok(json!({"id":command,"presentation":"queued"}))
            }
            "cancel" => {
                let target: Target = parse(&input.payload)?;
                let state: Option<String> = storage(
                    tx.query_row(
                        "SELECT state FROM cards WHERE id=? AND client=?",
                        params![target.id, input.client_id],
                        |r| r.get(0),
                    )
                    .optional(),
                )?;
                let state = state.ok_or("card_not_found")?;
                if state == "queued" {
                    storage(tx.execute(
                        "UPDATE cards SET state='cancelled' WHERE id=?",
                        [&target.id],
                    ))?;
                }
                Ok(json!({"state":if state=="queued" {"cancelled"}else{&state},"id":target.id}))
            }
            "session_create" => {
                let s: SessionCreate = parse(&input.payload)?;
                bounded(&s.id, 64)?;
                bounded(&s.text, 2048)?;
                if !(1..=3600).contains(&s.ttl) {
                    return Err("invalid_ttl".into());
                }
                let count: i64 =
                    storage(tx.query_row("SELECT count(*) FROM sessions", [], |r| r.get(0)))?;
                if count >= 64 {
                    return Err("session_capacity".into());
                }
                if storage(tx.query_row(
                    "SELECT count(*) FROM sessions WHERE id=?",
                    [&s.id],
                    |r| r.get::<_, i64>(0),
                ))? != 0
                {
                    return Err("session_exists".into());
                }
                storage(tx.execute(
                    "INSERT INTO sessions VALUES(?,?,1,?,NULL,0,?)",
                    params![s.id, input.client_id, s.text, now + s.ttl],
                ))?;
                Ok(json!({"id":s.id,"revision":1}))
            }
            "session_claim" | "session_write" | "session_release" => {
                let s: SessionChange = parse(&input.payload)?;
                let row:Option<(String,i64,String,Option<String>,i64,i64)>=storage(tx.query_row("SELECT client,revision,text,writer,lease_until,expires FROM sessions WHERE id=?",[&s.id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))).optional())?;
                let (owner, revision, text, writer, lease, expires) =
                    row.ok_or("session_not_found")?;
                if owner != input.client_id {
                    return Err("forbidden".into());
                }
                if expires <= now {
                    return Err("session_expired".into());
                }
                if revision != s.revision {
                    return Err("revision_conflict".into());
                }
                let next = revision.checked_add(1).ok_or("revision_capacity")?;
                if input.kind == "session_claim" {
                    if s.text.is_some() {
                        return Err("invalid_payload".into());
                    }
                    if lease > now && writer.as_deref() != Some(&input.client_id) {
                        return Err("writer_busy".into());
                    }
                    storage(tx.execute(
                        "UPDATE sessions SET revision=?,writer=?,lease_until=? WHERE id=?",
                        params![next, input.client_id, now + 30, s.id],
                    ))?;
                    Ok(json!({"id":s.id,"revision":next,"text":text,"lease_until":now+30}))
                } else if input.kind == "session_write" {
                    if writer.as_deref() != Some(&input.client_id) || lease <= now {
                        return Err("lease_expired".into());
                    }
                    let text = s.text.ok_or("invalid_payload")?;
                    bounded(&text, 2048)?;
                    storage(tx.execute(
                        "UPDATE sessions SET revision=?,text=? WHERE id=?",
                        params![next, text, s.id],
                    ))?;
                    Ok(json!({"id":s.id,"revision":next}))
                } else {
                    if s.text.is_some() {
                        return Err("invalid_payload".into());
                    }
                    if lease > now && writer.as_deref() != Some(&input.client_id) {
                        return Err("writer_busy".into());
                    }
                    storage(tx.execute(
                        "UPDATE sessions SET revision=?,writer=NULL,lease_until=0 WHERE id=?",
                        params![next, s.id],
                    ))?;
                    Ok(json!({"id":s.id,"revision":next}))
                }
            }
            "content_put" => {
                let c: Content = parse(&input.payload)?;
                bounded(&c.id, 64)?;
                bounded(&c.text, 2048)?;
                if c.sha256 != hash(c.text.as_bytes()) || !(1..=86400).contains(&c.ttl) {
                    return Err("invalid_content".into());
                }
                let existing: Option<String> = storage(
                    tx.query_row("SELECT client FROM contents WHERE id=?", [&c.id], |r| {
                        r.get(0)
                    })
                    .optional(),
                )?;
                if existing.as_ref().is_some_and(|id| id != &input.client_id) {
                    return Err("forbidden".into());
                }
                let count: i64 =
                    storage(tx.query_row("SELECT count(*) FROM contents", [], |r| r.get(0)))?;
                if existing.is_none() && count >= 64 {
                    return Err("content_capacity".into());
                }
                storage(tx.execute("INSERT INTO contents VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET text=excluded.text,sha256=excluded.sha256,expires=excluded.expires",params![c.id,input.client_id,c.text,c.sha256,now+c.ttl]))?;
                Ok(json!({"id":c.id,"expires_at":now+c.ttl}))
            }
            "content_remove" => {
                let t: Target = parse(&input.payload)?;
                storage(tx.execute(
                    "DELETE FROM contents WHERE id=? AND client=?",
                    params![t.id, input.client_id],
                ))?;
                Ok(json!({"id":t.id,"removed":true}))
            }
            _ => Err("unsupported_operation".into()),
        }
    }
    fn rows<T>(
        db: &Connection,
        sql: &str,
        id: &str,
        mut map: impl FnMut(&rusqlite::Row<'_>) -> rusqlite::Result<T>,
    ) -> Result<Vec<T>> {
        let mut statement = storage(db.prepare(sql))?;
        let rows = storage(statement.query_map([id], |row| map(row)))?;
        storage(rows.collect())
    }
    pub fn approve(&mut self, id: &str, approve: bool, now: i64) -> Result<()> {
        let changed = storage(self.db.execute(
            "UPDATE peers SET state=? WHERE id=? AND state='pending' AND deadline>?",
            params![if approve { "approved" } else { "rejected" }, id, now],
        ))?;
        if changed != 1 {
            return Err("pairing_expired_or_consumed".into());
        }
        Ok(())
    }
    pub fn revoke(&mut self, id: &str) -> Result<()> {
        let tx = storage(self.db.transaction())?;
        storage(tx.execute("UPDATE peers SET state='revoked' WHERE id=?", [id]))?;
        storage(tx.execute(
            "UPDATE cards SET state='cancelled' WHERE client=? AND state='queued'",
            [id],
        ))?;
        storage(tx.execute(
            "UPDATE sessions SET writer=NULL,lease_until=0 WHERE client=?",
            [id],
        ))?;
        storage(tx.commit())
    }
    pub fn presented(&mut self, id: &str, now: i64) -> Result<()> {
        storage(self.db.execute("UPDATE cards SET state='presented',presented=? WHERE id=? AND state='queued' AND expires>? AND EXISTS(SELECT 1 FROM peers WHERE peers.id=cards.client AND peers.state='approved')",params![now,id,now]))?;
        Ok(())
    }
    pub fn local_session(
        &mut self,
        id: &str,
        expected: i64,
        operation: &str,
        text: Option<&str>,
        now: i64,
    ) -> Result<()> {
        let tx = storage(
            self.db
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate),
        )?;
        let row:Option<(i64,Option<String>,i64,i64)>=storage(tx.query_row("SELECT revision,writer,lease_until,expires FROM sessions WHERE id=? AND EXISTS(SELECT 1 FROM peers WHERE peers.id=sessions.client AND peers.state='approved')",[id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional())?;
        let (revision, writer, lease, expires) = row.ok_or("session_not_found")?;
        if expires <= now {
            return Err("session_expired".into());
        }
        if revision != expected {
            return Err("revision_conflict".into());
        }
        let next = revision.checked_add(1).ok_or("revision_capacity")?;
        match operation {
            "session_claim" => {
                if lease > now && writer.as_deref() != Some("local-desktop") {
                    return Err("writer_busy".into());
                }
                storage(tx.execute("UPDATE sessions SET revision=?,writer='local-desktop',lease_until=? WHERE id=?",params![next,now+30,id]))?;
            }
            "session_write" => {
                if writer.as_deref() != Some("local-desktop") || lease <= now {
                    return Err("lease_expired".into());
                }
                let text = text.ok_or("invalid_payload")?;
                bounded(text, 2048)?;
                storage(tx.execute(
                    "UPDATE sessions SET revision=?,text=? WHERE id=?",
                    params![next, text, id],
                ))?;
            }
            "session_release" => {
                if lease > now && writer.as_deref() != Some("local-desktop") {
                    return Err("writer_busy".into());
                }
                storage(tx.execute(
                    "UPDATE sessions SET revision=?,writer=NULL,lease_until=0 WHERE id=?",
                    params![next, id],
                ))?;
            }
            _ => return Err("unsupported_local_operation".into()),
        }
        storage(tx.commit())
    }
    pub fn view(&self, now: i64) -> Result<Value> {
        let peers = Self::rows(
            &self.db,
            "SELECT id,name,public_key,state,deadline FROM peers WHERE ?='' ORDER BY id",
            "",
            |r| {
                let key: String = r.get(2)?;
                let state: String = r.get(3)?;
                let deadline: i64 = r.get(4)?;
                Ok(
                    json!({"id":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"fingerprint":hash(key.as_bytes()),"state":if state=="pending"&&deadline<=now {"expired"}else{&state},"expires_at":deadline}),
                )
            },
        )?;
        let cards = Self::rows(
            &self.db,
            "SELECT id,text,state,expires FROM cards WHERE ?='' ORDER BY created DESC,id LIMIT 64",
            "",
            |r| {
                let text: String = r.get(1)?;
                let state: String = r.get(2)?;
                let expires: i64 = r.get(3)?;
                Ok(
                    json!({"id":r.get::<_,String>(0)?,"text":if expires>now{&text}else{""},"state":if expires<=now{"expired"}else{&state},"expires_at":expires}),
                )
            },
        )?;
        let contents = Self::rows(
            &self.db,
            "SELECT id,text,expires FROM contents WHERE ?='' ORDER BY id",
            "",
            |r| {
                let expires: i64 = r.get(2)?;
                Ok(
                    json!({"id":r.get::<_,String>(0)?,"text":if expires>now{r.get::<_,String>(1)?}else{String::new()},"stale":expires<=now}),
                )
            },
        )?;
        let sessions=Self::rows(&self.db,"SELECT id,revision,text,writer,lease_until,expires FROM sessions WHERE ?='' ORDER BY id","",|r|{let expires:i64=r.get(5)?;Ok(json!({"id":r.get::<_,String>(0)?,"revision":r.get::<_,i64>(1)?,"text":if expires>now{r.get::<_,String>(2)?}else{String::new()},"writer":r.get::<_,Option<String>>(3)?,"lease_until":r.get::<_,i64>(4)?,"expired":expires<=now}))})?;
        Ok(
            json!({"type":"view","peers":peers,"cards":cards,"contents":contents,"sessions":sessions,"content_cleanup_pending":self.content_cleanup_pending}),
        )
    }
    pub fn expire_content(&mut self, now: i64) -> Result<()> {
        let tx = storage(
            self.db
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate),
        )?;
        let mut changed = storage(tx.execute("UPDATE cards SET text='',state=CASE WHEN state='queued' THEN 'expired' ELSE state END WHERE expires<=? AND text!=''",[now]))?;
        changed += storage(tx.execute(
            "UPDATE contents SET text='' WHERE expires<=? AND text!=''",
            [now],
        ))?;
        changed += storage(tx.execute(
            "UPDATE sessions SET text='',writer=NULL,lease_until=0 WHERE expires<=? AND text!=''",
            [now],
        ))?;
        let rows: Vec<(String, String)> = {
            let mut statement = storage(tx.prepare(
                "SELECT id,result FROM receipts WHERE content_purged=0 AND content_expires<=?",
            ))?;
            let mapped = storage(statement.query_map([now], |r| Ok((r.get(0)?, r.get(1)?))))?;
            storage(mapped.collect())?
        };
        for (id, raw) in rows {
            let mut result: Value = parse(&raw)?;
            let mut response = Self::receipt_response(&raw)?;
            response["value"]["text"] = json!("");
            response["value"]["content_expired"] = json!(true);
            result["evidence"]["output"]["response"] = json!(response.to_string());
            changed += storage(tx.execute(
                "UPDATE receipts SET result=?,content_purged=1 WHERE id=?",
                params![result.to_string(), id],
            ))?;
        }
        storage(tx.commit())?;
        self.content_cleanup_pending |= changed > 0;
        if self.content_cleanup_pending {
            self.content_cleanup_pending =
                maintain_content(&self.db, &mut self.legacy_compaction_pending, || {
                    storage(
                        self.db
                            .execute("UPDATE metadata SET content_compaction_pending=0", []),
                    )?;
                    Ok(())
                })?;
        }
        Ok(())
    }
}

/// 只读导出计数与存储版本，不包含正文、配对公钥、设备凭据或磁盘路径。
pub fn diagnostics(path: &std::path::Path) -> Result<Value> {
    let db = storage(Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    ))?;
    let mut counts = serde_json::Map::new();
    for table in ["peers", "receipts", "cards", "sessions", "contents"] {
        let count: i64 =
            storage(db.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0)))?;
        counts.insert(table.into(), json!(count));
    }
    let version: i64 = storage(db.query_row("PRAGMA user_version", [], |r| r.get(0)))?;
    Ok(
        json!({"product":"LimeLink","version":"0.1.0","schema_version":version,"counts":counts,"credentials_included":false,"content_included":false}),
    )
}
