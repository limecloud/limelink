using System.Security.Cryptography;
using System.Text;
using LimeLink.Core;

var identity=LinkIdentity.Create();var payload="{\"text\":\"你好\",\"ttl\":60}";var exchange=identity.Exchange("space-a","desktop-a","sha256:test","card",payload,DateTimeOffset.FromUnixTimeSeconds(100));
var publicKey=Convert.FromHexString(identity.PublicKey);using var verifier=ECDsa.Create(new ECParameters{Curve=ECCurve.NamedCurves.nistP256,Q=new ECPoint{X=publicKey[1..33],Y=publicKey[33..65]}});
var message=string.Join('\n',"limelink.exchange/v1","space-a","desktop-a","sha256:test",identity.Id,"card",exchange["nonce"]!.GetValue<string>(),"120",LinkIdentity.Hash(payload));
var signature=Convert.FromHexString(exchange["signature"]!.GetValue<string>());
if(!verifier.VerifyData(Encoding.UTF8.GetBytes(message),signature,HashAlgorithmName.SHA256,DSASignatureFormat.Rfc3279DerSequence))throw new Exception("signature mismatch");
if(verifier.VerifyData(Encoding.UTF8.GetBytes(message.Replace("desktop-a","desktop-b",StringComparison.Ordinal)),signature,HashAlgorithmName.SHA256,DSASignatureFormat.Rfc3279DerSequence))throw new Exception("target not bound");
try{identity.Exchange("s","d","r","card",new string('x',4097));throw new Exception("budget bypass");}catch(InvalidOperationException error)when(error.Message=="payload_too_large"){}
Console.WriteLine("{\"passed\":true,\"groups\":3,\"p256_der_signature\":true,\"target_binding\":true,\"payload_budget\":true,\"windows_ui\":false}");
