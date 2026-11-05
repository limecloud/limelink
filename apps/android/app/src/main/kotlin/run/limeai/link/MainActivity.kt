package run.limeai.link

import android.app.Application
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.speech.RecognizerIntent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*
import java.util.UUID
import run.limeai.iot.core.*
import run.limeai.link.core.*

class Workbench(application:Application):AndroidViewModel(application) {
    var cloudMode by mutableStateOf(false);private set
    var cloudEndpoint by mutableStateOf("");private set
    var authorization by mutableStateOf<NativeLogin?>(null);private set
    var principal by mutableStateOf("");private set
    var gateway by mutableStateOf("");private set
    var cloudRecords by mutableStateOf<List<ControlCommandRecord>>(emptyList());private set
    var recordKey by mutableStateOf("")
    var endpoint by mutableStateOf("")
    var token by mutableStateOf("")
    var space by mutableStateOf("")
    var spaces by mutableStateOf<List<String>>(emptyList())
    var devices by mutableStateOf<List<Device>>(emptyList())
    var target by mutableStateOf("")
    var name by mutableStateOf(android.os.Build.MODEL)
    var text by mutableStateOf("")
    var message by mutableStateOf("连接网关后，明确选择空间和电脑。")
    var fingerprint by mutableStateOf("")
    var busy by mutableStateOf(false)
    var pending by mutableStateOf(false)
    var session by mutableStateOf("")
    var revision by mutableStateOf("1")
    var content by mutableStateOf("")
    var cancel by mutableStateOf("")
    private val storage=SecureStore(application)
    private var client:LinkClient?=null
    private var ai:TextGenerationClient?=null
    private var aiKey:String?=null
    private var cloud:CloudLinkClient?=null
    private var cloudSnapshot:CloudLinkSnapshot?=null
    private var job:Job?=null
    private var generation=0
    private var nextPoll=0L
    private fun clearTargetFields(){fingerprint="";session="";revision="1";content="";cancel="";aiKey=null}
    private fun clearTargets(){devices=emptyList();target="";clearTargetFields()}
    fun editEndpoint(value:String){if(busy||endpoint==value)return;endpoint=value;token="";client=null;ai=null;spaces=emptyList();space="";clearTargets();pending=false;message="网关地址已更改，请重新连接；原任务保留在原网关。"}
    fun selectSpace(value:String){if(busy||space==value)return;space=value;clearTargets();cloudSnapshot=null;gateway=""}
    fun toggleCloudMode(value:Boolean){if(busy||cloudMode==value)return;cloudMode=value;resetRoute()}
    fun editCloudEndpoint(value:String){if(busy||cloudEndpoint==value)return;cloudEndpoint=value;resetRoute()}
    private fun resetRoute(){pause();client=null;cloud=null;ai=null;spaces=emptyList();space="";clearTargets();principal="";cloudRecords=emptyList();recordKey="";token="";text="";pending=false;message="入口已更改，请恢复会话或明确发起授权；原操作仍保存在原入口。"}
    fun pause(){generation++;job?.cancel();clearTargets();cloudSnapshot=null;gateway="";authorization=null}
    fun run(work:suspend()->Unit){
        if(busy)return;busy=true;val current=generation
        job=viewModelScope.launch{
            try{currentCoroutineContext().ensureActive();work()}
            catch(error:CancellationException){throw error}
            catch(error:Exception){if(current==generation){if(error is ControlException&&error.code=="unauthenticated"){spaces=emptyList();space="";clearTargets();principal="";gateway="";cloudSnapshot=null;cloudRecords=emptyList();recordKey="";text=""};message=(error as? GatewayException)?.displayMessage?:(error as? ControlException)?.displayMessage?:error.message?:"操作未完成"}}
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
        principal=session.principal.name+" · "+session.principal.principalId;spaces=available.map{it.spaceId};cloudRecords=records
        message="云会话已恢复，请明确选择空间并刷新；原操作可独立查询。"
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
        client=null;ai=null;spaces=emptyList();space="";clearTargets()
        val next=LinkClient(endpoint,storage)
        if(token.isBlank())next.restore()else next.login(token)
        currentCoroutineContext().ensureActive();token="";client=next;ai=TextGenerationClient(next.gateway,storage)
        val available=next.spaces().map{it.spaceId};currentCoroutineContext().ensureActive();spaces=available;devices=emptyList();target="";message="已连接，请选择空间并刷新。"
    }
    fun refresh()=run{
        val found:List<Device>
        if(cloudMode){val snapshot=cloudClient().snapshot(space);currentCoroutineContext().ensureActive();cloudSnapshot=snapshot;gateway=listOf(snapshot.gateway.gatewayId,snapshot.gateway.localSpaceId,snapshot.gateway.revision).joinToString(" · ");found=snapshot.devices.filter{snapshot.models[it.modelRevision]?.modelId=="urn:limelink:model:desktop:1"}}
        else{val snapshot=checkNotNull(client).snapshot(space);currentCoroutineContext().ensureActive();found=snapshot.devices.filter{snapshot.models[it.modelRevision]?.modelId=="urn:limelink:model:desktop:1"}}
        target="";clearTargetFields();devices=found;message="发现 ${devices.size} 个终端，请核对目标与指纹。"
    }
    fun select(id:String)=run{target=id;clearTargetFields();val value=if(cloudMode)cloudClient().fingerprint(id)else checkNotNull(client).fingerprint(space,id);currentCoroutineContext().ensureActive();fingerprint=value}
    private fun show(command:Command){
        val response=LinkClient.response(command);message=command.statusText+"\n"+command.commandId+"\n"+(response?.toString()?:"")
        val value=response?.get("value") as? JsonObject
        value?.get("revision")?.jsonPrimitive?.content?.let{revision=it}
        value?.get("text")?.jsonPrimitive?.content?.let{text=it}
        if(command.request.operation.value.jsonObject["kind"]?.jsonPrimitive?.content=="card")value?.get("id")?.jsonPrimitive?.content?.let{cancel=it}
    }
    fun action(kind:String,reapply:Boolean=false)=run{
        val device=devices.singleOrNull{it.deviceId==target}?:error("请先选择电脑")
        val payload=buildJsonObject{
            when(kind){
                "pair"->{put("name",name);if(reapply)put("reapply",true)}
                "card"->{put("text",text);put("ttl",3600)}
                "cancel"->put("id",cancel)
                "session_create"->{if(session.isBlank())session=UUID.randomUUID().toString();put("id",session);put("text",text);put("ttl",3600)}
                "session_claim","session_release"->{put("id",session);put("revision",revision.toLong())}
                "session_write"->{put("id",session);put("revision",revision.toLong());put("text",text)}
                "content_put"->{if(content.isBlank())content=UUID.randomUUID().toString();put("id",content);put("text",text);put("sha256",hash(text));put("ttl",3600)}
                "content_remove"->put("id",content)
            }
        }
        pending=true
        if(cloudMode){val record=cloudClient().perform(space,device,kind,payload);currentCoroutineContext().ensureActive();recordKey=record.id;showCloud(record)}
        else{val c=checkNotNull(client);var command=c.perform(space,device,kind,payload)
            repeat(20){if(command.status in setOf("accepted","dispatched")){delay(200);command=c.resolve()}}
            currentCoroutineContext().ensureActive();show(command)}
    }
    private fun showCloud(record:ControlCommandRecord){
        val response=CloudLinkClient.response(record)
        message=listOf("云原操作："+(if(record.isPrepared)"尚未提交" else record.rejection?:record.result?.status?.name?:"未知"),record.id,response?.toString()?:"").joinToString("\n")
        val selected=cloudSnapshot?:return;val ref=record.reference
        if(ref.principalId!=selected.principal||ref.spaceId!=space||ref.localSpaceId!=selected.gateway.localSpaceId||ref.request.gatewayId!=selected.gateway.gatewayId||ref.request.bindingRevision!=selected.gateway.revision||ref.request.deviceId!=target||devices.singleOrNull{it.deviceId==target}?.modelRevision!=ref.request.modelRevision)return
        val value=response?.get("value") as? JsonObject?:return
        value["revision"]?.jsonPrimitive?.content?.let{revision=it};value["text"]?.jsonPrimitive?.content?.let{text=it}
        if(ref.request.operation.value.jsonObject["kind"]?.jsonPrimitive?.content=="card")value["id"]?.jsonPrimitive?.content?.let{cancel=it}
    }
    fun resolve(reconcile:Boolean=false)=run{
        if(cloudMode){check(recordKey.isNotEmpty()){"请选择原操作"};val record=cloudClient().resolve(recordKey,reconcile);currentCoroutineContext().ensureActive();showCloud(record)}
        else{val receipt=checkNotNull(client).resolve();currentCoroutineContext().ensureActive();show(receipt)}
    }
    fun finish()=run{if(cloudMode){check(recordKey.isNotEmpty()){"请选择原操作"};cloudClient().forget(recordKey);currentCoroutineContext().ensureActive();recordKey=""}else checkNotNull(client).finish();message="已完成所选记录；未知结果会保留，未提交的准备可明确放弃。"}
    fun logout()=run{if(cloudMode)cloudClient().logout()else client?.logout();currentCoroutineContext().ensureActive();client=null;cloud=null;ai=null;space="";clearTargets();spaces=emptyList();principal="";gateway="";cloudSnapshot=null;cloudRecords=emptyList();recordKey="";authorization=null;text="";message="已退出，未核实任务保留在安全存储。"}
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
}
class MainActivity:ComponentActivity(){
    override fun onCreate(savedInstanceState:Bundle?){super.onCreate(savedInstanceState);setContent{MaterialTheme(colorScheme=lightColorScheme(primary=androidx.compose.ui.graphics.Color(0xFF41672B))){WorkbenchScreen()}}}
    override fun onStop(){androidx.lifecycle.ViewModelProvider(this)[Workbench::class.java].pause();super.onStop()}
}
@Composable private fun WorkbenchScreen(model:Workbench=viewModel()){
    var confirmingReapply by remember{mutableStateOf(false)}
    if(confirmingReapply)AlertDialog(onDismissRequest={confirmingReapply=false},title={Text("重新申请所选电脑的协同？")},text={Text("仅对过期、拒绝或撤销的关系生效；清除旧会话与内容后，电脑必须再次批准。先核实所有未完成请求。")},confirmButton={TextButton({confirmingReapply=false;model.action("pair",reapply=true)}){Text("清除并重新申请")}},dismissButton={TextButton({confirmingReapply=false}){Text("取消")}})
    val voice=rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()){result->if(result.resultCode==Activity.RESULT_OK){result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()?.let{model.text=it}}}
    val context=androidx.compose.ui.platform.LocalContext.current
    fun launchVoice(){try{voice.launch(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,RecognizerIntent.LANGUAGE_MODEL_FREE_FORM).putExtra(RecognizerIntent.EXTRA_LANGUAGE,"zh-CN").putExtra(RecognizerIntent.EXTRA_MAX_RESULTS,1))}catch(_:Exception){model.message="未安装系统语音识别服务，可以直接输入草稿。"}}
    Surface(Modifier.fillMaxSize()){
        LazyColumn(Modifier.fillMaxSize().padding(horizontal=20.dp),verticalArrangement=Arrangement.spacedBy(12.dp),contentPadding=PaddingValues(vertical=24.dp)){
            item{Text("LimeLink 柠联",style=MaterialTheme.typography.headlineMedium);Text("手机的灵感，电脑接着做。")}
            item{Text("选择 LimeIoT 连接入口",style=MaterialTheme.typography.titleLarge);Row{Switch(model.cloudMode,model::toggleCloudMode,enabled=!model.busy);Text("云控制面")}}
            if(model.cloudMode){
                item{OutlinedTextField(model.cloudEndpoint,model::editCloudEndpoint,label={Text("控制面 HTTPS 地址")},modifier=Modifier.fillMaxWidth(),enabled=!model.busy)}
                item{Row{Button(model::restoreCloud,enabled=!model.busy){Text("恢复云会话")};TextButton(model::beginCloud,enabled=!model.busy){Text("发起 / 恢复授权")}}}
                item{model.authorization?.let{login->
                    Text("授权码：${login.userCode}",style=MaterialTheme.typography.titleLarge);Text("到期：${login.expiresAt}")
                    TextButton({try{context.startActivity(Intent(Intent.ACTION_VIEW,Uri.parse(login.verificationUri)))}catch(_:Exception){model.message="未能打开系统浏览器。"}},enabled=!model.busy){Text("打开系统浏览器核对并批准")}
                    Row{Button(model::pollCloud,enabled=!model.busy){Text("查询授权结果")};TextButton(model::cancelCloud,enabled=!model.busy){Text("取消原授权")}}
                };Text("当前账号：${model.principal}");Text("有效网关：${model.gateway}");TextButton(model::logout,enabled=!model.busy){Text("退出云会话")}
                    Text("回到应用后明确恢复原授权。云端模型和媒体尚无正式转发合同。",style=MaterialTheme.typography.bodySmall)}
            }else{
            item{OutlinedTextField(model.endpoint,model::editEndpoint,label={Text("HTTPS 网关地址")},modifier=Modifier.fillMaxWidth(),enabled=!model.busy)}
            item{OutlinedTextField(model.token,{model.token=it},label={Text("所有者凭据，留空恢复会话")},visualTransformation=PasswordVisualTransformation(),modifier=Modifier.fillMaxWidth(),enabled=!model.busy)}
            item{Row{Button(model::connect,enabled=!model.busy){Text("连接")};TextButton(model::logout,enabled=!model.busy){Text("退出")}}}
            }
            items(model.spaces){space->Row{RadioButton(model.space==space,{model.selectSpace(space)},enabled=!model.busy);Text(space)}}
            item{Button(model::refresh,enabled=!model.busy){Text("刷新电脑与能力")}}
            items(model.devices){device->Row{RadioButton(model.target==device.deviceId,{model.select(device.deviceId)},enabled=!model.busy);Text(device.deviceId+if(device.ready)" · 在线" else " · 离线")}}
            item{OutlinedTextField(model.name,{model.name=it},label={Text("本客户端名称")},modifier=Modifier.fillMaxWidth());Text("本客户端指纹\n"+model.fingerprint,style=MaterialTheme.typography.bodySmall)}
            item{Row{Button({model.action("pair")},enabled=!model.busy&&!model.pending){Text("请求配对")};TextButton({model.action("status")},enabled=!model.busy&&!model.pending){Text("检查配对状态")}};Text("请在电脑本机核对并批准，120 秒内有效。")}
            item{TextButton({confirmingReapply=true},enabled=!model.busy&&!model.pending){Text("重新申请已失效的配对")}}
            item{OutlinedTextField(model.text,{model.text=it},label={Text("纯文本草稿")},minLines=5,modifier=Modifier.fillMaxWidth(),enabled=!model.busy)}
            item{Text("${model.text.toByteArray().size} / 2048 字节");Button({model.action("card")},enabled=!model.busy&&!model.pending){Text("确认发送到所选电脑")};TextButton(::launchVoice,enabled=!model.busy){Text("系统语音草稿")};Text("系统语音服务可能处理录音；识别结果只进入草稿。",style=MaterialTheme.typography.bodySmall)}
            if(!model.cloudMode)item{Text("网关模型将处理当前草稿，提供方由网关配置；生成不会触发设备操作。");Row{Button({model.modelDraft(false)},enabled=!model.busy){Text("生成草稿")};TextButton({model.modelDraft(true)},enabled=!model.busy){Text("查询原模型任务")}}}
            item{HorizontalDivider();Text(model.message);if(model.busy)LinearProgressIndicator(Modifier.fillMaxWidth())}
            if(model.cloudMode){
                item{Text("当前账号全部空间的原操作",style=MaterialTheme.typography.titleMedium)}
                items(model.cloudRecords){record->Row{RadioButton(model.recordKey==record.id,{model.recordKey=record.id},enabled=!model.busy);Text(listOf(record.reference.spaceId,record.reference.request.deviceId,if(record.isPrepared)"尚未提交" else record.result?.status?.name?:record.rejection?:"未知",record.id.take(8)).joinToString(" · "))}}
                item{Row{Button({model.resolve()},enabled=!model.busy){Text("查询原请求")};TextButton({model.resolve(true)},enabled=!model.busy){Text("核对原网关回执")}};TextButton(model::finish,enabled=!model.busy){Text("完成已结束记录 / 放弃未提交准备")};Text("未知结果保留并阻止新提交；切换空间或电脑不重建请求。",style=MaterialTheme.typography.bodySmall)}
            }else if(model.pending)item{Row{Button({model.resolve()},enabled=!model.busy){Text("查询原请求")};TextButton(model::finish,enabled=!model.busy){Text("完成已核实记录")}}}
            item{OutlinedTextField(model.cancel,{model.cancel=it},label={Text("取消的原卡片 ID")});TextButton({model.action("cancel")},enabled=!model.busy&&!model.pending){Text("请求取消待展示卡片")}}
            item{Text("会话接续",style=MaterialTheme.typography.titleLarge);OutlinedTextField(model.session,{model.session=it},label={Text("会话 ID，新建可留空")});OutlinedTextField(model.revision,{model.revision=it},label={Text("当前修订")})}
            item{Row{Button({model.action("session_create")},enabled=!model.busy&&!model.pending){Text("建立会话")};TextButton({model.action("session_claim")},enabled=!model.busy&&!model.pending){Text("取得输入资格")}}}
            item{Row{Button({model.action("session_write")},enabled=!model.busy&&!model.pending){Text("写入草稿修订")};TextButton({model.action("session_release")},enabled=!model.busy&&!model.pending){Text("释放资格")}}}
            item{Text("有界内容",style=MaterialTheme.typography.titleLarge);OutlinedTextField(model.content,{model.content=it},label={Text("内容 ID")});Row{Button({model.action("content_put")},enabled=!model.busy&&!model.pending){Text("安装文本内容")};TextButton({model.action("content_remove")},enabled=!model.busy&&!model.pending){Text("移除")}}}
            item{TextButton({model.action("revoke")},enabled=!model.busy&&!model.pending){Text("撤销此客户端的协同")};Text("手机后台不承担常驻网关职责；恢复后核对原请求，不自动重复发送。",style=MaterialTheme.typography.bodySmall)}
        }
    }
}
