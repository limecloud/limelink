package run.limeai.link

import android.app.Application
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.speech.RecognizerIntent
import androidx.activity.enableEdgeToEdge
import androidx.activity.SystemBarStyle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.foundation.background
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*
import java.util.UUID
import run.limeai.iot.core.*
import run.limeai.link.core.*

class Workbench(application:Application):AndroidViewModel(application) {
    var connectionRequest by mutableStateOf<GatewayConnectionRequest?>(null);private set
    var connectionSelection by mutableStateOf(0);private set
    fun receiveConnection(url:String){
        connectionRequest=try{GatewayConnectionRequest.fromUrl(url)}catch(_:Exception){message="无法识别网关连接地址。";null}
    }
    fun dismissConnection(){connectionRequest=null}
    fun acceptConnection(){
        if(busy)return
        val request=connectionRequest?:return
        toggleCloudMode(false);editEndpoint(request.origin);connectionRequest=null;connectionSelection++
        message="网关地址已填入，请登录或恢复连接。"
    }
    val discovery=GatewayDiscovery(application)
    var cloudMode by mutableStateOf(false);private set
    var cloudEndpoint by mutableStateOf("");private set
    var authorization by mutableStateOf<NativeLogin?>(null);private set
    var principal by mutableStateOf("");private set
    var gateway by mutableStateOf("");private set
    var cloudRecords by mutableStateOf<List<ControlCommandRecord>>(emptyList());private set
    var recordKey by mutableStateOf("")
    private val connectionPreferences=application.getSharedPreferences("gateway-connection",Application.MODE_PRIVATE)
    var endpoint by mutableStateOf(connectionPreferences.getString("origin","").orEmpty());private set
    var token by mutableStateOf("")
    var space by mutableStateOf("")
    var spaces by mutableStateOf<List<String>>(emptyList())
    var devices by mutableStateOf<List<Device>>(emptyList())
    var target by mutableStateOf("")
    var name by mutableStateOf("我的手机")
    var requiresToken by mutableStateOf(false);private set
    var pairingState by mutableStateOf("");private set
    var pairingTimedOut by mutableStateOf(false);private set
    var diagnostic by mutableStateOf("");private set
    private var pairingDeadline=0L
    val paired get()=pairingState=="approved"
    var text by mutableStateOf("")
    var message by mutableStateOf("连接网关后，明确选择空间和电脑。")
    var fingerprint by mutableStateOf("")
    var busy by mutableStateOf(false)
    var pending by mutableStateOf(false)
    var session by mutableStateOf("")
    var revision by mutableStateOf("1")
    var content by mutableStateOf("")
    var cancel by mutableStateOf("")
    var agentCapabilities by mutableStateOf<AgentCapabilities?>(null);private set
    var agentRecords by mutableStateOf<List<AgentReference>>(emptyList());private set
    var agentRun by mutableStateOf<AgentRun?>(null);private set
    var agentEvents by mutableStateOf<List<AgentEvent>>(emptyList());private set
    var agentWorkspace by mutableStateOf("")
    var agentText by mutableStateOf("")
    var agentWrite by mutableStateOf(false)
    var agentContinue by mutableStateOf(false)
    var agentRunId by mutableStateOf("");private set
    var agentToolEnabled by mutableStateOf(false);private set
    var agentIoTDevices by mutableStateOf<List<Device>>(emptyList());private set
    var agentSelectedDevices by mutableStateOf<Set<String>>(emptySet());private set
    var agentToolRecords by mutableStateOf<List<AgentToolRecord>>(emptyList());private set
    private var gatewayModels=emptyMap<String,Model>()
    private var agentGeneration=0
    private var agent:AgentClient?=null
    private var agentIoT:AgentIoTClient?=null
    private val storage=SecureStore(application)
    private var client:LinkClient?=null
    private var ai:TextGenerationClient?=null
    private var aiKey:String?=null
    private var cloud:CloudLinkClient?=null
    private var cloudSnapshot:CloudLinkSnapshot?=null
    private var job:Job?=null
    private var generation=0
    private var nextPoll=0L
    private fun clearAgent(){agentGeneration++;agentCapabilities=null;agentRecords=emptyList();agentRun=null;agentEvents=emptyList();agentWorkspace="";agentText="";agentWrite=false;agentContinue=false;agentRunId="";agentToolEnabled=false;agentSelectedDevices=emptySet();agentToolRecords=emptyList()}
    private fun clearTargetFields(){fingerprint="";pairingState="";pairingTimedOut=false;pairingDeadline=0;session="";revision="1";content="";cancel="";aiKey=null;clearAgent()}
    private fun clearTargets(){devices=emptyList();agentIoTDevices=emptyList();gatewayModels=emptyMap();target="";clearTargetFields()}
    fun editEndpoint(value:String){if(busy||endpoint==value)return;endpoint=value;if(runCatching{GatewayConnectionRequest.fromOrigin(value)}.isSuccess)connectionPreferences.edit().putString("origin",value).apply();token="";client=null;agent=null;agentIoT=null;ai=null;spaces=emptyList();space="";clearTargets();pending=false;message="网关地址已更改，请重新连接；原任务保留在原网关。"}
    fun selectSpace(value:String){if(busy||space==value)return;run{space=value;if(!cloudMode)connectionPreferences.edit().putString("space:$endpoint",value).apply();clearTargets();cloudSnapshot=null;gateway="";loadDevices(connectSingle=!cloudMode)}}
    fun toggleCloudMode(value:Boolean){if(busy||cloudMode==value)return;cloudMode=value;resetRoute()}
    fun editCloudEndpoint(value:String){if(busy||cloudEndpoint==value)return;cloudEndpoint=value;resetRoute()}
    private fun resetRoute(){pause();client=null;agent=null;agentIoT=null;cloud=null;ai=null;spaces=emptyList();space="";clearTargets();principal="";cloudRecords=emptyList();recordKey="";token="";text="";pending=false;message="入口已更改，请恢复会话或明确发起授权；原操作仍保存在原入口。";resume()}
    fun resume(){if(!cloudMode){
        discovery.start()
        val previous=job;val current=generation
        viewModelScope.launch{
            previous?.join()
            if(current==generation&&client!=null&&space.isNotEmpty()&&!busy)run{
                loadDevices(connectSingle=false)
                if(target.isNotEmpty()){
                    recoverSelectedConnection()
                    if(!pending)performAction("status")
                }
            }
        }
    }}
    fun pause(){discovery.stop();generation++;job?.cancel();clearTargets();cloudSnapshot=null;gateway="";authorization=null}
    override fun onCleared(){discovery.stop();super.onCleared()}
    fun run(work:suspend()->Unit){
        if(busy)return;busy=true;val current=generation
        job=viewModelScope.launch(start=CoroutineStart.UNDISPATCHED){
            try{currentCoroutineContext().ensureActive();work()}
            catch(error:CancellationException){throw error}
            catch(error:Exception){if(current==generation){
                diagnostic=error.javaClass.simpleName+": "+error.message.orEmpty()
                val unauthenticated=error is ControlException&&error.code=="unauthenticated"||error is GatewayException&&error.code=="unauthenticated"
                if(unauthenticated){spaces=emptyList();space="";clearTargets();principal="";gateway="";cloudSnapshot=null;cloudRecords=emptyList();recordKey="";text="";requiresToken=!cloudMode}
                message=when{
                    unauthenticated->"请输入访问密钥。"
                    error is java.io.IOException->"连接中断，请重试。"
                    error.message=="agent_disabled"->"请先在电脑设置中开启助手。"
                    error.message=="resolve_original_request_first"->"正在核实上次操作。"
                    error is GatewayException->error.displayMessage
                    error is ControlException->error.displayMessage
                    else->error.message?.takeIf{it.any{c->c in '\u4e00'..'\u9fff'}}?:"操作未完成，请重试。"
                }
            }}
            finally{
                if(current==generation){
                    try{
                        if(cloudMode){val records=cloud?.records()?:emptyList();currentCoroutineContext().ensureActive();cloudRecords=records;pending=records.any{it.isPrepared||!it.canForget}}
                        else{val saved=client?.pending();currentCoroutineContext().ensureActive();pending=saved!=null}
                    }catch(_:CancellationException){}catch(_:Exception){pending=true}
                }
                busy=false
            }
        }
    }
    private fun cloudClient():CloudLinkClient=cloud?:CloudLinkClient(cloudEndpoint,storage).also{cloud=it}
    private suspend fun loadCloud(c:CloudLinkClient){
        val session=c.control.restoreSession();val available=c.control.spaces();val records=c.records();currentCoroutineContext().ensureActive()
        space="";clearTargets();cloudSnapshot=null;gateway="";text="";authorization=null;recordKey=""
        principal=session.principal.name;spaces=available.map{it.spaceId};cloudRecords=records
        message="已连接云账号。"
    }
    fun restoreCloud()=run{loadCloud(cloudClient())}
    fun beginCloud()=run{
        val login=cloudClient().control.beginAuthorization("android");currentCoroutineContext().ensureActive()
        authorization=login;nextPoll=android.os.SystemClock.elapsedRealtime()+login.intervalSeconds*1000L
        message="在系统浏览器核对授权码、平台和账号后批准；回到应用明确查询。"
    }
    fun pollCloud()=run{
        val login=checkNotNull(authorization){"请先发起 / 恢复原授权"}
        check(android.os.SystemClock.elapsedRealtime()>=nextPoll){"请按授权间隔稍后查询"}
        nextPoll=android.os.SystemClock.elapsedRealtime()+login.intervalSeconds*1000L
        val c=cloudClient();val response=c.control.pollAuthorization();currentCoroutineContext().ensureActive()
        if(response.status==NativeAuthorizationStatus.APPROVED)loadCloud(c)else message="授权状态：${response.status}"
    }
    fun cancelCloud()=run{cloudClient().control.cancelAuthorization();currentCoroutineContext().ensureActive();authorization=null;message="原授权已取消。"}
    fun connect()=run{
        client=null;agent=null;agentIoT=null;ai=null;spaces=emptyList();space="";clearTargets()
        val next=LinkClient(endpoint,storage)
        if(token.isBlank())next.restore()else next.login(token)
        currentCoroutineContext().ensureActive();token="";client=next;val runner=AgentClient(next,storage);agent=runner;agentIoT=AgentIoTClient(next.gateway,runner,storage);ai=TextGenerationClient(next.gateway,storage)
        val available=next.spaces().map{it.spaceId};currentCoroutineContext().ensureActive();spaces=available;devices=emptyList();target="";message="";requiresToken=false
        pending=next.pending()!=null
        val selected=available.singleOrNull()?:connectionPreferences.getString("space:$endpoint",null)?.takeIf{it in available}
        selected?.let{space=it;loadDevices(connectSingle=true)}
    }
    fun refresh()=run{loadDevices(connectSingle=false)}
    private suspend fun loadDevices(connectSingle:Boolean){
        val found:List<Device>
        if(cloudMode){val snapshot=cloudClient().snapshot(space);currentCoroutineContext().ensureActive();cloudSnapshot=snapshot;gateway=listOf(snapshot.gateway.gatewayId,snapshot.gateway.localSpaceId,snapshot.gateway.revision).joinToString("，");found=snapshot.devices.filter{snapshot.models[it.modelRevision]?.modelId=="urn:limelink:model:desktop:1"}}
        else{val snapshot=checkNotNull(client).snapshot(space);currentCoroutineContext().ensureActive();found=snapshot.devices.filter{snapshot.models[it.modelRevision]?.modelId=="urn:limelink:model:desktop:1"};gatewayModels=snapshot.models;agentIoTDevices=snapshot.devices.filter{snapshot.models[it.modelRevision]?.modelId?.let{id->!id.startsWith("urn:limelink:model:desktop:")}==true}}
        val previous=target
        devices=found;message=if(found.isEmpty())"暂未发现电脑，请在电脑上打开柠联。"else ""
        if(found.none{it.deviceId==previous}){target="";clearTargetFields()}
        val preferred=previous.ifEmpty{connectionPreferences.getString("desktop:$endpoint:$space","").orEmpty()}
        (found.singleOrNull{it.deviceId==preferred}?:found.singleOrNull())?.let{device->
            selectTarget(device.deviceId)
            if(connectSingle&&device.ready&&!cloudMode){
                recoverSelectedConnection()
                if(!pending&&!paired)performAction("pair")
            }
        }
    }
    private suspend fun recoverSelectedConnection(){
        val c=checkNotNull(client);val device=devices.single{it.deviceId==target}
        val original=c.pending()
        pending=original!=null
        if(original!=null&&original.space==space&&original.intent.input.deviceId==target&&original.intent.input.modelRevision==device.modelRevision){
            if(original.intent.input.operation.path=="agent.exchange"){
                val runner=checkNotNull(agent);val value=runner.recover();currentCoroutineContext().ensureActive()
                if(value!=null){loadAgentRecords(runner,device,value.id);showAgent(value)}
            }else{val receipt=c.resolve();currentCoroutineContext().ensureActive();finishExchange(c,receipt)}
            pending=c.pending()!=null
        }
    }
    private suspend fun selectTarget(id:String){if(target!=id){clearTargetFields();target=id};val value=if(cloudMode)cloudClient().fingerprint(id)else checkNotNull(client).fingerprint(space,id);currentCoroutineContext().ensureActive();fingerprint=value;if(!cloudMode)connectionPreferences.edit().putString("desktop:$endpoint:$space",id).apply()}
    fun select(id:String)=run{selectTarget(id);if(!cloudMode&&!pending&&devices.single{it.deviceId==id}.ready)performAction("pair")}
    fun checkPairing(){if(pairingState!="pending")return;if(android.os.SystemClock.elapsedRealtime()>=pairingDeadline){pairingTimedOut=true;return};if(!busy&&!cloudMode){if(pending)resolve()else action("status")}}
    private fun show(command:Command){
        val response=LinkClient.response(command);diagnostic=command.statusText+"\n"+command.commandId+"\n"+(response?.toString()?:"")
        val value=response?.takeIf{it["ok"]==JsonPrimitive(true)}?.get("value") as? JsonObject
        val kind=command.request.operation.value.jsonObject["kind"]?.jsonPrimitive?.content
        if(kind in setOf("pair","status","revoke"))value?.get("state")?.jsonPrimitive?.content?.let{pairingState=it}
        message=when{
            response==null->when(command.status){"accepted","dispatched"->"正在发送…";"failed","rejected"->"操作未完成，请检查连接。";"expired"->"操作已超时，请检查结果。";else->"操作结果待确认。"}
            response?.get("ok")==JsonPrimitive(false)->when(response["error"]?.jsonPrimitive?.content){"pairing_required"->"请先连接电脑。";"pairing_not_approved"->"请在电脑上确认连接。";"agent_disabled"->"请先在电脑设置中开启助手。";else->"操作未完成，请检查连接。"}
            response["ok"]!=JsonPrimitive(true)->"操作结果待确认。"
            kind in setOf("pair","status")->when(pairingState){"approved"->"";"pending"->"请在电脑上确认连接。";"revoked"->"连接已取消。";else->"正在连接电脑…"}
            kind=="card"->if(LinkClient.completedCardText(command)!=null)"已发送到电脑。"else "发送结果待确认。"
            kind=="revoke"->"连接已取消。"
            kind=="session_create"||kind=="session_claim"->"已开始共同编辑。"
            kind=="session_write"->"修改已保存。"
            kind=="session_release"->"已结束编辑。"
            kind=="content_put"->"内容已保存到电脑。"
            kind=="content_remove"->"已移除保存内容。"
            kind=="cancel"->when(value?.get("state")?.jsonPrimitive?.content){"cancelled"->"消息已撤回。";"presented"->"消息已显示，无法撤回。";"expired"->"消息已过期。";else->"撤回结果待确认。"}
            else->"操作已完成。"
        }
        value?.get("revision")?.jsonPrimitive?.content?.let{revision=it}
        value?.get("text")?.jsonPrimitive?.content?.let{text=it}
        if(command.request.operation.value.jsonObject["kind"]?.jsonPrimitive?.content=="card")value?.get("id")?.jsonPrimitive?.content?.let{cancel=it}
        if(kind=="cancel"&&value?.get("state")?.jsonPrimitive?.content in setOf("cancelled","presented","expired"))cancel=""
        if(kind=="content_remove"&&value?.get("removed")==JsonPrimitive(true))content=""
    }
    private suspend fun finishExchange(c:LinkClient,command:Command){
        show(command)
        // 只清空已确认发送且仍与原请求一致的草稿，恢复旧请求不会覆盖新输入。
        if(c.finishKnownExchange()){
            currentCoroutineContext().ensureActive()
            LinkClient.completedCardText(command)?.let{if(text==it)text=""}
        }
    }
    fun action(kind:String,reapply:Boolean=false)=run{performAction(kind,reapply)}
    private suspend fun performAction(kind:String,reapply:Boolean=false){
        val device=devices.singleOrNull{it.deviceId==target}?:error("请先选择电脑")
        val payload=buildJsonObject{
            when(kind){
                "pair"->{put("name",name);if(reapply)put("reapply",true)}
                "card"->{put("text",text);put("ttl",3600)}
                "cancel"->put("id",cancel)
                "session_create"->{session=UUID.randomUUID().toString();revision="1";put("id",session);put("text",text);put("ttl",3600)}
                "session_claim","session_release"->{put("id",session);put("revision",revision.toLong())}
                "session_write"->{put("id",session);put("revision",revision.toLong());put("text",text)}
                "content_put"->{if(content.isBlank())content=UUID.randomUUID().toString();put("id",content);put("text",text);put("sha256",hash(text));put("ttl",3600)}
                "content_remove"->put("id",content)
            }
        }
        pending=true
        if(kind=="pair"){pairingDeadline=android.os.SystemClock.elapsedRealtime()+90_000;pairingTimedOut=false}
        if(cloudMode){val record=cloudClient().perform(space,device,kind,payload);currentCoroutineContext().ensureActive();recordKey=record.id;showCloud(record)}
        else{val c=checkNotNull(client);var command=c.perform(space,device,kind,payload)
            repeat(20){if(command.status in setOf("accepted","dispatched")){delay(200);command=c.resolve()}}
            currentCoroutineContext().ensureActive()
            // 只收尾已经核实的终态。断线、404或未知结果继续保留原请求。
            finishExchange(c,command)}
    }
    private fun showCloud(record:ControlCommandRecord){
        val response=CloudLinkClient.response(record)
        diagnostic=listOf(record.id,record.result?.status?.name.orEmpty(),record.rejection.orEmpty(),response?.toString().orEmpty()).joinToString("\n")
        message=if(record.isPrepared)"操作尚未提交。"else if(record.rejection!=null)"操作未完成，请检查连接。"else if(response?.get("ok")==JsonPrimitive(true))"操作已完成。"else "操作结果待确认。"
        val selected=cloudSnapshot?:return;val ref=record.reference
        if(ref.principalId!=selected.principal||ref.spaceId!=space||ref.localSpaceId!=selected.gateway.localSpaceId||ref.request.gatewayId!=selected.gateway.gatewayId||ref.request.bindingRevision!=selected.gateway.revision||ref.request.deviceId!=target||devices.singleOrNull{it.deviceId==target}?.modelRevision!=ref.request.modelRevision)return
        val value=response?.get("value") as? JsonObject?:return
        value["revision"]?.jsonPrimitive?.content?.let{revision=it};value["text"]?.jsonPrimitive?.content?.let{text=it}
        if(ref.request.operation.value.jsonObject["kind"]?.jsonPrimitive?.content=="card")value["id"]?.jsonPrimitive?.content?.let{cancel=it}
    }
    fun resolve(reconcile:Boolean=false)=run{
        if(cloudMode){check(recordKey.isNotEmpty()){"请选择原操作"};val record=cloudClient().resolve(recordKey,reconcile);currentCoroutineContext().ensureActive();showCloud(record)}
        else{val c=checkNotNull(client);val receipt=c.resolve();currentCoroutineContext().ensureActive();finishExchange(c,receipt)}
    }
    fun finish()=run{if(cloudMode){check(recordKey.isNotEmpty()){"请选择原操作"};cloudClient().forget(recordKey);currentCoroutineContext().ensureActive();recordKey=""}else checkNotNull(client).finish();message="已完成所选记录；未知结果会保留，未提交的准备可明确放弃。"}
    fun logout()=run{if(cloudMode)cloudClient().logout()else client?.logout();currentCoroutineContext().ensureActive();client=null;agent=null;cloud=null;ai=null;space="";clearTargets();spaces=emptyList();principal="";gateway="";cloudSnapshot=null;cloudRecords=emptyList();recordKey="";authorization=null;text="";message="已退出，未核实任务保留在安全存储。"}
    fun modelDraft(resolve:Boolean)=run{
        val model=checkNotNull(ai);val capabilities=model.capabilities(space)
        check(capabilities.configured){"网关未配置文字模型"}
        val records=model.records(space)
        val record=if(resolve){model.resolve(space,aiKey?:records.lastOrNull()?.key?:error("没有原模型任务"))}else{
            check(records.none{it.pending}){"请先查询原模型任务"}
            model.submit(space,TextGenerationRequests.input(listOf(TextGenerationMessage("user",text)),instructions="仅整理纯文本草稿，不执行设备动作。"))
        }
        currentCoroutineContext().ensureActive();aiKey=record.key;record.text?.let{text=it};message=record.statusText+"；发送到电脑需要另行确认。"
    }
    private fun agentTarget():Triple<AgentClient,Device,Int>{
        check(!cloudMode){"助手暂时通过网关连接，请切换连接入口"}
        val device=devices.singleOrNull{it.deviceId==target}?:error("请选择执行电脑")
        return Triple(checkNotNull(agent){"请先连接网关"},device,agentGeneration)
    }
    fun selectAgentRun(id:String){if(busy)return;agentRunId=id;agentRun=null;agentEvents=emptyList();agentContinue=false;agentToolRecords=emptyList()}
    fun selectAgentDevice(id:String,selected:Boolean){if(busy)return;if(selected){if(agentIoTDevices.none{it.deviceId==id}||agentSelectedDevices.size>=4)return;agentSelectedDevices=agentSelectedDevices+id}else agentSelectedDevices=agentSelectedDevices-id}
    val agentDeviceScope get()=if(agentContinue)agentRecords.singleOrNull{it.id==agentRunId}?.iotDevices?:emptyList()else agentSelectedDevices.sorted()
    fun selectAgentWorkspace(id:String){if(busy)return;agentWorkspace=id;agentWrite=false}
    private suspend fun loadAgentRecords(c:AgentClient,device:Device,selected:String?=null){
        val records=c.references();currentCoroutineContext().ensureActive()
        agentRecords=records.filter{it.space==space && it.device==device.deviceId && it.revision==device.modelRevision}
        if(selected!=null){agentRunId=selected;agentRun=null;agentEvents=emptyList();agentContinue=false;agentToolRecords=emptyList()}
    }
    private fun showAgent(value:AgentRun){
        if(agentRun?.id!=value.id)agentEvents=emptyList()
        agentRunId=value.id;agentRun=value
        agentEvents=if(value.expiresAt<=java.time.Instant.now().epochSecond)emptyList()else (agentEvents+value.events).associateBy{it.seq}.values.sortedBy{it.seq}
        message=value.stateText+(value.error?.let{"\n$it"}?:"")
    }
    fun discoverAgent()=run{
        val(c,d,g)=agentTarget();val capabilities=c.discover(space,d);val tools=c.discoverTools(space,d);currentCoroutineContext().ensureActive()
        if(g==agentGeneration){agentCapabilities=capabilities;agentWorkspace=capabilities.workspaces.singleOrNull()?.id.orEmpty();agentToolEnabled=tools.enabled;loadAgentRecords(c,d);message=""}
    }
    fun submitAgent()=run{
        val(c,d,g)=agentTarget();val workspace=agentCapabilities?.workspaces?.singleOrNull{it.id==agentWorkspace}?:error("请选择工作目录")
        val resume=if(agentContinue){check(agentRun?.state=="succeeded"&&agentRun?.sessionId!=null){"请先查询已完成的任务"};agentRecords.singleOrNull{it.id==agentRunId}?:error("请选择要继续的任务")}else null
        val selected=resume?.iotDevices?:agentSelectedDevices.sorted()
        check(selected.isEmpty() || agentToolEnabled&&selected.all{id->agentIoTDevices.any{it.deviceId==id}}){"请选择当前网关中的设备"}
        try{
            val value=c.submit(space,d,workspace.id,agentText,if(agentWrite&&workspace.allowWrite)"workspace-write" else "read-only",resume,selected)
            currentCoroutineContext().ensureActive();if(g==agentGeneration){loadAgentRecords(c,d,value.id);showAgent(value)}
        }catch(error:CancellationException){throw error}catch(error:Exception){if(g==agentGeneration)loadAgentRecords(c,d);throw error}
    }
    fun queryAgent(cancel:Boolean=false)=run{
        val(c,d,g)=agentTarget();val ref=agentRecords.singleOrNull{it.id==agentRunId}?:error("请选择任务")
        val after=if(cancel)0 else agentRun?.takeIf{it.id==ref.id}?.cursor?:0
        val value=c.query(ref,space,d,after,cancel);currentCoroutineContext().ensureActive();if(g!=agentGeneration)return@run;showAgent(value)
        agentIoT?.let{tools->
            if(!cancel && value.state=="running" && ref.iotDevices.isNotEmpty())try{tools.receive(ref,space,d)}catch(error:CancellationException){throw error}catch(error:Exception){loadAgentTools(tools,ref,g);throw error}
            loadAgentTools(tools,ref,g)
        }
    }
    fun recoverAgent()=run{
        val(c,d,g)=agentTarget();val value=c.recover();currentCoroutineContext().ensureActive()
        if(g==agentGeneration){val ref=c.references().singleOrNull{it.id==value?.id};currentCoroutineContext().ensureActive()
            if(ref!=null&&ref.space==space&&ref.device==d.deviceId&&ref.revision==d.modelRevision){loadAgentRecords(c,d,value!!.id);showAgent(value)}
            else message="原请求已核实。请选择对应空间和电脑查看任务。"
        }
    }
    private suspend fun loadAgentTools(tools:AgentIoTClient,reference:AgentReference,version:Int){
        tools.pruneExpired();val records=tools.records();currentCoroutineContext().ensureActive()
        if(version==agentGeneration&&agentRunId==reference.id)agentToolRecords=records.filter{it.reference==reference}
    }
    fun agentDeviceName(id:String):String {
        val device=agentIoTDevices.singleOrNull{it.deviceId==id}?:return "授权设备"
        val services=gatewayModels[device.modelRevision]?.services.orEmpty()
        val name=when{services.any{it.id=="light"}->"环境灯";services.any{it.id=="button"}->"无线按钮";else->"设备"}
        val index=agentIoTDevices.indexOf(device)+1
        return if(agentIoTDevices.size==1)name else "$name $index"
    }
    fun agentPropertyName(record:AgentToolRecord):String {
        val parts=record.call.path.split('.');return gatewayModels[record.call.revision]?.services?.singleOrNull{it.id==parts.firstOrNull()}?.properties?.singleOrNull{it.id==parts.lastOrNull()}?.displayName?:record.call.path
    }
    enum class ToolAction { CONFIRM,REJECT,RECOVER,REPORT }
    fun performAgentTool(id:String,action:ToolAction)=run{
        val(_,device,version)=agentTarget();val tools=checkNotNull(agentIoT);val ref=agentRecords.singleOrNull{it.id==agentRunId}?:error("请选择原任务")
        val record=try{when(action){
            ToolAction.CONFIRM->tools.confirm(id,ref,space,device)
            ToolAction.REJECT->tools.reject(id,ref,space,device)
            ToolAction.RECOVER->tools.recoverCommand(id,ref,space,device)
            ToolAction.REPORT->tools.sendResult(id,ref,space,device)
        }}catch(error:CancellationException){throw error}catch(error:Exception){loadAgentTools(tools,ref,version);throw error}
        currentCoroutineContext().ensureActive();if(version!=agentGeneration)return@run
        loadAgentTools(tools,ref,version);message=if(record.needsRecovery)"设备结果待核实，请查询原命令。"else if(record.delivered)"设备操作结果已回传。"else "原设备命令已核实，请回传结果。"
    }
    fun pollAgent(){if(!busy&&!pending&&!cloudMode&&agentRun?.state in setOf("awaiting_approval","approved","starting","running","cancelling"))queryAgent()}
}
class MainActivity:ComponentActivity(){
    override fun onCreate(savedInstanceState:Bundle?){super.onCreate(savedInstanceState);enableEdgeToEdge(statusBarStyle=SystemBarStyle.light(android.graphics.Color.TRANSPARENT,android.graphics.Color.TRANSPARENT),navigationBarStyle=SystemBarStyle.light(android.graphics.Color.TRANSPARENT,android.graphics.Color.TRANSPARENT));receiveConnection(intent);setContent{LinkTheme{WorkbenchScreen()}}}
    override fun onNewIntent(intent:Intent){super.onNewIntent(intent);setIntent(intent);receiveConnection(intent)}
    private fun receiveConnection(intent:Intent?){if(intent?.action==Intent.ACTION_VIEW)intent.dataString?.let{androidx.lifecycle.ViewModelProvider(this)[Workbench::class.java].receiveConnection(it)}}
    override fun onStart(){super.onStart();androidx.lifecycle.ViewModelProvider(this)[Workbench::class.java].resume()}
    override fun onStop(){androidx.lifecycle.ViewModelProvider(this)[Workbench::class.java].pause();super.onStop()}
}
