using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace LimeLink.Core;

public sealed record AgentToolCapabilities(bool Enabled);
public sealed record AgentToolCall(string Id,string Tool,JsonObject Arguments,long ExpiresAt) {
    [JsonIgnore] public bool IsWrite=>Tool=="limeiot_command";
    [JsonIgnore] public string Device=>Arguments["device_id"]!.GetValue<string>();
    [JsonIgnore] public string? Revision=>Arguments["model_revision"]?.GetValue<string>();
    [JsonIgnore] public string? Path=>Arguments["path"]?.GetValue<string>();
    [JsonIgnore] public JsonNode? Value=>Arguments["value"];
    public bool Matches(AgentToolCall other)=>Id==other.Id&&Tool==other.Tool&&ExpiresAt==other.ExpiresAt&&JsonNode.DeepEquals(Arguments,other.Arguments);
}
public sealed record AgentToolBatch(string Id,IReadOnlyList<AgentToolCall> Calls,long ExpiresAt);

/// <summary>设备工具的有限协议边界；模型参数不能改变网关、凭据或授权范围。</summary>
public static class AgentToolProtocol {
    private static readonly JsonSerializerOptions Wire=new(){Encoder=JavaScriptEncoder.UnsafeRelaxedJsonEscaping};
    private static void Check(bool value){if(!value)throw new InvalidOperationException("invalid_agent_tool_response");}
    private static bool Keys(JsonObject value,params string[] keys)=>value.Select(p=>p.Key).ToHashSet().SetEquals(keys);
    private static bool Match(string? value,string pattern)=>value is not null&&Regex.IsMatch(value,"\\A(?:"+pattern+")\\z",RegexOptions.CultureInvariant);
    public static int Bytes(JsonNode value)=>Encoding.UTF8.GetByteCount(value.ToJsonString(Wire));
    public static bool Identifier(string? value)=>Match(value,"[A-Za-z0-9_.:-]{1,128}");
    private static bool Revision(JsonNode? value)=>Match(Text(value),"sha256:[a-f0-9]{64}");
    private static bool Path(JsonNode? value)=>Match(Text(value),"[A-Za-z0-9_]{1,64}\\.[A-Za-z0-9_]{1,64}");
    private static string? Text(JsonNode? value)=>value is JsonValue v&&v.TryGetValue<string>(out var s)?s:null;
    private static bool Boolean(JsonNode? value)=>value is JsonValue v&&v.TryGetValue<bool>(out _);
    private static bool Number(JsonNode? value)=>value is JsonValue v&&v.GetValueKind()==JsonValueKind.Number&&v.TryGetValue<double>(out var n)&&double.IsFinite(n);
    public static bool Scalar(JsonNode? value)=>value is JsonValue&&Bytes(value)<=512&&(Text(value)is not null||Boolean(value)||Number(value));
    public static bool Timestamp(JsonNode? value)=>value is null||Text(value)is string s&&Regex.IsMatch(s,"T.*(?:Z|[+-][0-9]{2}:[0-9]{2})$")&&DateTimeOffset.TryParse(s,System.Globalization.CultureInfo.InvariantCulture,System.Globalization.DateTimeStyles.None,out _);
    private static bool Schema(JsonObject value){
        if(value.Any(p=>!new[]{"type","minimum","maximum","minLength","maxLength","enum"}.Contains(p.Key))||Text(value["type"]) is not ("boolean" or "integer" or "number" or "string"))return false;
        foreach(var key in new[]{"minimum","maximum"})if(value.ContainsKey(key)&&!Number(value[key]))return false;
        foreach(var key in new[]{"minLength","maxLength"})if(value.ContainsKey(key)&&(value[key] is not JsonValue v||!v.TryGetValue<long>(out var n)||n<0))return false;
        return !value.ContainsKey("enum")||value["enum"] is JsonArray a&&a.Count is >=1 and <=16&&a.All(Scalar);
    }
    public static bool ValidGrant(IReadOnlyList<string> devices)=>devices.Count<=4&&devices.Distinct().Count()==devices.Count&&devices.All(Identifier);
    public static AgentToolCapabilities Capabilities(JsonObject value){
        Check(Keys(value,"enabled","tools","approval_required","max_devices")&&Boolean(value["enabled"])&&JsonNode.DeepEquals(value["approval_required"],JsonValue.Create(true))&&JsonNode.DeepEquals(value["max_devices"],JsonValue.Create(4))&&JsonNode.DeepEquals(value["tools"],new JsonArray("limeiot_read","limeiot_command")));
        return new(value["enabled"]!.GetValue<bool>());
    }
    public static AgentToolCall Call(JsonObject value,IReadOnlyList<string> devices){
        Check(Keys(value,"id","tool","arguments","expires_at"));
        var call=new AgentToolCall(value["id"]!.GetValue<string>(),value["tool"]!.GetValue<string>(),(JsonObject)value["arguments"]!.AsObject().DeepClone(),value["expires_at"]!.GetValue<long>());Validate(call,devices);return call;
    }
    public static void Validate(AgentToolCall call,IReadOnlyList<string> devices){
        Check(Guid.TryParseExact(call.Id,"D",out _)&&call.ExpiresAt>=0&&Bytes(call.Arguments)<=1024&&devices.Contains(Text(call.Arguments["device_id"])));
        if(call.Tool=="limeiot_read"&&Keys(call.Arguments,"device_id"))return;
        Check(call.IsWrite&&Keys(call.Arguments,"device_id","model_revision","path","value")&&Revision(call.Arguments["model_revision"])&&Path(call.Arguments["path"])&&Scalar(call.Value));
    }
    public static AgentToolBatch Pending(JsonObject value,AgentReference reference){
        var required=new[]{"id","devices","calls","expires_at"};
        Check(required.All(value.ContainsKey)&&value.All(p=>required.Contains(p.Key)||p.Key=="content_expired")&&Text(value["id"])==reference.Id);
        var expires=value["expires_at"]!.GetValue<long>();var devices=value["devices"]!.AsArray();var calls=value["calls"]!.AsArray();Check(expires>=0&&calls.Count<=1);
        if(value.ContainsKey("content_expired")){Check(JsonNode.DeepEquals(value["content_expired"],JsonValue.Create(true))&&devices.Count==0&&calls.Count==0);return new(reference.Id,[],expires);}
        Check(devices.Select(Text).SequenceEqual(reference.Devices)||expires<=DateTimeOffset.UtcNow.ToUnixTimeSeconds()&&devices.Count==0&&calls.Count==0);
        var decoded=calls.Select(c=>Call(c!.AsObject(),reference.Devices)).ToArray();Check(decoded.All(c=>c.ExpiresAt<=expires));return new(reference.Id,decoded,expires);
    }
    public static void Completion(JsonObject value,string id,string call)=>Check(Keys(value,"id","call_id","recorded")&&Text(value["id"])==id&&Text(value["call_id"])==call&&JsonNode.DeepEquals(value["recorded"],JsonValue.Create(true)));
    public static void Result(AgentToolCall call,bool success,JsonObject output){
        Check(Bytes(output)<=1600);
        if(!success&&Keys(output,"error")&&Match(Text(output["error"]),"[a-z0-9_]{1,96}"))return;
        Check(Text(output["device_id"])==call.Device);
        if(!call.IsWrite){
            Check(success&&Keys(output,"device_id","model_revision","ready","properties")&&Revision(output["model_revision"])&&Boolean(output["ready"]));
            var properties=output["properties"]!.AsArray();Check(properties.Count<=8);var paths=new HashSet<string>();
            foreach(var raw in properties){var p=raw!.AsObject();
                Check(Keys(p,"path","schema","writable","value","observed_at","quality")&&Path(p["path"])&&paths.Add(p["path"]!.GetValue<string>())&&Schema(p["schema"]!.AsObject())&&Boolean(p["writable"])&&(p["value"]is null||Scalar(p["value"]))&&Timestamp(p["observed_at"])&&Text(p["quality"])is string quality&&Encoding.UTF8.GetByteCount(quality)<=32);
            }
        }else Check(Keys(output,"device_id","model_revision","path","value","command_id","status","observed_at")&&new[]{"model_revision","path","value"}.All(k=>JsonNode.DeepEquals(output[k],call.Arguments[k]))&&Identifier(Text(output["command_id"]))&&Text(output["status"])is "confirmed" or "failed" or "expired" or "rejected" or "unknown"&&success==(Text(output["status"])=="confirmed")&&Timestamp(output["observed_at"]));
    }
}
