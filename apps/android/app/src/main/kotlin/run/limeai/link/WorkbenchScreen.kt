package run.limeai.link

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.delay

@OptIn(ExperimentalMaterial3Api::class)
@Composable internal fun WorkbenchScreen(model:Workbench=viewModel()){
    var page by rememberSaveable{mutableStateOf("助手")}
    var settings by rememberSaveable{mutableStateOf(false)}
    var pairing by rememberSaveable{mutableStateOf(false)}
    var confirmingReapply by remember{mutableStateOf(false)}
    val connected=model.spaces.isNotEmpty()
    val keyboardVisible=WindowInsets.ime.getBottom(LocalDensity.current)>0
    LaunchedEffect(model.connectionSelection){if(model.connectionSelection>0)page="网关"}
    LaunchedEffect(model.paired){if(model.paired){pairing=false;if(page=="网关")page="协同"}}
    LaunchedEffect(model.target,model.pairingState){if(model.pairingState=="pending")repeat(45){delay(2000);model.checkPairing()}}
    model.connectionRequest?.let{request->AlertDialog(onDismissRequest=model::dismissConnection,title={Text("连接网关")},text={Text(request.origin)},confirmButton={TextButton(model::acceptConnection,enabled=!model.busy){Text("使用此地址")}},dismissButton={TextButton(model::dismissConnection){Text("取消")}})}
    if(confirmingReapply)AlertDialog(onDismissRequest={confirmingReapply=false},title={Text("重新配对这台电脑？")},text={Text("旧会话与内容将清除，电脑需要再次批准。未完成请求需先核实。")},confirmButton={TextButton({confirmingReapply=false;model.action("pair",reapply=true)}){Text("重新配对")}},dismissButton={TextButton({confirmingReapply=false}){Text("取消")}})
    if(settings)ModalBottomSheet(onDismissRequest={settings=false},sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),containerColor=Radix.slate1){
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal=24.dp).padding(bottom=28.dp),verticalArrangement=Arrangement.spacedBy(20.dp)){
            Text("设置",style=MaterialTheme.typography.titleLarge)
            LinkSettingRow("gateway","网关连接",if(connected)gatewayHost(model)else "尚未连接"){settings=false;page="网关"}
            LinkDisclosure("诊断信息"){SelectionContainer{Text(listOf(model.endpoint,model.target,model.fingerprint,model.diagnostic,model.message).filter{it.isNotBlank()}.joinToString("\n"),style=MaterialTheme.typography.bodySmall,color=Radix.slate11)}}
            HorizontalDivider(thickness=0.5.dp,color=Radix.slate6)
            Row(verticalAlignment=Alignment.CenterVertically){Image(painterResource(R.drawable.link_brand),null,Modifier.size(44.dp));Spacer(Modifier.width(12.dp));Column{Text("LimeLink 柠联",fontWeight=FontWeight.SemiBold);Text("开发版 0.1.0",style=MaterialTheme.typography.bodySmall,color=Radix.slate11)}}
            if(connected)TextButton({settings=false;model.logout()},enabled=!model.busy){Text("退出当前网关",color=Radix.red11)}
        }
    }
    if(pairing)ModalBottomSheet(onDismissRequest={pairing=false},sheetState=rememberModalBottomSheetState(skipPartiallyExpanded=true),containerColor=Radix.slate1){
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp),verticalArrangement=Arrangement.spacedBy(20.dp)){
            ConnectionPanel(model)
            if(model.paired)LinkPrimaryButton("完成",{pairing=false},Modifier.fillMaxWidth())
            LinkDisclosure("管理连接"){LinkTextField(model.name,{model.name=it},"手机名称",enabled=!model.busy);TextButton({pairing=false;confirmingReapply=true},enabled=!model.busy&&!model.pending){Text("重新连接")};TextButton({model.action("revoke")},enabled=!model.busy&&!model.pending){Text("取消连接",color=Radix.red11)}}
        }
    }
    val background=Brush.linearGradient(listOf(Radix.teal2,Radix.slate2,Radix.blue2))
    Box(Modifier.fillMaxSize().background(background)){
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Top+WindowInsetsSides.Horizontal))){
            Row(Modifier.fillMaxWidth().height(72.dp).padding(horizontal=24.dp),verticalAlignment=Alignment.CenterVertically){
                Image(painterResource(R.drawable.link_brand),null,Modifier.size(36.dp))
                Spacer(Modifier.width(10.dp));Text("柠联",style=MaterialTheme.typography.titleLarge)
                Spacer(Modifier.weight(1f))
                if(model.paired)Text("已连接",style=MaterialTheme.typography.bodySmall,color=Radix.teal11,modifier=Modifier.clip(RoundedCornerShape(6.dp)).background(Radix.teal3).padding(horizontal=10.dp,vertical=5.dp))
                IconButton({settings=true},modifier=Modifier.semantics{contentDescription="设置"}){LinkIcon("settings",color=Radix.slate11)}
            }
            if(model.busy)LinearProgressIndicator(Modifier.fillMaxWidth().height(2.dp),color=Radix.teal11,trackColor=Color.Transparent)
            Column(Modifier.weight(1f).fillMaxWidth().imePadding().verticalScroll(rememberScrollState()).padding(horizontal=24.dp).padding(top=12.dp,bottom=28.dp),verticalArrangement=Arrangement.spacedBy(24.dp)){
                if(page=="网关")GatewayPanel(model,{if(model.paired)page="协同"else pairing=true})
                else if(model.busy&&connected&&model.target.isEmpty())Text("正在连接电脑…",color=Radix.slate11)
                else if(!connected||model.target.isEmpty()){
                    LinkWelcome(page,connected){page="网关";if(!connected&&model.endpoint.isNotEmpty())model.connect()}
                    if(connected&&model.devices.isNotEmpty())DevicePicker(model){pairing=true}
                }else if(!model.paired&&!model.cloudMode){LinkPanel{ConnectionPanel(model)}}else{
                    Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically){
                        Column(Modifier.weight(1f)){Text(if(page=="助手")"电脑助手"else "发送到电脑",style=MaterialTheme.typography.titleLarge);Text(model.devices.singleOrNull{it.deviceId==model.target}?.let{if(it.ready)"电脑在线"else "电脑离线"}?:"所选电脑",style=MaterialTheme.typography.bodySmall,color=Radix.slate11)}
                        if(model.devices.size>1)TextButton({page="网关"},enabled=!model.busy){Text("切换")}
                        IconButton({pairing=true},enabled=!model.busy,modifier=Modifier.semantics{contentDescription="管理电脑连接"}){LinkIcon("shield",Modifier.size(20.dp))}
                    }
                    if(page=="助手")AssistantPanel(model)else CollaborationPanel(model)
                }
                if(!model.busy&&model.message !in listOf("连接网关后，明确选择空间和电脑。","网关地址已填入，请登录或恢复连接。")&&!(page=="助手"&&model.agentRun?.stateText==model.message))LinkNotice(model)
                if(model.pending&&!model.busy)LinkPanel{
                    Text("正在核实操作结果",fontWeight=FontWeight.SemiBold)
                    TextButton({if(page=="助手"&&model.paired)model.recoverAgent()else model.resolve()},enabled=!model.busy){Text("重新检查")}
                }
                if(model.cloudMode&&model.cloudRecords.isNotEmpty())LinkDisclosure("云端任务记录"){
                    model.cloudRecords.forEachIndexed{index,record->LinkChoice("任务 ${index+1}",if(record.isPrepared)"尚未提交"else if(record.canForget)"已结束"else "等待确认",model.recordKey==record.id,!model.busy){model.recordKey=record.id}}
                    TextButton({model.resolve()},enabled=!model.busy&&model.recordKey.isNotEmpty()){Text("检查结果")};TextButton({model.resolve(true)},enabled=!model.busy&&model.recordKey.isNotEmpty()){Text("重新核实")};TextButton(model::finish,enabled=!model.busy&&model.recordKey.isNotEmpty()){Text("完成记录")}
                }
            }
            if(!keyboardVisible){
            HorizontalDivider(thickness=0.5.dp,color=Radix.slate6)
            Row(Modifier.fillMaxWidth().background(Radix.slate1.copy(alpha=0.95f)).windowInsetsPadding(WindowInsets.navigationBars.only(WindowInsetsSides.Bottom)).height(72.dp).selectableGroup(),verticalAlignment=Alignment.CenterVertically){
                listOf("助手" to "assistant","协同" to "send","网关" to "gateway").forEach{(label,icon)->
                    val selected=page==label
                    Column(Modifier.weight(1f).fillMaxHeight().selectable(selected,role=Role.Tab,onClick={page=label}),horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.Center){
                        Box(Modifier.size(54.dp,30.dp).clip(RoundedCornerShape(10.dp)).background(if(selected)Radix.teal3 else Color.Transparent),contentAlignment=Alignment.Center){LinkIcon(icon,color=if(selected)Radix.teal11 else Radix.slate11)}
                        Spacer(Modifier.height(3.dp));Text(if(label=="网关")"设备"else label,style=MaterialTheme.typography.bodySmall,color=if(selected)Radix.teal12 else Radix.slate11,fontWeight=if(selected)FontWeight.SemiBold else FontWeight.Normal)
                    }
                }
            }
            }
        }
    }
}

private fun gatewayHost(model:Workbench):String=runCatching{Uri.parse(if(model.cloudMode)model.cloudEndpoint else model.endpoint).host}.getOrNull()?:"当前网关"
private fun computerName(model:Workbench,id:String):String=if(model.devices.size==1)"我的电脑"else "电脑 ${model.devices.indexOfFirst{it.deviceId==id}+1}"

@Composable private fun ConnectionPanel(model:Workbench){
    val waiting=model.pairingState=="pending"
    Text(if(model.paired)"电脑已连接"else if(waiting)"在电脑上确认连接"else "连接电脑",style=MaterialTheme.typography.titleLarge)
    Row(verticalAlignment=Alignment.CenterVertically){LinkIcon("computer",color=Radix.teal11);Spacer(Modifier.width(12.dp));Text(computerName(model,model.target),fontWeight=FontWeight.SemiBold)}
    if(waiting){
        Text(model.fingerprint.take(8).uppercase().chunked(4).joinToString(" "),style=MaterialTheme.typography.titleLarge)
        Text("确认两端核对码一致。",style=MaterialTheme.typography.bodySmall,color=Radix.slate11)
    }
    if(!model.paired)LinkPrimaryButton(if(waiting&&!model.pairingTimedOut)"等待电脑确认"else if(waiting)"检查连接"else "连接电脑",{model.action(if(waiting)"status"else "pair")},Modifier.fillMaxWidth(),!model.busy&&!model.pending&&(!waiting||model.pairingTimedOut)&&model.devices.any{it.deviceId==model.target&&it.ready},"computer")
}

@Composable private fun LinkWelcome(page:String,connected:Boolean,onConnect:()->Unit){
    Column(Modifier.fillMaxWidth().padding(top=16.dp),verticalArrangement=Arrangement.spacedBy(12.dp)){
        Text(if(page=="助手")"把任务交给电脑"else "手机与电脑，随时接续",style=MaterialTheme.typography.titleLarge)
        Image(painterResource(if(page=="助手")R.drawable.link_welcome else R.drawable.link_devices),null,Modifier.fillMaxWidth().height(232.dp),contentScale=ContentScale.Fit)
        LinkPrimaryButton(if(connected)"选择电脑"else "连接电脑",onConnect,Modifier.fillMaxWidth(),icon="computer")
    }
}

@Composable private fun GatewayPanel(model:Workbench,onUseComputer:()->Unit){
    var manual by rememberSaveable{mutableStateOf(false)}
    var manualAddress by rememberSaveable{mutableStateOf("")}
    val connected=model.spaces.isNotEmpty()
    if(manual)AlertDialog(onDismissRequest={manual=false},title={Text("添加网关")},text={LinkTextField(manualAddress,{manualAddress=it},"网关地址",enabled=!model.busy,placeholder="https://",keyboardType=KeyboardType.Uri)},confirmButton={TextButton({model.editEndpoint(manualAddress);manual=false},enabled=!model.busy&&runCatching{run.limeai.link.core.GatewayConnectionRequest.fromOrigin(manualAddress)}.isSuccess){Text("使用地址")}},dismissButton={TextButton({manual=false}){Text("取消")}})
    Text(if(connected)"我的设备"else "连接电脑",style=MaterialTheme.typography.titleLarge)
    if(model.cloudMode){
        CloudGatewayPanel(model,connected)
    }else if(!connected){
        if(model.endpoint.isNotEmpty())LinkPanel{
            Row(verticalAlignment=Alignment.CenterVertically){LinkIcon("computer",color=Radix.teal11);Spacer(Modifier.width(12.dp));Text(gatewayHost(model),Modifier.weight(1f),fontWeight=FontWeight.SemiBold,maxLines=1,overflow=TextOverflow.Ellipsis)}
            if(model.requiresToken)LinkTextField(model.token,{model.token=it},"访问密钥",enabled=!model.busy,visualTransformation=PasswordVisualTransformation(),keyboardType=KeyboardType.Password)
            LinkPrimaryButton(if(model.busy)"正在连接…"else "连接电脑",model::connect,Modifier.fillMaxWidth(),!model.busy,"computer")
        }
        if(model.endpoint.isEmpty())LinkPanel{
            Row(verticalAlignment=Alignment.CenterVertically){Text("附近的网关",Modifier.weight(1f),fontWeight=FontWeight.SemiBold);IconButton(model.discovery::restart,enabled=!model.busy&&!model.discovery.searching,modifier=Modifier.semantics{contentDescription="重新查找网关"}){LinkIcon("refresh",Modifier.size(20.dp),Radix.slate11)}}
            if(model.discovery.gateways.isEmpty()){
                Text(if(model.discovery.searching)"正在查找附近的网关…"else model.discovery.message,color=Radix.slate11)
            }else model.discovery.gateways.forEach{candidate->LinkChoice(candidate.name,candidate.origin,model.endpoint==candidate.origin,!model.busy){model.editEndpoint(candidate.origin);manual=false;model.connect()}}
            if(model.endpoint.isEmpty()){
                TextButton({manualAddress="";manual=true},enabled=!model.busy){LinkIcon("plus",Modifier.size(18.dp));Spacer(Modifier.width(6.dp));Text("添加远程网关")}
            }
        }
    }
    if(connected){
        if(model.spaces.size>1)LinkPanel{
            LinkPicker("工作空间",model.space.ifEmpty{"选择工作空间"},model.spaces,!model.busy,display={"工作空间 ${model.spaces.indexOf(it)+1}"},onSelect=model::selectSpace)
            LinkPrimaryButton("查找电脑",model::refresh,Modifier.fillMaxWidth(),!model.busy&&model.space.isNotEmpty(),"refresh")
        }
        if(model.devices.isNotEmpty())DevicePicker(model,onUseComputer)
        else LinkPrimaryButton(if(model.busy)"正在查找…"else "重新查找",model::refresh,Modifier.fillMaxWidth(),!model.busy&&model.space.isNotEmpty(),"refresh")
    }
    if(!connected)LinkDisclosure("其他连接方式"){
        TextButton({manualAddress=model.endpoint;manual=true},enabled=!model.busy){Text("输入网关地址")}
        TextButton({model.toggleCloudMode(!model.cloudMode)},enabled=!model.busy){Text(if(model.cloudMode)"使用本地网关"else "使用云账号")}
    }
}

@Composable private fun CloudGatewayPanel(model:Workbench,connected:Boolean){
    val context=LocalContext.current
    LinkPanel{
        if(!connected){
            LinkTextField(model.cloudEndpoint,model::editCloudEndpoint,"云服务地址",enabled=!model.busy,placeholder="https://",keyboardType=KeyboardType.Uri)
            LinkPrimaryButton("登录云账号",model::beginCloud,Modifier.fillMaxWidth(),!model.busy)
            TextButton(model::restoreCloud,enabled=!model.busy){Text("恢复上次会话")}
        }else{Text(model.principal,fontWeight=FontWeight.SemiBold);Text(gatewayHost(model),style=MaterialTheme.typography.bodySmall,color=Radix.slate11)}
        model.authorization?.let{login->
            Text(login.userCode,style=MaterialTheme.typography.titleLarge)
            LinkPrimaryButton("打开浏览器授权",{try{context.startActivity(Intent(Intent.ACTION_VIEW,Uri.parse(login.verificationUri)))}catch(_:Exception){model.message="未能打开系统浏览器。"}},Modifier.fillMaxWidth(),!model.busy)
            TextButton(model::pollCloud,enabled=!model.busy){Text("完成登录")};TextButton(model::cancelCloud,enabled=!model.busy){Text("取消登录")}
        }
    }
}

@Composable private fun DevicePicker(model:Workbench,onUse:()->Unit){
    Column(verticalArrangement=Arrangement.spacedBy(12.dp)){
        model.devices.forEach{device->
            LinkPanel{Row(Modifier.fillMaxWidth().clickable(enabled=!model.busy){model.select(device.deviceId);onUse()},verticalAlignment=Alignment.CenterVertically){
                Box(Modifier.size(44.dp).clip(RoundedCornerShape(10.dp)).background(Radix.teal3),contentAlignment=Alignment.Center){LinkIcon("computer",color=Radix.teal11)}
                Spacer(Modifier.width(12.dp));Column(Modifier.weight(1f)){Text(computerName(model,device.deviceId),fontWeight=FontWeight.SemiBold,maxLines=1,overflow=TextOverflow.Ellipsis);Text(if(device.ready)"在线"else "离线",style=MaterialTheme.typography.bodySmall,color=if(device.ready)Radix.teal11 else Radix.slate11)}
                if(model.target==device.deviceId)LinkIcon("check",Modifier.size(20.dp),Radix.teal11)else LinkIcon("chevron",Modifier.size(18.dp),Radix.slate11)
            }}
        }
        if(model.target.isNotEmpty()){
            if(model.paired)LinkPrimaryButton("开始协同",onUse,Modifier.fillMaxWidth(),!model.busy,"computer")
            else LinkPanel{ConnectionPanel(model)}
        }
    }
}

@Composable internal fun LinkPicker(label:String,value:String,choices:List<String>,enabled:Boolean=true,display:(String)->String={it},onSelect:(String)->Unit){
    var expanded by remember{mutableStateOf(false)}
    Column(verticalArrangement=Arrangement.spacedBy(8.dp)){
        Text(label,style=MaterialTheme.typography.bodySmall,color=Radix.slate11)
        Box{OutlinedButton({expanded=true},enabled=enabled,modifier=Modifier.fillMaxWidth().heightIn(min=50.dp),shape=RoundedCornerShape(10.dp),border=androidx.compose.foundation.BorderStroke(0.5.dp,Radix.slate7)){
            Text(if(value in choices)display(value)else value,Modifier.weight(1f),color=Radix.slate12,maxLines=1,overflow=TextOverflow.Ellipsis);LinkIcon("down",Modifier.size(16.dp),Radix.slate11)
        };DropdownMenu(expanded,{expanded=false}){choices.forEach{choice->DropdownMenuItem(text={Text(display(choice))},onClick={expanded=false;onSelect(choice)})}}}
    }
}

@Composable internal fun LinkChoice(title:String,subtitle:String,selected:Boolean,enabled:Boolean=true,onClick:()->Unit){
    Row(Modifier.fillMaxWidth().heightIn(min=56.dp).selectable(selected,enabled=enabled,role=Role.RadioButton,onClick=onClick).padding(vertical=8.dp),verticalAlignment=Alignment.CenterVertically){
        Column(Modifier.weight(1f)){Text(title,maxLines=2,overflow=TextOverflow.Ellipsis);if(subtitle.isNotEmpty())Text(subtitle,style=MaterialTheme.typography.bodySmall,color=Radix.slate11,maxLines=2,overflow=TextOverflow.Ellipsis)}
        RadioButton(selected,null,enabled=enabled)
    }
}

@Composable internal fun LinkDisclosure(title:String,content:@Composable ColumnScope.()->Unit){
    var expanded by rememberSaveable{mutableStateOf(false)}
    Column(Modifier.fillMaxWidth()){
        Row(Modifier.fillMaxWidth().heightIn(min=52.dp).clickable{expanded=!expanded},verticalAlignment=Alignment.CenterVertically){Text(title,Modifier.weight(1f),fontWeight=FontWeight.Medium);LinkIcon(if(expanded)"down"else "chevron",Modifier.size(18.dp),Radix.slate11)}
        if(expanded)Column(Modifier.padding(top=8.dp,bottom=16.dp),verticalArrangement=Arrangement.spacedBy(16.dp),content=content)
        HorizontalDivider(thickness=0.5.dp,color=Radix.slate6)
    }
}

@Composable private fun LinkSettingRow(icon:String,title:String,subtitle:String,onClick:(()->Unit)?=null){
    Row(Modifier.fillMaxWidth().heightIn(min=60.dp).then(if(onClick!=null)Modifier.clickable(onClick=onClick)else Modifier),verticalAlignment=Alignment.CenterVertically){LinkIcon(icon,color=Radix.teal11);Spacer(Modifier.width(14.dp));Column(Modifier.weight(1f)){Text(title,fontWeight=FontWeight.Medium);Text(subtitle,style=MaterialTheme.typography.bodySmall,color=Radix.slate11)};if(onClick!=null)LinkIcon("chevron",Modifier.size(18.dp),Radix.slate11)}
}

@Composable private fun LinkNotice(model:Workbench){
    if(model.message.isEmpty())return
    Column(verticalArrangement=Arrangement.spacedBy(8.dp)){
        Row(horizontalArrangement=Arrangement.spacedBy(8.dp)){LinkIcon("info",Modifier.size(18.dp),Radix.slate11);Text(model.message.lineSequence().first(),style=MaterialTheme.typography.bodySmall,color=Radix.slate11,modifier=Modifier.weight(1f))}
    }
}

@Composable private fun CollaborationPanel(model:Workbench){
    val voice=rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()){result->if(result.resultCode==Activity.RESULT_OK)result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()?.let{model.text=it}}
    fun launchVoice(){try{voice.launch(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL,RecognizerIntent.LANGUAGE_MODEL_FREE_FORM).putExtra(RecognizerIntent.EXTRA_LANGUAGE,"zh-CN").putExtra(RecognizerIntent.EXTRA_MAX_RESULTS,1))}catch(_:Exception){model.message="未安装系统语音识别服务，可以直接输入草稿。"}}
    val enabled=!model.busy&&!model.pending
    LinkPanel{
        LinkTextField(model.text,{model.text=it},"发送内容",minLines=4,enabled=!model.busy,placeholder="输入要发送的内容…")
        Row(verticalAlignment=Alignment.CenterVertically,horizontalArrangement=Arrangement.spacedBy(12.dp)){
            TextButton(::launchVoice,enabled=!model.busy){Text("语音输入")}
            LinkPrimaryButton("发送",{model.action("card")},Modifier.weight(1f),enabled&&model.text.isNotBlank(),"send")
        }
    }
    LinkDisclosure("更多操作"){
    if(!model.cloudMode)LinkDisclosure("整理草稿"){
        Text("生成结果先保留为草稿。",style=MaterialTheme.typography.bodySmall,color=Radix.slate11)
        TextButton({model.modelDraft(false)},enabled=!model.busy&&model.text.isNotBlank()){Text("AI 整理")};TextButton({model.modelDraft(true)},enabled=!model.busy){Text("查询原模型任务")}
    }
    LinkDisclosure("共同编辑"){
        TextButton({model.action("session_create")},enabled=enabled){Text("新建共同编辑")}
        if(model.session.isNotEmpty()){
            TextButton({model.action("session_claim")},enabled=enabled){Text("开始编辑")}
            Row{TextButton({model.action("session_write")},enabled=enabled){Text("保存修改")};TextButton({model.action("session_release")},enabled=enabled){Text("结束编辑")}}
        }
    }
    LinkDisclosure("保存内容"){
        Row{TextButton({model.action("content_put")},enabled=enabled&&model.text.isNotBlank()){Text("保存到电脑")};if(model.content.isNotEmpty())TextButton({model.action("content_remove")},enabled=enabled){Text("移除已保存内容")}}
    }
    if(model.cancel.isNotEmpty())TextButton({model.action("cancel")},enabled=enabled){Text("撤回上一条消息")}
    }
}
