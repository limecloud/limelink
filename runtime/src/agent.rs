//! Agent 运行记录属于产品；设备命令的受理与结果仍由 LimeIoT 记录。
use crate::{bounded, digest, maintain_content, parse, storage, Exchange, Result, Store};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

pub mod codex;
pub mod tools;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Workspace {
    pub id: String,
    pub name: String,
    pub path: PathBuf,
    #[serde(default)]
    pub allow_write: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub executable: PathBuf,
    pub workspaces: Vec<Workspace>,
    #[serde(default = "timeout")]
    pub timeout_seconds: u64,
    #[serde(default, skip_serializing_if = "is_false")]
    pub allow_iot_tools: bool,
}
fn is_false(value: &bool) -> bool {
    !value
}
fn timeout() -> u64 {
    600
}
impl Config {
    pub fn validate(mut self) -> Result<Self> {
        if !self.executable.is_absolute()
            || !(30..=1800).contains(&self.timeout_seconds)
            || !(1..=8).contains(&self.workspaces.len())
        {
            return Err("invalid_agent_config".into());
        }
        self.executable = self
            .executable
            .canonicalize()
            .map_err(|_| "agent_executable_unavailable")?;
        if !self.executable.is_file() {
            return Err("agent_executable_unavailable".into());
        }
        let mut ids = std::collections::HashSet::new();
        for workspace in &mut self.workspaces {
            if workspace.id.is_empty()
                || workspace.id.len() > 64
                || !workspace
                    .id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
                || !ids.insert(workspace.id.clone())
                || !workspace.path.is_absolute()
            {
                return Err("invalid_agent_workspace".into());
            }
            bounded(&workspace.name, 64)?;
            workspace.path = workspace
                .path
                .canonicalize()
                .map_err(|_| "agent_workspace_unavailable")?;
            if !workspace.path.is_dir() {
                return Err("agent_workspace_unavailable".into());
            }
        }
        Ok(self)
    }
    pub fn capabilities(&self) -> Value {
        json!({"adapter":"codex-app-server","configured":true,"authentication":"managed_by_codex","local_approval_required":true,"workspaces":self.workspaces.iter().map(|w|json!({"id":w.id,"name":w.name,"allow_write":w.allow_write})).collect::<Vec<_>>()})
    }
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Submit {
    id: String,
    workspace_id: String,
    text: String,
    sandbox: String,
    resume_from: Option<String>,
    #[serde(default)]
    iot_devices: Vec<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Query {
    id: String,
    #[serde(default)]
    after: i64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Target {
    id: String,
}

#[derive(Clone, Debug)]
pub struct Job {
    pub id: String,
    pub client: String,
    pub text: String,
    pub workspace: Workspace,
    pub sandbox: String,
    pub thread: Option<String>,
    pub config_digest: String,
    pub iot_devices: Vec<String>,
}
#[derive(Clone, Debug)]
pub enum Update {
    Tool {
        call: tools::ToolCall,
        reply: tokio::sync::mpsc::Sender<tools::ToolReply>,
    },
    Session {
        thread: String,
        turn: String,
    },
    Event {
        kind: String,
        text: String,
    },
    Finished {
        state: String,
        error: Option<String>,
    },
}
pub struct AgentStore {
    db: Connection,
    pub config: Config,
    revision: String,
    tool_replies: std::collections::HashMap<String, tokio::sync::mpsc::Sender<tools::ToolReply>>,
    content_cleanup_pending: bool,
    compaction_pending: bool,
    content_time: i64,
}
impl AgentStore {
    pub fn open(path: &Path, identity: &str, config: Config, now: i64) -> Result<Self> {
        let config = config.validate()?;
        let revision = digest(&config)?;
        let mut db = storage(Connection::open(path))?;
        storage(db.busy_timeout(std::time::Duration::from_secs(3)))?;
        let version: i64 = storage(db.query_row("PRAGMA user_version", [], |r| r.get(0)))?;
        if version > 2 {
            return Err("unsupported_agent_storage_version".into());
        }
        storage(db.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON;",
        ))?;
        let tx = storage(db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate))?;
        storage(tx.execute_batch("
            CREATE TABLE IF NOT EXISTS metadata(identity TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY,client TEXT NOT NULL,workspace TEXT NOT NULL,sandbox TEXT NOT NULL,prompt TEXT NOT NULL,digest TEXT NOT NULL,config TEXT NOT NULL,state TEXT NOT NULL,thread TEXT,turn TEXT,created INTEGER NOT NULL,deadline INTEGER NOT NULL,expires INTEGER NOT NULL,error TEXT);
            CREATE TABLE IF NOT EXISTS events(run TEXT NOT NULL,seq INTEGER NOT NULL,kind TEXT NOT NULL,text TEXT NOT NULL,PRIMARY KEY(run,seq));
            CREATE TABLE IF NOT EXISTS receipts(id TEXT PRIMARY KEY,digest TEXT NOT NULL,result TEXT NOT NULL,expires INTEGER NOT NULL,purged INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS nonces(client TEXT NOT NULL,nonce TEXT NOT NULL,PRIMARY KEY(client,nonce));"))?;
        let previous: Option<String> = storage(
            tx.query_row("SELECT identity FROM metadata", [], |r| r.get(0))
                .optional(),
        )?;
        match previous {
            Some(value) if value != identity => return Err("agent_identity_mismatch".into()),
            None => {
                storage(tx.execute("INSERT INTO metadata VALUES(?)", [identity]))?;
            }
            _ => {}
        }
        tools::initialize(&tx)?;
        // 进程重启不证明远端生成或工具已经停止；保留未知，不重新启动。
        storage(tx.execute("UPDATE runs SET state='unknown',error='agent_host_restarted' WHERE state IN ('starting','running','cancelling')", []))?;
        storage(tx.execute_batch("PRAGMA user_version=2"))?;
        storage(tx.commit())?;
        let mut store = Self {
            db,
            config,
            revision,
            tool_replies: Default::default(),
            content_cleanup_pending: true,
            // v2 没有记录过去是否启用安全删除；每次重开都整理旧空闲页，失败后继续重试。
            compaction_pending: version != 0,
            content_time: now,
        };
        store.expire(now)?;
        Ok(store)
    }
    pub fn execute(
        &mut self,
        command: &str,
        input: &Exchange,
        peers: &Store,
        space: &str,
        device: &str,
        model: &str,
        now: i64,
    ) -> Result<Value> {
        self.expire(now)?;
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
        input.verify(space, device, model, now)?;
        peers.authorize(input)?;
        if storage(tx.query_row("SELECT count(*) FROM receipts", [], |r| r.get::<_, i64>(0)))?
            >= 4096
        {
            return Err("receipt_capacity".into());
        }
        if storage(tx.query_row(
            "SELECT count(*) FROM nonces WHERE client=? AND nonce=?",
            params![input.client_id, input.nonce],
            |r| r.get::<_, i64>(0),
        ))? != 0
        {
            return Err("nonce_replayed".into());
        }
        storage(tx.execute_batch("SAVEPOINT agent_effect"))?;
        let outcome = Self::apply(&tx, &self.config, &self.revision, input, device, now);
        if outcome.is_err() {
            storage(tx.execute_batch("ROLLBACK TO agent_effect"))?;
        }
        storage(tx.execute_batch("RELEASE agent_effect"))?;
        if outcome
            .as_ref()
            .err()
            .is_some_and(|e| e == "storage_unavailable")
        {
            return Err("storage_unavailable".into());
        }
        let response = match outcome {
            Ok(value) => json!({"ok":true,"value":value}),
            Err(error) => json!({"ok":false,"error":error}),
        };
        if response.to_string().len() > 4096 {
            return Err("agent_response_budget".into());
        }
        let result = json!({"command_id":command,"status":"confirmed","evidence":{"type":"action_result","path":"agent.exchange","input_digest":request_digest,"output":{"response":response.to_string()},"completion":"submitted","observed_at":chrono::DateTime::from_timestamp(now,0).ok_or("invalid_time")?}});
        let expires = response["value"]["expires_at"]
            .as_i64()
            .unwrap_or(now + 3600)
            .min(now + 3600);
        storage(tx.execute(
            "INSERT INTO receipts(id,digest,result,expires) VALUES(?,?,?,?)",
            params![command, request_digest, result.to_string(), expires],
        ))?;
        storage(tx.execute(
            "INSERT INTO nonces VALUES(?,?)",
            params![input.client_id, input.nonce],
        ))?;
        storage(tx.commit())?;
        self.deliver_tool_replies()?;
        Ok(result)
    }
    fn apply(
        db: &Connection,
        config: &Config,
        revision: &str,
        input: &Exchange,
        device: &str,
        now: i64,
    ) -> Result<Value> {
        match input.kind.as_str() {
            "agent.capabilities" => {
                if input.payload != "{}" {
                    return Err("invalid_payload".into());
                }
                Ok(config.capabilities())
            }
            "agent.submit" => {
                let value: Submit = parse(&input.payload)?;
                tools::validate_grant(&value.iot_devices)?;
                if !value.iot_devices.is_empty()
                    && (!config.allow_iot_tools || value.iot_devices.iter().any(|id| id == device))
                {
                    return Err("agent_iot_tools_not_allowed".into());
                }
                uuid::Uuid::parse_str(&value.id).map_err(|_| "invalid_agent_run_id")?;
                bounded(&value.text, 2048)?;
                let workspace = config
                    .workspaces
                    .iter()
                    .find(|w| w.id == value.workspace_id)
                    .ok_or("agent_workspace_not_allowed")?;
                if value.sandbox != "read-only"
                    && !(value.sandbox == "workspace-write" && workspace.allow_write)
                {
                    return Err("agent_sandbox_not_allowed".into());
                }
                let run_digest =
                    digest(&json!({"client":input.client_id,"payload":value_as_json(&value)}))?;
                if let Some(old) = storage(
                    db.query_row("SELECT digest FROM runs WHERE id=?", [&value.id], |r| {
                        r.get::<_, String>(0)
                    })
                    .optional(),
                )? {
                    if old != run_digest {
                        return Err("agent_run_conflict".into());
                    }
                    return Self::status(db, &input.client_id, &value.id, 0, now);
                }
                if storage(db.query_row("SELECT count(*) FROM runs", [], |r| r.get::<_, i64>(0)))?
                    >= 128
                {
                    return Err("agent_run_capacity".into());
                }
                let thread = if let Some(previous) = &value.resume_from {
                    if tools::devices(db, previous)? != value.iot_devices {
                        return Err("agent_tool_scope_changed".into());
                    }
                    storage(db.query_row("SELECT thread FROM runs WHERE id=? AND client=? AND workspace=? AND sandbox=? AND config=? AND state='succeeded' AND expires>?", params![previous,input.client_id,workspace.id,value.sandbox,revision,now], |r|r.get::<_,Option<String>>(0)).optional())?.flatten().ok_or("agent_session_not_resumable")?.into()
                } else {
                    None
                };
                storage(db.execute(
                    "INSERT INTO runs VALUES(?,?,?,?,?,?,?,'awaiting_approval',?,NULL,?,?,?,NULL)",
                    params![
                        value.id,
                        input.client_id,
                        workspace.id,
                        value.sandbox,
                        value.text,
                        run_digest,
                        revision,
                        thread,
                        now,
                        now + 120,
                        now + 3600
                    ],
                ))?;
                if !value.iot_devices.is_empty() {
                    storage(db.execute(
                        "INSERT INTO tool_grants VALUES(?,?)",
                        params![
                                value.id,
                                serde_json::to_string(&value.iot_devices)
                                    .map_err(|_| "invalid_agent_devices")?
                            ],
                    ))?;
                }
                Self::status(db, &input.client_id, &value.id, 0, now)
            }
            "agent.tool_capabilities" => {
                if input.payload != "{}" {
                    return Err("invalid_payload".into());
                }
                Ok(
                    json!({"enabled":config.allow_iot_tools,"tools":["limeiot_read","limeiot_command"],"approval_required":true,"max_devices":4}),
                )
            }
            "agent.tool_pending" => tools::pending(
                db,
                &input.client_id,
                &parse::<Target>(&input.payload)?.id,
                now,
            ),
            "agent.tool_result" => tools::complete(db, &input.client_id, &input.payload, now),
            "agent.status" => {
                let query: Query = parse(&input.payload)?;
                Self::status(db, &input.client_id, &query.id, query.after, now)
            }
            "agent.cancel" => {
                let target: Target = parse(&input.payload)?;
                storage(db.execute("UPDATE runs SET state=CASE WHEN state IN ('awaiting_approval','approved') THEN 'cancelled' WHEN state IN ('starting','running') THEN 'cancelling' ELSE state END WHERE id=? AND client=?", params![target.id,input.client_id]))?;
                storage(db.execute("UPDATE tool_calls SET state='unknown' WHERE run IN (SELECT id FROM runs WHERE id=? AND client=? AND state='cancelling') AND state='pending'",params![target.id,input.client_id]))?;
                Self::status(db, &input.client_id, &target.id, 0, now)
            }
            _ => Err("unsupported_agent_operation".into()),
        }
    }
    fn status(db: &Connection, client: &str, id: &str, after: i64, now: i64) -> Result<Value> {
        if !(0..=256).contains(&after) {
            return Err("invalid_agent_cursor".into());
        }
        let row: Option<(String,String,String,Option<String>,Option<String>,i64)> = storage(db.query_row("SELECT state,workspace,sandbox,thread,error,expires FROM runs WHERE id=? AND client=?", params![id,client], |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))).optional())?;
        let (state, workspace, sandbox, thread, error, expires) =
            row.ok_or("agent_run_not_found")?;
        let mut statement = storage(db.prepare(
            "SELECT seq,kind,text FROM events WHERE run=? AND seq>? ORDER BY seq LIMIT 4",
        ))?;
        let events: Vec<Value> = storage(storage(statement.query_map(params![id,after], |r|Ok(json!({"seq":r.get::<_,i64>(0)?,"kind":r.get::<_,String>(1)?,"text":if expires>now {r.get::<_,String>(2)?}else{String::new()}}))))?.collect())?;
        let cursor = events
            .last()
            .and_then(|v| v["seq"].as_i64())
            .unwrap_or(after);
        Ok(
            json!({"id":id,"state":state,"workspace_id":workspace,"sandbox":sandbox,"session_id":thread,"error":error,"expires_at":expires,"events":events,"cursor":cursor}),
        )
    }
    pub fn approve(&mut self, id: &str, allowed: bool, now: i64) -> Result<()> {
        let changed = storage(self.db.execute("UPDATE runs SET state=? WHERE id=? AND state='awaiting_approval' AND deadline>? AND config=?", params![if allowed {"approved"}else{"rejected"},id,now,self.revision]))?;
        if changed != 1 {
            return Err("agent_approval_expired_or_consumed".into());
        }
        Ok(())
    }
    pub fn cancel(&mut self, id: &str) -> Result<()> {
        storage(self.db.execute("UPDATE runs SET state=CASE WHEN state IN ('awaiting_approval','approved') THEN 'cancelled' WHEN state IN ('starting','running') THEN 'cancelling' ELSE state END WHERE id=?", [id]))?;
        storage(self.db.execute(
            "UPDATE tool_calls SET state='unknown' WHERE run=? AND state='pending'",
            [id],
        ))?;
        self.deliver_tool_replies()?;
        Ok(())
    }
    pub fn cancelling(&self, id: &str) -> Result<bool> {
        Ok(storage(
            self.db
                .query_row("SELECT state FROM runs WHERE id=?", [id], |r| {
                    r.get::<_, String>(0)
                }),
        )? == "cancelling")
    }
    pub fn next(&mut self, peers: &Store, now: i64) -> Result<Option<Job>> {
        self.expire(now)?;
        let row: Option<(String,String,String,String,String,Option<String>,String)> = storage(self.db.query_row("SELECT id,client,workspace,sandbox,prompt,thread,config FROM runs WHERE state='approved' ORDER BY created,id LIMIT 1", [], |r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?))).optional())?;
        let Some((id, client, workspace, sandbox, text, thread, config_digest)) = row else {
            return Ok(None);
        };
        let paired: bool = storage(peers.db.query_row(
            "SELECT count(*) FROM peers WHERE id=? AND state='approved'",
            [&client],
            |r| r.get::<_, i64>(0),
        ))? == 1;
        if !paired || config_digest != self.revision {
            self.update(
                &id,
                Update::Finished {
                    state: "rejected".into(),
                    error: Some("agent_authorization_changed".into()),
                },
            )?;
            return Ok(None);
        }
        let workspace = self
            .config
            .workspaces
            .iter()
            .find(|w| w.id == workspace)
            .ok_or("agent_workspace_not_allowed")?
            .clone();
        if workspace.path.canonicalize().ok().as_ref() != Some(&workspace.path) {
            self.update(
                &id,
                Update::Finished {
                    state: "failed".into(),
                    error: Some("agent_workspace_changed".into()),
                },
            )?;
            return Ok(None);
        }
        storage(self.db.execute(
            "UPDATE runs SET state='starting' WHERE id=? AND state='approved'",
            [&id],
        ))?;
        let iot_devices = tools::devices(&self.db, &id)?;
        Ok(Some(Job {
            id,
            client,
            text,
            workspace,
            sandbox,
            thread,
            config_digest,
            iot_devices,
        }))
    }
    pub fn update(&mut self, id: &str, update: Update) -> Result<()> {
        match update {
            Update::Tool { call, reply } => {
                let tool_id = self.register_tool(id, &call, chrono::Utc::now().timestamp())?;
                self.tool_replies.insert(tool_id, reply);
            }
            Update::Session { thread, turn } => {
                bounded(&thread, 128)?;
                bounded(&turn, 128)?;
                storage(self.db.execute("UPDATE runs SET thread=?,turn=?,state=CASE WHEN state='cancelling' THEN state ELSE 'running' END WHERE id=? AND state IN ('starting','running','cancelling')", params![thread,turn,id]))?;
            }
            Update::Event { kind, text } => {
                if !["message", "tool_started", "tool_completed", "working"]
                    .contains(&kind.as_str())
                    || text.len() > 400
                {
                    return Err("invalid_agent_event".into());
                }
                // 到期维护后到达的旧消息不能把已清空正文重新写回。
                if storage(self.db.query_row(
                    "SELECT count(*) FROM runs WHERE id=? AND expires>?",
                    params![id, self.content_time],
                    |r| r.get::<_, i64>(0),
                ))? != 1
                {
                    return Err("agent_run_content_expired".into());
                }
                let seq: i64 = storage(self.db.query_row(
                    "SELECT coalesce(max(seq),0)+1 FROM events WHERE run=?",
                    [id],
                    |r| r.get(0),
                ))?;
                if seq > 256 {
                    return Err("agent_event_budget".into());
                }
                storage(self.db.execute(
                    "INSERT INTO events VALUES(?,?,?,?)",
                    params![id, seq, kind, text],
                ))?;
            }
            Update::Finished { state, error } => {
                let uncertain = tools::unresolved(&self.db, id)?;
                let (state, error) = if uncertain {
                    (
                        "unknown".to_string(),
                        Some("agent_tool_result_unknown".into()),
                    )
                } else {
                    (state, error)
                };
                if !["succeeded", "failed", "cancelled", "unknown", "rejected"]
                    .contains(&state.as_str())
                {
                    return Err("invalid_agent_state".into());
                }
                storage(self.db.execute("UPDATE runs SET state=?,error=? WHERE id=? AND state IN ('approved','starting','running','cancelling')", params![state,error,id]))?;
                storage(self.db.execute(
                    "UPDATE tool_calls SET state='unknown' WHERE run=? AND state='pending'",
                    [id],
                ))?;
                self.deliver_tool_replies()?;
            }
        }
        Ok(())
    }
    pub fn authorized(&self, id: &str, peers: &Store) -> Result<bool> {
        let client: String = storage(self.db.query_row(
            "SELECT client FROM runs WHERE id=?",
            [id],
            |r| r.get(0),
        ))?;
        Ok(storage(peers.db.query_row(
            "SELECT count(*) FROM peers WHERE id=? AND state='approved'",
            [client],
            |r| r.get::<_, i64>(0),
        ))? == 1)
    }
    pub fn view(&self, now: i64) -> Result<Value> {
        let mut statement = storage(self.db.prepare("SELECT id,client,workspace,sandbox,prompt,state,thread,error,expires FROM runs ORDER BY created DESC,id LIMIT 32"))?;
        let mut runs: Vec<Value> = storage(storage(statement.query_map([], |r| {
            let expires: i64 = r.get(8)?;
            let workspace: String = r.get(2)?;
            Ok(json!({
                "id": r.get::<_,String>(0)?, "client": r.get::<_,String>(1)?,
                "workspace_id": workspace,
                "workspace_path": self.config.workspaces.iter().find(|w|w.id==workspace).map(|w|&w.path),
                "sandbox": r.get::<_,String>(3)?,
                "text": if expires>now {r.get::<_,String>(4)?}else{String::new()},
                "state": r.get::<_,String>(5)?, "session_id": r.get::<_,Option<String>>(6)?,
                "iot_devices": if expires>now {tools::devices(&self.db, &r.get::<_,String>(0)?).map_err(|_|rusqlite::Error::InvalidQuery)?}else{Vec::new()},
                "error": r.get::<_,Option<String>>(7)?, "expires_at": expires
            }))
        }))?.collect())?;
        for run in &mut runs {
            if run["expires_at"]
                .as_i64()
                .is_none_or(|expires| expires <= now)
            {
                run["reply"] = json!("");
                run["reply_truncated"] = json!(false);
                continue;
            }
            let id = run["id"].as_str().ok_or("invalid_agent_run")?;
            let mut statement = storage(self.db.prepare(
                "SELECT text FROM events WHERE run=? AND kind='message' ORDER BY seq DESC LIMIT 10",
            ))?;
            let messages: Vec<String> =
                storage(storage(statement.query_map([id], |r| r.get(0)))?.collect())?;
            let count: i64 = storage(self.db.query_row(
                "SELECT count(*) FROM events WHERE run=? AND kind='message'",
                [id],
                |r| r.get(0),
            ))?;
            run["reply"] = json!(messages.into_iter().rev().collect::<String>());
            run["reply_truncated"] = json!(count > 10);
        }
        Ok(
            json!({"capabilities":self.config.capabilities(),"runs":runs,"content_cleanup_pending":self.content_cleanup_pending}),
        )
    }
    pub fn expire(&mut self, now: i64) -> Result<()> {
        let before: i64 = storage(
            self.db
                .query_row("SELECT total_changes()", [], |r| r.get(0)),
        )?;
        let tx = storage(
            self.db
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate),
        )?;
        tools::expire(&tx, now)?;
        storage(tx.execute("UPDATE runs SET state='expired' WHERE state IN ('awaiting_approval','approved') AND deadline<=?", [now]))?;
        storage(tx.execute(
            "UPDATE runs SET prompt='' WHERE expires<=? AND prompt!=''",
            [now],
        ))?;
        storage(tx.execute(
            "UPDATE events SET text='' WHERE text!='' AND run IN (SELECT id FROM runs WHERE expires<=?)",
            [now],
        ))?;
        let rows: Vec<(String, String)> = {
            let mut statement = storage(
                tx.prepare("SELECT id,result FROM receipts WHERE expires<=? AND purged=0"),
            )?;
            let mapped = storage(statement.query_map([now], |r| Ok((r.get(0)?, r.get(1)?))))?;
            storage(mapped.collect())?
        };
        for (id, raw) in rows {
            let mut result: Value = parse(&raw)?;
            let mut response: Value = parse(
                result["evidence"]["output"]["response"]
                    .as_str()
                    .ok_or("invalid_agent_receipt")?,
            )?;
            if let Some(events) = response["value"]["events"].as_array_mut() {
                for event in events {
                    event["text"] = json!("");
                }
            }
            // 工具提案也可能被原平台请求缓存，过期后不保留参数与设备范围。
            if response["value"].get("calls").is_some() {
                response["value"]["calls"] = json!([]);
                response["value"]["devices"] = json!([]);
            }
            if response["value"].is_object() {
                response["value"]["content_expired"] = json!(true);
            }
            result["evidence"]["output"]["response"] = json!(response.to_string());
            storage(tx.execute(
                "UPDATE receipts SET result=?,purged=1 WHERE id=?",
                params![result.to_string(), id],
            ))?;
        }
        storage(tx.commit())?;
        self.content_time = self.content_time.max(now);
        let after: i64 = storage(
            self.db
                .query_row("SELECT total_changes()", [], |r| r.get(0)),
        )?;
        self.content_cleanup_pending |= after != before;
        if self.content_cleanup_pending {
            self.content_cleanup_pending =
                maintain_content(&self.db, &mut self.compaction_pending, || Ok(()))?;
        }
        self.deliver_tool_replies()?;
        Ok(())
    }
}
fn value_as_json(value: &Submit) -> Value {
    let mut result = json!({"id":value.id,"workspace_id":value.workspace_id,"text":value.text,"sandbox":value.sandbox,"resume_from":value.resume_from});
    if !value.iot_devices.is_empty() {
        result["iot_devices"] = json!(value.iot_devices);
    }
    result
}
