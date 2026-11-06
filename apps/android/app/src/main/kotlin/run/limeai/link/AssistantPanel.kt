package run.limeai.link

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.serialization.json.*

@Composable internal fun AssistantPanel(model:Workbench){
    if(model.cloudMode){Text("助手需要直连执行电脑所在的网关。",color=Radix.slate11);return}
    val ready=!model.busy&&!model.pending&&model.target.isNotEmpty()
    LaunchedEffect(model.target,model.paired){if(model.paired&&model.agentCapabilities==null){while(model.busy)delay(100);if(!model.pending)model.discoverAgent()}}
    LaunchedEffect(model.agentRunId){if(model.agentRunId.isNotEmpty())while(true){delay(2000);model.pollAgent()}}
    if(model.agentCapabilities==null){
        LinkPanel{
            Row(horizontalArrangement=Arrangement.spacedBy(12.dp),verticalAlignment=Alignment.CenterVertically){LinkIcon("assistant",color=Radix.teal11);Text(if(model.busy)"正在连接电脑助手…"else "电脑助手尚未就绪",fontWeight=FontWeight.SemiBold)}
            if(!model.busy)LinkPrimaryButton("重新连接",model::discoverAgent,Modifier.fillMaxWidth(),ready,"refresh")
        }
    }else LinkPanel{
        val workspace=model.agentCapabilities?.workspaces?.singleOrNull{it.id==model.agentWorkspace}
        val workspaces=model.agentCapabilities?.workspaces.orEmpty()
        if(workspaces.size>1)LinkPicker("工作目录",workspace?.id?:"选择工作目录",workspaces.map{it.id},!model.busy,display={id->workspaces.single{it.id==id}.name},onSelect=model::selectAgentWorkspace)
        else workspace?.let{Text(it.name,fontWeight=FontWeight.SemiBold)}
        LinkTextField(model.agentText,{model.agentText=it},"交给助手的任务",minLines=3,enabled=!model.busy,placeholder="例如，整理这个项目的待办事项…")
        if(workspace?.allowWrite==true)Row(verticalAlignment=Alignment.CenterVertically){Checkbox(model.agentWrite,{model.agentWrite=it},enabled=!model.busy);Text("允许修改所选目录")}
        if(model.agentToolEnabled){
            if(model.agentContinue){if(model.agentDeviceScope.isNotEmpty())Text("本次会话已授权 ${model.agentDeviceScope.size} 台设备",style=MaterialTheme.typography.bodySmall,color=Radix.slate11)}
            else if(model.agentIoTDevices.isNotEmpty())LinkDisclosure("允许访问的设备（${model.agentSelectedDevices.size}）"){
                model.agentIoTDevices.forEach{device->Row(verticalAlignment=Alignment.CenterVertically){
                    Checkbox(device.deviceId in model.agentSelectedDevices,{model.selectAgentDevice(device.deviceId,it)},enabled=!model.busy&&(device.deviceId in model.agentSelectedDevices||model.agentSelectedDevices.size<4))
                    Column{Text(model.agentDeviceName(device.deviceId));Text(if(device.ready)"在线"else "离线",style=MaterialTheme.typography.bodySmall,color=Radix.slate11)}
                }}
            }
        }
        LinkPrimaryButton("提交任务",model::submitAgent,Modifier.fillMaxWidth(),ready&&workspace!=null&&model.agentText.isNotBlank(),"send")
    }
    model.agentRun?.let{run->
        LinkPanel{
            Row(verticalAlignment=Alignment.CenterVertically){LinkIcon("assistant",color=Radix.teal11);Spacer(Modifier.width(10.dp));Text(run.stateText,fontWeight=FontWeight.SemiBold,modifier=Modifier.weight(1f));if(run.canCancel)TextButton({model.queryAgent(true)},enabled=ready){Text("停止")}}
            val text=model.agentEvents.filter{it.kind=="message"}.joinToString(""){it.text}
            if(text.isNotEmpty())SelectionContainer{Text(text)}
            if(run.events.size==4)TextButton({model.queryAgent()},enabled=ready){Text("继续读取回复")}
        }
    }
    model.agentToolRecords.forEach{record->LinkPanel{
        Text(model.agentDeviceName(record.call.device),fontWeight=FontWeight.SemiBold)
        Text(record.statusText,style=MaterialTheme.typography.bodySmall,color=Radix.slate11)
        if(record.call.isWrite){val value=record.call.value.jsonPrimitive;Text(model.agentPropertyName(record)+"："+if(value.booleanOrNull!=null&&!value.isString){if(value.boolean)"开启"else "关闭"}else value.content)}
        if(record.canConfirm)Row{
            LinkPrimaryButton("确认操作",{model.performAgentTool(record.id,Workbench.ToolAction.CONFIRM)},enabled=!model.busy&&!model.pending)
            TextButton({model.performAgentTool(record.id,Workbench.ToolAction.REJECT)},enabled=!model.busy&&!model.pending){Text("拒绝")}
        }
        if(record.needsRecovery)TextButton({model.performAgentTool(record.id,Workbench.ToolAction.RECOVER)},enabled=!model.busy){Text("检查操作结果")}
        if(record.outcome!=null&&!record.delivered)TextButton({model.performAgentTool(record.id,Workbench.ToolAction.REPORT)},enabled=!model.busy){Text(if(record.replyIntent==null)"提交结果"else "检查提交结果")}
    }}
    if(model.agentRecords.isNotEmpty())LinkDisclosure("任务记录（${model.agentRecords.size}）"){
        model.agentRecords.forEachIndexed{index,record->LinkChoice("任务 ${index+1}","",model.agentRunId==record.id,!model.busy){model.selectAgentRun(record.id)}}
        Row(verticalAlignment=Alignment.CenterVertically){Checkbox(model.agentContinue,{model.agentContinue=it},enabled=!model.busy&&model.agentRunId.isNotEmpty());Text("继续此任务的会话")}
        TextButton({model.queryAgent()},enabled=ready&&model.agentRunId.isNotEmpty()){Text("查看任务")}
    }
}
