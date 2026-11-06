//! 官方 App Server stdio 接口。关闭管道不当作成功中断。
use super::{
    tools::{self, ToolCall, ToolReply},
    Config, Job, Update,
};
use serde_json::{json, Value};
use std::{process::Stdio, time::Duration};
use tokio::{
    io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader},
    process::Command,
    sync::{mpsc, watch},
    time::Instant,
};

async fn send(writer: &mut (impl AsyncWrite + Unpin), value: Value) -> Result<(), String> {
    let mut bytes = serde_json::to_vec(&value).map_err(|_| "agent_protocol_invalid")?;
    bytes.push(b'\n');
    writer
        .write_all(&bytes)
        .await
        .map_err(|_| "agent_transport_lost".into())
}
async fn line(
    reader: &mut (impl AsyncBufRead + Unpin),
    result: &mut Vec<u8>,
) -> Result<Value, String> {
    loop {
        let bytes = reader
            .fill_buf()
            .await
            .map_err(|_| "agent_transport_lost")?;
        if bytes.is_empty() {
            return Err("agent_transport_lost".into());
        }
        let count = bytes
            .iter()
            .position(|v| *v == b'\n')
            .map(|i| i + 1)
            .unwrap_or(bytes.len());
        if result.len() + count > 131072 {
            return Err("agent_protocol_budget".into());
        }
        let done = bytes[count - 1] == b'\n';
        result.extend_from_slice(&bytes[..count]);
        reader.consume(count);
        if done {
            let value = serde_json::from_slice(result).map_err(|_| "agent_protocol_invalid".into());
            result.clear();
            return value;
        }
    }
}
fn identifier(value: &Value) -> Result<String, String> {
    value
        .as_str()
        .filter(|s| {
            !s.is_empty()
                && s.len() <= 128
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"-_".contains(&b))
        })
        .map(str::to_owned)
        .ok_or("agent_protocol_invalid".into())
}
fn policy(job: &Job) -> Value {
    if job.sandbox == "workspace-write" {
        json!({"type":"workspaceWrite","writableRoots":[job.workspace.path],"networkAccess":false,"excludeTmpdirEnvVar":true,"excludeSlashTmp":true})
    } else {
        json!({"type":"readOnly","networkAccess":false})
    }
}
async fn update(
    sender: &mpsc::Sender<(String, Update)>,
    job: &Job,
    value: Update,
) -> Result<(), String> {
    sender
        .send((job.id.clone(), value))
        .await
        .map_err(|_| "agent_host_stopped".into())
}
fn chunks(text: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut chunk = String::new();
    for ch in text.chars() {
        if chunk.len() + ch.len_utf8() > 400 {
            result.push(std::mem::take(&mut chunk));
        }
        chunk.push(ch);
    }
    if !chunk.is_empty() {
        result.push(chunk);
    }
    result
}
pub async fn run(
    config: Config,
    job: Job,
    mut cancel: watch::Receiver<bool>,
    sender: mpsc::Sender<(String, Update)>,
) {
    let mut command = Command::new(&config.executable);
    command
        .args([
            "--disable",
            "hooks",
            "--disable",
            "apps",
            "--disable",
            "multi_agent",
            "-c",
            "notify=[]",
            "app-server",
            "--listen",
            "stdio://",
        ])
        .current_dir(&job.workspace.path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(_) => {
            let _ = update(
                &sender,
                &job,
                Update::Finished {
                    state: "failed".into(),
                    error: Some("agent_spawn_failed".into()),
                },
            )
            .await;
            return;
        }
    };
    let mut writer = child.stdin.take().expect("piped stdin");
    let mut reader = BufReader::new(child.stdout.take().expect("piped stdout"));
    let mut input_sent = false;
    let outcome: Result<(String,Option<String>),String> = async {
        tools::validate_grant(&job.iot_devices)?;
        let iot_enabled=!job.iot_devices.is_empty();
        if iot_enabled && !config.allow_iot_tools {return Err("agent_iot_tools_not_allowed".into());}
        send(&mut writer,json!({"id":0,"method":"initialize","params":{"clientInfo":{"name":"limelink","title":"LimeLink","version":"0.1.0"},"capabilities":{"experimentalApi":iot_enabled}}})).await?;
        let deadline = Instant::now()+Duration::from_secs(config.timeout_seconds);
        let mut phase=0; let mut thread=String::new(); let mut turn=String::new();
        let mut cancelling=false;
        let mut interrupt_deadline=deadline; let mut messages=0; let mut output_bytes=0;
        let mut seen_messages=std::collections::HashSet::new();
        let (tool_sender,mut tool_replies)=mpsc::channel::<ToolReply>(16);
        let mut pending_tools=std::collections::HashMap::<String,(Value,ToolCall)>::new();
        let mut seen_tools=std::collections::HashSet::new();
        let mut seen_request_ids=std::collections::HashSet::new();
        let mut unknown_tool_result=false;
        // select! 中断读取时保留半行，下一次轮询不能丢失协议字节。
        let mut partial_line = Vec::new();
        loop {
            let cancellation = *cancel.borrow();
            if cancellation && !input_sent {return Ok(("cancelled".into(),None));}
            if cancellation && !cancelling && !turn.is_empty() {
                send(&mut writer,json!({"id":3,"method":"turn/interrupt","params":{"threadId":thread,"turnId":turn}})).await?;
                cancelling=true; interrupt_deadline=Instant::now()+Duration::from_secs(15);
            }
            let limit=deadline.min(interrupt_deadline);
            let value=tokio::select! {
                value=line(&mut reader, &mut partial_line)=>value?,
                _=tokio::time::sleep_until(limit)=>return Err(if cancelling {"agent_interrupt_unknown"}else{"agent_deadline_unknown"}.into()),
                changed=cancel.changed()=>{if changed.is_err(){return Err("agent_host_stopped".into());}continue;},
                reply=tool_replies.recv(),if !pending_tools.is_empty()=>{
                    let reply=reply.ok_or("agent_tool_result_unknown")?;
                    let (request_id,call)=pending_tools.remove(&reply.call).ok_or("agent_tool_reply_mismatch")?;
                    tools::validate_output(&call.tool,&call.arguments,reply.success,&reply.output)?;
                    unknown_tool_result|=tools::uncertain(&reply.output);
                    send(&mut writer,json!({"id":request_id,"result":{"contentItems":[{"type":"inputText","text":reply.output.to_string()}],"success":reply.success}})).await?;
                    update(&sender,&job,Update::Event{kind:"tool_completed".into(),text:if call.tool=="limeiot_read" {"已返回设备状态"}else{"已返回设备操作结果"}.into()}).await?;
                    continue;
                },
            };
            messages+=1; if messages>4096 {return Err("agent_protocol_budget".into());}
            if value.get("id").is_some() && value.get("method").is_some() {
                let params=&value["params"];
                // 仅当前任务的两个动态工具可进入原客户端；其他工具和提权请求仍拒绝。
                if value["method"]!="item/tool/call" || !iot_enabled || cancelling || turn.is_empty() || params["threadId"]!=thread || params["turnId"]!=turn || !(params["namespace"].is_null() || params["namespace"]=="") {
                    send(&mut writer,json!({"id":value["id"],"error":{"code":-32601,"message":"Unsupported client request"}})).await?;continue;
                }
                let request_id=&value["id"];
                if !(request_id.is_i64() || request_id.as_str().is_some_and(|s|!s.is_empty() && s.len()<=128)) {return Err("agent_tool_request_invalid".into());}
                if !seen_request_ids.insert(request_id.to_string()) {return Err("agent_tool_request_replayed".into());}
                if seen_request_ids.len()>16 {return Err("agent_tool_budget".into());}
                let call=ToolCall{call:params["callId"].as_str().unwrap_or("").into(),tool:params["tool"].as_str().unwrap_or("").into(),arguments:params["arguments"].clone()};
                let fields_valid=params.as_object().is_some_and(|fields| fields.keys().all(|key|["threadId","turnId","callId","tool","arguments","namespace"].contains(&key.as_str())));
                let validation=if !fields_valid {Err("invalid_agent_tool_call".into())}else{tools::validate_call(&call,&job.iot_devices)};
                if let Err(error)=validation {
                    send(&mut writer,json!({"id":request_id,"result":{"contentItems":[{"type":"inputText","text":json!({"error":error}).to_string()}],"success":false}})).await?;continue;
                }
                if !seen_tools.insert(call.call.clone()) {return Err("agent_tool_call_replayed".into());}
                if seen_tools.len()>16 {return Err("agent_tool_budget".into());}
                pending_tools.insert(call.call.clone(),(request_id.clone(),call.clone()));
                update(&sender,&job,Update::Event{kind:"tool_started".into(),text:if call.tool=="limeiot_read" {"读取设备状态"}else{"等待确认设备操作"}.into()}).await?;
                update(&sender,&job,Update::Tool{call,reply:tool_sender.clone()}).await?;
                continue;
            }
            if value.get("error").is_some() && value.get("id").is_some() {
                let message=value["error"]["message"].as_str().unwrap_or("").to_ascii_lowercase();
                return Err(if message.contains("auth") || message.contains("login") || message.contains("401") {"agent_login_required"}else{"agent_rpc_rejected"}.into());
            }
            if value["id"]==0 && phase==0 {
                if !value["result"].is_object(){return Err("agent_protocol_invalid".into());}
                send(&mut writer,json!({"method":"initialized","params":{}})).await?;
                send(&mut writer,json!({"id":4,"method":"config/read","params":{"cwd":job.workspace.path,"includeLayers":false}})).await?;
                phase=4;continue;
            }
            if value["id"]==4 && phase==4 {
                let settings=value["result"]["config"].as_object().ok_or("agent_protocol_invalid")?;
                // 外部工具不受主机文件沙箱约束，首版不接管其权限。
                // 只读配置中的工具开关，不记录提供方、环境变量或凭据。
                let disabled=|key:&str|->Value{Value::Object(settings.get(key).and_then(Value::as_object).into_iter().flat_map(|table|table.keys()).map(|name|(name.clone(),json!({"enabled":false}))).collect())};
                let mut overrides=json!({"web_search":"disabled","mcp_servers":disabled("mcp_servers"),"apps":disabled("apps"),"plugins":disabled("plugins"),"features":{"hooks":false,"apps":false,"multi_agent":false}});
                overrides["apps"]["_default"]=json!({"enabled":false});
                let mut params=json!({"cwd":job.workspace.path,"sandbox":job.sandbox,"approvalPolicy":"never","config":overrides});
                // 恢复会话时 App Server 从原 thread 元数据恢复工具；产品存储已核对授权范围相同。
                if iot_enabled && job.thread.is_none() {params["dynamicTools"]=tools::specifications(&job.iot_devices);}
                let method=if let Some(previous)=&job.thread {params["threadId"]=json!(previous);params["excludeTurns"]=json!(true);"thread/resume"}else{"thread/start"};
                send(&mut writer,json!({"id":1,"method":method,"params":params})).await?; phase=1; continue;
            }
            if value["id"]==1 && phase==1 {
                let result=&value["result"];
                let expected=if job.sandbox=="workspace-write" {"workspaceWrite"}else{"readOnly"};
                if result["approvalPolicy"]!="never" || result["sandbox"]["type"]!=expected || result["cwd"].as_str()!=job.workspace.path.to_str() {return Err("agent_policy_mismatch".into());}
                thread=identifier(&result["thread"]["id"])?;
                if job.thread.as_ref().is_some_and(|previous|*previous!=thread){return Err("agent_session_mismatch".into());}
                // 写入请求前进入不确定区；部分写入或丢响应不能再次提交。
                input_sent=true;
                send(&mut writer,json!({"id":2,"method":"turn/start","params":{"threadId":thread,"cwd":job.workspace.path,"approvalPolicy":"never","sandboxPolicy":policy(&job),"input":[{"type":"text","text":job.text}]}})).await?;
                phase=2; continue;
            }
            if value["id"]==2 && phase==2 {
                let next=identifier(&value["result"]["turn"]["id"])?;
                if !turn.is_empty() && turn!=next {return Err("agent_turn_mismatch".into());}
                if turn.is_empty() {turn=next;update(&sender,&job,Update::Session{thread:thread.clone(),turn:turn.clone()}).await?;}
                phase=3; continue;
            }
            let method=value["method"].as_str().unwrap_or(""); let params=&value["params"];
            if thread.is_empty() || params["threadId"]!=thread {continue;}
            if method=="turn/started" {
                let next=identifier(&params["turn"]["id"])?;
                if !turn.is_empty() && turn!=next {return Err("agent_turn_mismatch".into());}
                if turn.is_empty() {turn=next;update(&sender,&job,Update::Session{thread:thread.clone(),turn:turn.clone()}).await?;}
                continue;
            }
            if method=="turn/completed" {
                if turn.is_empty() || params["turn"]["id"]!=turn {return Err("agent_turn_mismatch".into());}
                if !pending_tools.is_empty() || unknown_tool_result {return Err("agent_tool_result_unknown".into());}
                let state=match params["turn"]["status"].as_str() {Some("completed")=>"succeeded",Some("interrupted")=>"cancelled",Some("failed")=>"failed",_=>return Err("agent_protocol_invalid".into())};
                return Ok((state.into(),if state=="failed" {Some("agent_turn_failed".into())}else{None}));
            }
            if params["turnId"]!=turn || turn.is_empty(){continue;}
            if method=="item/completed" && params["item"]["type"]=="agentMessage" {
                let item=identifier(&params["item"]["id"])?;
                if !seen_messages.insert(item){return Err("agent_duplicate_message".into());}
                let text=params["item"]["text"].as_str().ok_or("agent_protocol_invalid")?;
                output_bytes+=text.len(); if output_bytes>32768 {return Err("agent_output_budget".into());}
                for text in chunks(text){update(&sender,&job,Update::Event{kind:"message".into(),text}).await?;}
            } else if method=="item/started" || method=="item/completed" {
                let kind=params["item"]["type"].as_str().unwrap_or("");
                let label=match kind {"commandExecution"=>Some("运行命令"),"fileChange"=>Some("修改文件"),"mcpToolCall"=>Some("调用工具"),"webSearch"=>Some("搜索资料"),_=>None};
                if let Some(label)=label {update(&sender,&job,Update::Event{kind:if method=="item/started"{"tool_started"}else{"tool_completed"}.into(),text:label.into()}).await?;}
            }
        }
    }.await;
    let (state, error) = match outcome {
        Ok(value) => value,
        Err(error) => (
            if input_sent { "unknown" } else { "failed" }.into(),
            Some(error),
        ),
    };
    // 只有 turn/completed(interrupted) 才报告 cancelled；关闭进程不产生该证明。
    let _ = writer.shutdown().await;
    if tokio::time::timeout(Duration::from_secs(3), child.wait())
        .await
        .is_err()
    {
        let _ = child.kill().await;
        let _ = child.wait().await;
    }
    let _ = update(&sender, &job, Update::Finished { state, error }).await;
}
