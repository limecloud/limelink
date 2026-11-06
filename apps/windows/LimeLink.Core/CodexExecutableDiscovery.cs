using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace LimeLink.Core;

public sealed record DiscoveredCodex(string Path,string Version);

public static class CodexExecutableDiscovery {
    public static IEnumerable<string> Candidates(){
        var suffix=OperatingSystem.IsWindows()?"codex.exe":"codex";
        var prefixes=(Environment.GetEnvironmentVariable("PATH")??"").Split(Path.PathSeparator).Where(Path.IsPathFullyQualified).ToList();
        prefixes.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".bun","bin"));
        foreach(var prefix in prefixes)yield return Path.Combine(prefix,suffix);
        if(!OperatingSystem.IsWindows())yield break;
        prefixes.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),"npm"));
        prefixes.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),".bun","install","global"));
        foreach(var prefix in prefixes.Distinct(StringComparer.OrdinalIgnoreCase)){
            foreach(var (package,target) in new[]{("codex","x86_64-pc-windows-msvc"),("codex","aarch64-pc-windows-msvc"),("codex-win32-x64","x86_64-pc-windows-msvc"),("codex-win32-arm64","aarch64-pc-windows-msvc")})yield return Path.Combine(prefix,"node_modules","@openai",package,"vendor",target,"codex","codex.exe");
        }
    }
    public static async Task<DiscoveredCodex?> FindAsync(IEnumerable<string> candidates,CancellationToken cancellation=default,TimeSpan? probeTimeout=null){
        var seen=new HashSet<string>(OperatingSystem.IsWindows()?StringComparer.OrdinalIgnoreCase:StringComparer.Ordinal);var count=0;
        foreach(var candidate in candidates){
            cancellation.ThrowIfCancellationRequested();string path;
            try{path=LocalAgentConfiguration.CanonicalPath(candidate,false);}catch(Exception error)when(error is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException){continue;}
            if(OperatingSystem.IsWindows()&&!path.EndsWith(".exe",StringComparison.OrdinalIgnoreCase)||!seen.Add(path))continue;
            if(count++>=8)break;
            var output=await ProbeAsync(path,["--version"],cancellation,probeTimeout);var fields=output?.Split((char[]?)null,StringSplitOptions.RemoveEmptyEntries);
            if(fields is not{Length:2}||fields[0]!="codex-cli"||!Version.TryParse(fields[1],out var version)||version.Build<0||version.Revision>=0||version<new Version(0,166,0))continue;
            var help=await ProbeAsync(path,["app-server","--help"],cancellation,probeTimeout);
            if(help?.Contains("codex app-server",StringComparison.Ordinal)==true&&help.Contains("generate-json-schema",StringComparison.Ordinal))return new(path,fields[1]);
        }
        return null;
    }
    private static async Task<string?> ProbeAsync(string path,string[] arguments,CancellationToken cancellation,TimeSpan? probeTimeout){
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(cancellation);deadline.CancelAfter(TimeSpan.FromMilliseconds(Math.Clamp((probeTimeout??TimeSpan.FromSeconds(2)).TotalMilliseconds,50,5000)));
        var start=new ProcessStartInfo(path){UseShellExecute=false,RedirectStandardOutput=true,RedirectStandardError=true,RedirectStandardInput=true,CreateNoWindow=true};foreach(var argument in arguments)start.ArgumentList.Add(argument);
        using var process=new Process{StartInfo=start};var started=false;
        try{
            started=process.Start();if(!started)return null;process.StandardInput.Close();
            var output=ReadBounded(process.StandardOutput.BaseStream,deadline.Token);var error=ReadBounded(process.StandardError.BaseStream,deadline.Token);
            await Task.WhenAll(output,error,process.WaitForExitAsync(deadline.Token));
            return process.ExitCode==0?new UTF8Encoding(false,true).GetString(await output):null;
        }catch(Exception error)when(error is IOException or InvalidOperationException or Win32Exception or OperationCanceledException or DecoderFallbackException){
            if(started){try{if(!process.HasExited)process.Kill(true);await process.WaitForExitAsync(CancellationToken.None);}catch(InvalidOperationException){}catch(Win32Exception){}}
            cancellation.ThrowIfCancellationRequested();return null;
        }
    }
    private static async Task<byte[]> ReadBounded(Stream stream,CancellationToken cancellation){
        using var output=new MemoryStream();var buffer=new byte[4096];int count;
        while((count=await stream.ReadAsync(buffer,cancellation))>0){if(output.Length+count>16384)throw new IOException("codex_probe_output_budget");output.Write(buffer,0,count);}
        return output.ToArray();
    }
}
