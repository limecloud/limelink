package run.limeai.link

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.unit.dp

// 统一24单位轮廓图标，按钮本身提供可访问名称。
@Composable internal fun LinkIcon(name:String,modifier:Modifier=Modifier,color:Color=LocalContentColor.current){
    Canvas(modifier.size(24.dp)){
        scale(size.width/24f,size.height/24f,pivot=Offset.Zero){
            val stroke=Stroke(1.7f,cap=StrokeCap.Round)
            fun line(x:Float,y:Float,x2:Float,y2:Float)=drawLine(color,Offset(x,y),Offset(x2,y2),1.7f,StrokeCap.Round)
            when(name){
                "assistant"->{
                    drawRoundRect(color,Offset(4f,6f),Size(16f,13f),CornerRadius(5f),style=stroke)
                    line(12f,3f,12f,6f);line(1.5f,11f,1.5f,14f);line(22.5f,11f,22.5f,14f)
                    drawCircle(color,1f,Offset(8.5f,11.5f));drawCircle(color,1f,Offset(15.5f,11.5f));line(9f,16f,15f,16f)
                }
                "computer"->{drawRoundRect(color,Offset(3f,4f),Size(18f,13f),CornerRadius(2f),style=stroke);line(12f,17f,12f,21f);line(8f,21f,16f,21f)}
                "gateway"->{drawRoundRect(color,Offset(3f,10f),Size(18f,10f),CornerRadius(3f),style=stroke);drawCircle(color,1f,Offset(7f,15f));line(12f,15f,17f,15f);line(7f,10f,7f,5f);line(17f,10f,17f,5f);line(10f,3f,14f,3f)}
                "send"->{val p=Path().apply{moveTo(21f,3f);lineTo(14f,21f);lineTo(10f,14f);lineTo(3f,10f);close()};drawPath(p,color,style=stroke);line(10f,14f,21f,3f)}
                "settings"->{
                    val p=Path().apply{moveTo(9f,2f);lineTo(15f,2f);lineTo(16f,5f);lineTo(19f,5f);lineTo(22f,10f);lineTo(20f,12f);lineTo(22f,14f);lineTo(19f,19f);lineTo(16f,19f);lineTo(15f,22f);lineTo(9f,22f);lineTo(8f,19f);lineTo(5f,19f);lineTo(2f,14f);lineTo(4f,12f);lineTo(2f,10f);lineTo(5f,5f);lineTo(8f,5f);close()}
                    drawPath(p,color,style=stroke);drawCircle(color,3.5f,Offset(12f,12f),style=stroke)
                }
                "chevron"->{line(9f,6f,15f,12f);line(15f,12f,9f,18f)}
                "down"->{line(6f,9f,12f,15f);line(12f,15f,18f,9f)}
                "check"->{line(5f,12f,10f,17f);line(10f,17f,20f,7f)}
                "plus"->{line(12f,5f,12f,19f);line(5f,12f,19f,12f)}
                "refresh"->{drawArc(color,35f,280f,false,Offset(4f,4f),Size(16f,16f),style=stroke);line(20f,4f,20f,10f);line(14f,10f,20f,10f)}
                "shield"->{val p=Path().apply{moveTo(12f,2f);lineTo(20f,5f);lineTo(20f,12f);quadraticTo(19f,18f,12f,22f);quadraticTo(5f,18f,4f,12f);lineTo(4f,5f);close()};drawPath(p,color,style=stroke);line(8f,11f,11f,14f);line(11f,14f,16f,9f)}
                "history"->{drawCircle(color,9f,Offset(12f,12f),style=stroke);line(12f,7f,12f,12f);line(12f,12f,16f,14f)}
                "info"->{drawCircle(color,9f,Offset(12f,12f),style=stroke);drawCircle(color,1f,Offset(12f,7f));line(12f,11f,12f,17f)}
            }
        }
    }
}
