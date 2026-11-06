#!/usr/bin/env python3
"""从固定的 Radix 色表生成桌面和 Android 主题；支持离线一致性检查。"""
import argparse,json
from pathlib import Path
from xml.sax.saxutils import escape
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument("--check",action="store_true");args=parser.parse_args()
data=json.loads((root/"assets/desktop/design/radix-colors.json").read_text())
swift=["// 由 tools/generate-desktop-theme.py 生成，请勿手改。","import SwiftUI","enum DesktopColors {"]
for mode,colors in data["palettes"].items():
 swift.append(f"    static let {mode}:[String:UInt32] = [")
 swift.extend(f'        "{name}":0x{value[1:]},' for name,value in colors.items())
 swift.append("    ]")
swift.extend(['    static func color(_ name:String,dark:Bool)->Color {','        let value=(dark ? self.dark : light)[name]!','        return Color(.sRGB,red:Double((value>>16)&255)/255,green:Double((value>>8)&255)/255,blue:Double(value&255)/255,opacity:1)','    }','}'])
xaml=['<!-- 由 tools/generate-desktop-theme.py 生成，请勿手改。 -->','<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"><ResourceDictionary.ThemeDictionaries>']
for mode in ("light","dark"):
 xaml.append(f'<ResourceDictionary x:Key="{mode.title()}">')
 for name,value in data["palettes"][mode].items():xaml.append(f'<SolidColorBrush x:Key="LL{name}" Color="{value}" />')
 aliases={"ButtonBackground":"slate3","ButtonBackgroundPointerOver":"slate4","ButtonBackgroundPressed":"slate5","ButtonForeground":"slate12","ButtonBorderBrush":"slate7","ToggleButtonBackground":"slate2","ToggleButtonBackgroundChecked":"teal4","ToggleButtonForeground":"slate12","ToggleButtonBorderBrush":"slate7","TextControlBackground":"slate1","TextControlForeground":"slate12","TextControlBorderBrush":"slate7","TextControlPlaceholderForeground":"slate11","ComboBoxBackground":"slate1","ComboBoxForeground":"slate12","ComboBoxBorderBrush":"slate7"}
 for key,token in aliases.items():xaml.append(f'<SolidColorBrush x:Key="{key}" Color="{data["palettes"][mode][token]}" />')
 xaml.append(f'<LinearGradientBrush x:Key="LLWorkspaceBackground" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="{data["palettes"][mode]["teal2"]}" Offset="0"/><GradientStop Color="{data["palettes"][mode]["slate2"]}" Offset="0.5"/><GradientStop Color="{data["palettes"][mode]["blue2"]}" Offset="1"/></LinearGradientBrush>')
 xaml.append(f'<LinearGradientBrush x:Key="LLPrimaryBackground" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="{data["palettes"]["light"]["teal11"]}" Offset="0"/><GradientStop Color="{data["palettes"]["light"]["teal12"]}" Offset="1"/></LinearGradientBrush>')
 xaml.append('</ResourceDictionary>')
xaml.extend(['<ResourceDictionary x:Key="HighContrast">','<SolidColorBrush x:Key="LLslate1" Color="{ThemeResource SystemColorWindowColor}" />','<SolidColorBrush x:Key="LLslate2" Color="{ThemeResource SystemColorWindowColor}" />','<SolidColorBrush x:Key="LLWorkspaceBackground" Color="{ThemeResource SystemColorWindowColor}" />'])
for key in ("slate3","slate4","slate5"):xaml.append(f'<SolidColorBrush x:Key="LL{key}" Color="{{ThemeResource SystemColorButtonFaceColor}}" />')
for key in ("slate7","slate11","slate12","teal11","green11","amber11","red11"):xaml.append(f'<SolidColorBrush x:Key="LL{key}" Color="{{ThemeResource SystemColorWindowTextColor}}" />')
xaml.extend(['<SolidColorBrush x:Key="LLwhite" Color="{ThemeResource SystemColorHighlightTextColor}" />','<SolidColorBrush x:Key="LLPrimaryBackground" Color="{ThemeResource SystemColorHighlightColor}" />','<SolidColorBrush x:Key="LLteal9" Color="{ThemeResource SystemColorHighlightColor}" />','<SolidColorBrush x:Key="LLteal10" Color="{ThemeResource SystemColorHighlightColor}" />','</ResourceDictionary></ResourceDictionary.ThemeDictionaries>','<Style TargetType="TextBlock"><Setter Property="FontSize" Value="14"/><Setter Property="Foreground" Value="{ThemeResource LLslate12}"/></Style>',
'<Style TargetType="Button"><Setter Property="FontSize" Value="14"/><Setter Property="BorderThickness" Value="0.5"/><Setter Property="CornerRadius" Value="6"/><Setter Property="Padding" Value="14,9"/></Style>',
'<Style TargetType="ToggleButton"><Setter Property="FontSize" Value="14"/><Setter Property="BorderThickness" Value="0.5"/><Setter Property="CornerRadius" Value="6"/></Style>',
'<Style x:Key="LimeLinkPrimaryButton" TargetType="Button"><Setter Property="FontSize" Value="14"/><Setter Property="Foreground" Value="{ThemeResource LLwhite}"/><Setter Property="Background" Value="{ThemeResource LLPrimaryBackground}"/><Setter Property="BorderThickness" Value="0.5"/><Setter Property="CornerRadius" Value="6"/><Setter Property="Padding" Value="14,9"/></Style>',
'<Style TargetType="TextBox"><Setter Property="FontSize" Value="14"/><Setter Property="BorderThickness" Value="0.5"/><Setter Property="CornerRadius" Value="6"/></Style>',
'<Style TargetType="PasswordBox"><Setter Property="FontSize" Value="14"/><Setter Property="BorderThickness" Value="0.5"/><Setter Property="CornerRadius" Value="6"/></Style>',
'<Style TargetType="ComboBox"><Setter Property="FontSize" Value="14"/><Setter Property="BorderThickness" Value="0.5"/><Setter Property="CornerRadius" Value="6"/></Style>',
'<Style TargetType="Expander"><Setter Property="FontSize" Value="14"/><Setter Property="BorderThickness" Value="0"/><Setter Property="Background" Value="{ThemeResource LLslate2}"/></Style>',
'</ResourceDictionary>'])
kotlin=['// 由 tools/generate-desktop-theme.py 生成，请勿手改。','package run.limeai.link','import androidx.compose.ui.graphics.Color','internal object Radix {']
kotlin.extend(f'    val {name}=Color(0xFF{value[1:]})' for name,value in data['palettes']['light'].items())
kotlin.append('}')
outputs={"apps/macos/DesktopColors.generated.swift":"\n".join(swift)+"\n","apps/windows/LimeLink.App/DesktopColors.generated.xaml":"\n".join(xaml)+"\n","apps/android/app/src/main/kotlin/run/limeai/link/LinkColors.generated.kt":"\n".join(kotlin)+"\n"}
for name,text in outputs.items():
 p=root/name
 if args.check:assert p.read_text()==text,f"主题过期：{name}"
 else:p.write_text(text)
print("Desktop themes verified" if args.check else "Desktop themes generated")
