using System.Security.Cryptography;
using System.Text;
using LimeIoT.Client;
namespace LimeLink.App;
public sealed class SecretStore:ISessionStore {
    private readonly string folder=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"LimeLink","secure");
    private readonly SemaphoreSlim gate=new(1,1);
    private string PathFor(string scope)=>Path.Combine(folder,Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(scope)))+".bin");
    public async Task<string?> LoadAsync(string scope,CancellationToken cancellation=default){await gate.WaitAsync(cancellation);try{var path=PathFor(scope);if(!File.Exists(path))return null;var data=await File.ReadAllBytesAsync(path,cancellation);return Encoding.UTF8.GetString(ProtectedData.Unprotect(data,Encoding.UTF8.GetBytes(scope),DataProtectionScope.CurrentUser));}finally{gate.Release();}}
    public async Task SaveAsync(string scope,string? value,CancellationToken cancellation=default){await gate.WaitAsync(cancellation);try{Directory.CreateDirectory(folder);var path=PathFor(scope);if(value is null){if(File.Exists(path))File.Delete(path);return;}var data=ProtectedData.Protect(Encoding.UTF8.GetBytes(value),Encoding.UTF8.GetBytes(scope),DataProtectionScope.CurrentUser);var temporary=path+"."+Guid.NewGuid()+".tmp";using(var file=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)){await file.WriteAsync(data,cancellation);file.Flush(true);}File.Move(temporary,path,true);}finally{gate.Release();}}
}
