package run.limeai.link

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.LocalTextSelectionColors
import androidx.compose.foundation.text.selection.TextSelectionColors
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable internal fun LinkTheme(content:@Composable ()->Unit){
    val body=TextStyle(fontSize=14.sp,lineHeight=22.sp)
    val title=body.copy(fontSize=22.sp,lineHeight=30.sp,fontWeight=FontWeight.SemiBold)
    val small=body.copy(fontSize=12.sp,lineHeight=18.sp)
    val typography=Typography(displayLarge=title,displayMedium=title,displaySmall=title,headlineLarge=title,headlineMedium=title,headlineSmall=title,titleLarge=title,titleMedium=body.copy(fontWeight=FontWeight.SemiBold),titleSmall=body.copy(fontWeight=FontWeight.SemiBold),bodyLarge=body,bodyMedium=body,bodySmall=small,labelLarge=body.copy(fontWeight=FontWeight.Medium),labelMedium=small,labelSmall=small)
    val colors=lightColorScheme(primary=Radix.teal11,onPrimary=Radix.white,primaryContainer=Radix.teal3,onPrimaryContainer=Radix.teal12,
        secondary=Radix.teal11,onSecondary=Radix.white,secondaryContainer=Radix.teal3,onSecondaryContainer=Radix.teal12,
        tertiary=Radix.blue11,onTertiary=Radix.white,tertiaryContainer=Radix.blue3,onTertiaryContainer=Radix.blue12,
        background=Radix.slate2,onBackground=Radix.slate12,surface=Radix.slate1,onSurface=Radix.slate12,surfaceVariant=Radix.slate3,onSurfaceVariant=Radix.slate11,surfaceTint=Color.Transparent,
        inverseSurface=Radix.slate12,inverseOnSurface=Radix.slate1,error=Radix.red11,onError=Radix.white,errorContainer=Radix.red3,onErrorContainer=Radix.red12,outline=Radix.slate7,outlineVariant=Radix.slate6,
        surfaceBright=Radix.slate1,surfaceDim=Radix.slate4,surfaceContainerLowest=Radix.white,surfaceContainerLow=Radix.slate2,surfaceContainer=Radix.slate3,surfaceContainerHigh=Radix.slate4,surfaceContainerHighest=Radix.slate5)
    MaterialTheme(colorScheme=colors,typography=typography,shapes=Shapes(small=RoundedCornerShape(10.dp),medium=RoundedCornerShape(16.dp),large=RoundedCornerShape(20.dp))){
        CompositionLocalProvider(LocalTextSelectionColors provides TextSelectionColors(Radix.teal11,Radix.teal4),content=content)
    }
}

@Composable internal fun LinkTextField(value:String,onValueChange:(String)->Unit,label:String,modifier:Modifier=Modifier,enabled:Boolean=true,minLines:Int=1,visualTransformation:VisualTransformation=VisualTransformation.None,placeholder:String="",keyboardType:KeyboardType=KeyboardType.Text){
    val shape=RoundedCornerShape(10.dp)
    Column(modifier.fillMaxWidth(),verticalArrangement=Arrangement.spacedBy(8.dp)){
        Text(label,style=MaterialTheme.typography.bodySmall,color=Radix.slate11)
        BasicTextField(value,onValueChange,enabled=enabled,minLines=minLines,singleLine=minLines==1,visualTransformation=visualTransformation,
            keyboardOptions=KeyboardOptions(capitalization=KeyboardCapitalization.None,autoCorrectEnabled=false,keyboardType=keyboardType),
            textStyle=MaterialTheme.typography.bodyMedium.copy(color=if(enabled)Radix.slate12 else Radix.slate11),cursorBrush=SolidColor(Radix.teal11),
            modifier=Modifier.fillMaxWidth().heightIn(min=50.dp).semantics{contentDescription=label}.clip(shape).background(Radix.slate1).border(0.5.dp,Radix.slate7,shape).padding(14.dp),
            decorationBox={inner->Box{if(value.isEmpty()&&placeholder.isNotEmpty())Text(placeholder,color=Radix.slate11);inner()}})
    }
}

@Composable internal fun LinkPrimaryButton(text:String,onClick:()->Unit,modifier:Modifier=Modifier,enabled:Boolean=true,icon:String?=null){
    val shape=RoundedCornerShape(10.dp)
    Button(onClick,enabled=enabled,modifier=modifier.heightIn(min=50.dp).clip(shape).background(if(enabled)Brush.horizontalGradient(listOf(Radix.teal11,Radix.teal12))else Brush.horizontalGradient(listOf(Radix.slate4,Radix.slate4))),
        shape=shape,colors=ButtonDefaults.buttonColors(containerColor=Color.Transparent,contentColor=Radix.white,disabledContainerColor=Color.Transparent,disabledContentColor=Radix.slate11),contentPadding=PaddingValues(horizontal=20.dp,vertical=12.dp)){
        if(icon!=null){LinkIcon(icon,Modifier.size(20.dp));Spacer(Modifier.width(8.dp))};Text(text)
    }
}

@Composable internal fun LinkPanel(modifier:Modifier=Modifier,content:@Composable ColumnScope.()->Unit){
    Column(modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Radix.white.copy(alpha=0.88f)).border(0.5.dp,Radix.slate6,RoundedCornerShape(16.dp)).padding(18.dp),verticalArrangement=Arrangement.spacedBy(16.dp),content=content)
}
