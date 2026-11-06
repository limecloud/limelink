use chrono::Utc;
use fs2::FileExt;
use limelink_runtime::agent::{self, AgentStore, Update};
use limelink_runtime::{Exchange, Store};
use rumqttc::{
    v5::{
        mqttbytes::{v5::Packet, QoS},
        AsyncClient, Event, MqttOptions,
    },
    Transport,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{io::Write, path::PathBuf, time::Duration};
use tokio::io::{AsyncBufReadExt, BufReader};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Config {
    mqtt_host: String,
    mqtt_port: u16,
    space: String,
    device: String,
    model_revision: String,
    database: PathBuf,
    ca: Option<PathBuf>,
    certificate: Option<PathBuf>,
    private_key: Option<PathBuf>,
    #[serde(default)]
    allow_loopback_development: bool,
    development_password: Option<String>,
    agent: Option<agent::Config>,
}
#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
struct Envelope {
    v: u8,
    kind: String,
    message_id: String,
    device_id: String,
    model_revision: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    boot_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    seq: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    session_id: Option<String>,
    body: Value,
}
struct Device {
    config: Config,
    boot: String,
    seq: u64,
    session: Option<String>,
    challenge: String,
    snapshot: u64,
}
fn id() -> String {
    uuid::Uuid::new_v4().to_string()
}
impl Device {
    async fn publish(
        &mut self,
        client: &AsyncClient,
        kind: &str,
        body: Value,
    ) -> Result<(), Box<dyn std::error::Error>> {
        self.seq += 1;
        let message = Envelope {
            v: 1,
            kind: kind.into(),
            message_id: id(),
            device_id: self.config.device.clone(),
            model_revision: self.config.model_revision.clone(),
            boot_id: Some(self.boot.clone()),
            seq: Some(self.seq),
            session_id: self.session.clone(),
            body,
        };
        client
            .publish(
                format!(
                    "limeiot/v1/{}/{}/up/{kind}",
                    self.config.space, self.config.device
                ),
                QoS::AtLeastOnce,
                false,
                serde_json::to_vec(&message)?,
            )
            .await?;
        Ok(())
    }
    async fn snapshot(&mut self, client: &AsyncClient) -> Result<(), Box<dyn std::error::Error>> {
        self.snapshot += 1;
        self.publish(
            client,
            "state",
            json!({"type":"snapshot","revision":self.snapshot,"properties":[]}),
        )
        .await
    }
}
fn emit(value: &Value) {
    println!("{value}");
    let _ = std::io::stdout().flush();
}
fn local_id(value: &Value) -> Option<&str> {
    value["id"].as_str().filter(|s| s.len() <= 128)
}
fn view(store: &Store, agent: Option<&AgentStore>, now: i64) -> Result<Value, String> {
    let mut value = store.view(now)?;
    if let Some(agent) = agent {
        value["agent"] = agent.view(now)?;
    }
    Ok(value)
}
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = std::env::args_os().skip(1);
    let first = arguments
        .next()
        .ok_or("usage: limelink-runtime [--diagnostics|--migrate-storage] CONFIG.json")?;
    let diagnostic = first == "--diagnostics";
    let migration = first == "--migrate-storage";
    let config_path = if diagnostic || migration {
        arguments.next().ok_or("missing_configuration")?
    } else {
        first
    };
    let config: Config = serde_json::from_slice(&std::fs::read(config_path)?)?;
    if diagnostic {
        emit(&limelink_runtime::diagnostics(&config.database)?);
        return Ok(());
    }
    for identifier in [&config.device, &config.space] {
        if identifier.is_empty()
            || identifier.len() > 128
            || !identifier
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"-_.:".contains(&b))
        {
            return Err("invalid_identity".into());
        }
    }
    if !config.model_revision.starts_with("sha256:") || config.model_revision.len() != 71 {
        return Err("invalid_revision".into());
    }
    if let Some(parent) = config.database.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let lock = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(config.database.with_extension("lock"))?;
    lock.try_lock_exclusive()
        .map_err(|_| "runtime_already_running")?;
    let identity = format!(
        "{}\n{}\n{}",
        config.space, config.device, config.model_revision
    );
    let mut store = if migration {
        Store::migrate(&config.database, &identity, Utc::now().timestamp())?
    } else {
        Store::open(&config.database, &identity)?
    };
    if migration {
        emit(
            &json!({"type":"storage_migration","schema_version":2,"content_cleanup_pending":store.view(Utc::now().timestamp())?["content_cleanup_pending"]}),
        );
        return Ok(());
    }
    let mut agent_store = config
        .agent
        .clone()
        .map(|settings| {
            AgentStore::open(
                &config.database.with_extension("agent.sqlite"),
                &identity,
                settings,
                Utc::now().timestamp(),
            )
        })
        .transpose()?;
    let (agent_updates, mut updates) = tokio::sync::mpsc::channel::<(String, Update)>(32);
    let mut active_agent: Option<(
        String,
        tokio::sync::watch::Sender<bool>,
        tokio::task::JoinHandle<()>,
    )> = None;
    let mut options = MqttOptions::new(&config.device, &config.mqtt_host, config.mqtt_port);
    options.set_keep_alive(Duration::from_secs(10));
    options.set_max_packet_size(Some(17000));
    match (&config.ca, &config.certificate, &config.private_key) {
        (Some(ca), Some(cert), Some(key)) => options.set_transport(Transport::tls(
            std::fs::read(ca)?,
            Some((std::fs::read(cert)?, std::fs::read(key)?)),
            None,
        )),
        (None, None, None)
            if config.allow_loopback_development && config.mqtt_host == "127.0.0.1" =>
        {
            options.set_credentials(
                &config.device,
                config
                    .development_password
                    .as_deref()
                    .ok_or("missing_development_password")?,
            );
            &mut options
        }
        _ => return Err("device_mtls_required".into()),
    };
    let mut device = Device {
        config,
        boot: id(),
        seq: 0,
        session: None,
        challenge: id(),
        snapshot: 0,
    };
    let (client, mut eventloop) = AsyncClient::new(options, 32);
    let mut input = BufReader::new(tokio::io::stdin()).lines();
    let mut heartbeat = tokio::time::interval(Duration::from_secs(2));
    emit(&view(&store, agent_store.as_ref(), Utc::now().timestamp())?);
    loop {
        tokio::select! {
            _=heartbeat.tick()=>{
                store.expire_content(Utc::now().timestamp())?;
                if let Some(agent)=agent_store.as_mut(){
                    agent.expire(Utc::now().timestamp())?;
                    if active_agent.as_ref().is_some_and(|(_,_,task)|task.is_finished()) && updates.is_empty(){
                        if let Some((id,_,task))=active_agent.take(){
                            let _=task.await;
                            agent.update(&id,Update::Finished{state:"unknown".into(),error:Some("agent_worker_stopped_without_result".into())})?;
                        }
                    }
                    if let Some((id,cancel,_))=&active_agent{if !agent.authorized(id,&store)?{agent.cancel(id)?;}if agent.cancelling(id)?{let _=cancel.send(true);}}
                    if active_agent.is_none(){if let Some(job)=agent.next(&store,Utc::now().timestamp())?{
                        let (cancel,receiver)=tokio::sync::watch::channel(false);
                        let id=job.id.clone();let settings=agent.config.clone();let sender=agent_updates.clone();
                        active_agent=Some((id,cancel,tokio::spawn(agent::codex::run(settings,job,receiver,sender))));
                    }}
                }
                if device.session.is_some(){device.snapshot(&client).await?;}
                emit(&view(&store,agent_store.as_ref(),Utc::now().timestamp())?);
            },
            update=updates.recv()=>{if let Some((id,update))=update{
                let finished=matches!(&update,Update::Finished{..});
                if let Some(agent)=agent_store.as_mut(){if let Err(code)=agent.update(&id,update){
                    if let Some((_,cancel,_))=&active_agent{let _=cancel.send(true);}
                    agent.update(&id,Update::Finished{state:"unknown".into(),error:Some(code.clone())})?;
                    emit(&json!({"type":"error","code":code}));
                }}
                if finished && active_agent.as_ref().is_some_and(|(active,_,_)|active==&id){if let Some((_,_,task))=active_agent.take(){let _=task.await;}}
                emit(&view(&store,agent_store.as_ref(),Utc::now().timestamp())?);
            }},
            line=input.next_line()=>{
                let Some(line)=line? else {break;};
                if line.len()>8192 {continue;}
                let Ok(value)=serde_json::from_str::<Value>(&line) else {continue;};
                let result=match (value["type"].as_str(),local_id(&value)) {
                    (Some("approve"),Some(id))=>store.approve(id,true,Utc::now().timestamp()),
                    (Some("reject"),Some(id))=>store.approve(id,false,Utc::now().timestamp()),
                    (Some("revoke"),Some(id))=>store.revoke(id),
                    (Some("presented"),Some(id))=>store.presented(id,Utc::now().timestamp()),
                    (Some("agent_approve"),Some(id))=>match agent_store.as_mut(){Some(agent)=>agent.approve(id,true,Utc::now().timestamp()),None=>Err("agent_not_configured".into())},
                    (Some("agent_reject"),Some(id))=>match agent_store.as_mut(){Some(agent)=>agent.approve(id,false,Utc::now().timestamp()),None=>Err("agent_not_configured".into())},
                    (Some("agent_cancel"),Some(id))=>match agent_store.as_mut(){Some(agent)=>agent.cancel(id),None=>Err("agent_not_configured".into())},
                    (Some(kind @ ("session_claim"|"session_write"|"session_release")),Some(id))=>match value["revision"].as_i64(){Some(revision)=>store.local_session(id,revision,kind,value["text"].as_str(),Utc::now().timestamp()),None=>Err("invalid_revision".into())},
                    _=>Err("invalid_local_operation".into()),
                };
                if let Err(code)=result{emit(&json!({"type":"error","code":code}));}
                emit(&view(&store,agent_store.as_ref(),Utc::now().timestamp())?);
            },
            result=eventloop.poll()=>match result {
                Ok(Event::Incoming(Packet::ConnAck(_)))=>{
                    device.session=None;device.challenge=id();
                    client.subscribe(format!("limeiot/v1/{}/{}/down/+",device.config.space,device.config.device),QoS::AtLeastOnce).await?;
                    device.publish(&client,"hello",json!({"challenge":device.challenge,"firmware":"limelink-0.1.0","hardware":std::env::consts::OS})).await?;
                },
                Ok(Event::Incoming(Packet::Publish(packet)))=>{
                    if packet.retain||packet.payload.len()>16384 {continue;}
                    let Ok(message)=serde_json::from_slice::<Envelope>(&packet.payload) else {continue;};
                    if message.v!=1||message.device_id!=device.config.device||message.model_revision!=device.config.model_revision{continue;}
                    if message.kind=="welcome"&&message.body["challenge"]==device.challenge&&message.session_id.is_some(){
                        device.session=message.session_id;device.snapshot=0;device.snapshot(&client).await?;
                        emit(&json!({"type":"connection","state":"ready","device":device.config.device}));
                    }else if message.kind=="command"&&device.session.is_some()&&message.session_id==device.session {
                        let now=Utc::now().timestamp();
                        let result=(||->std::result::Result<Value,String>{
                            let expires=message.body["expires_at"].as_str().and_then(|s|chrono::DateTime::parse_from_rfc3339(s).ok()).ok_or("invalid_deadline")?;
                            if expires.timestamp()<=now{return Err("command_expired".into());}
                            let operation=&message.body["operation"];
                            let path=operation["path"].as_str().unwrap_or("");
                            if operation["type"]!="action.invoke"||!["link.exchange","agent.exchange"].contains(&path){return Err("unsupported_operation".into());}
                            let command=message.body["command_id"].as_str().ok_or("invalid_command")?;
                            if command!=message.message_id||command.len()>128{return Err("invalid_command".into());}
                            let exchange:Exchange=serde_json::from_value(operation["value"].clone()).map_err(|_|"invalid_exchange")?;
                            if path=="agent.exchange"{
                                agent_store.as_mut().ok_or("agent_not_configured")?.execute(command,&exchange,&store,&device.config.space,&device.config.device,&device.config.model_revision,now)
                            }else{store.execute(command,&exchange,&device.config.space,&device.config.device,&device.config.model_revision,now)}
                        })();
                        match result {
                            Ok(body)=>{device.publish(&client,"result",body).await?;emit(&view(&store,agent_store.as_ref(),now)?);},
                            Err(code)=>{let command=message.body["command_id"].as_str().unwrap_or("");if !command.is_empty(){device.publish(&client,"result",json!({"command_id":command,"status":"failed","error":"execution_failed","evidence":{"type":"device_result","observed_at":Utc::now(),"reported":{}}})).await?;}emit(&json!({"type":"error","code":code}));}
                        }
                    }
                },
                Err(_)=>{device.session=None;emit(&json!({"type":"connection","state":"offline"}));tokio::time::sleep(Duration::from_millis(500)).await;},
                _=>{},
            },
            _=tokio::signal::ctrl_c()=>break,
        }
    }
    if let Some((id, cancel, mut task)) = active_agent {
        let _ = cancel.send(true);
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        loop {
            tokio::select! {
                update=updates.recv()=>{if let Some((run,update))=update{if let Some(agent)=agent_store.as_mut(){agent.update(&run,update)?;}}},
                _=&mut task=>break,
                _=tokio::time::sleep_until(deadline)=>{task.abort();let _=task.await;break;},
            }
        }
        while let Ok((run, update)) = updates.try_recv() {
            if let Some(agent) = agent_store.as_mut() {
                agent.update(&run, update)?;
            }
        }
        if let Some(agent) = agent_store.as_mut() {
            agent.update(
                &id,
                Update::Finished {
                    state: "unknown".into(),
                    error: Some("agent_shutdown_unconfirmed".into()),
                },
            )?;
        }
        emit(&view(&store, agent_store.as_ref(), Utc::now().timestamp())?);
    }
    let _ = client.disconnect().await;
    drop(lock);
    Ok(())
}
