use limelink_runtime::{Exchange,Store};
use ring::{rand::SystemRandom,signature::{EcdsaKeyPair,KeyPair,ECDSA_P256_SHA256_ASN1_SIGNING}};
use serde_json::{json,Value};
const SPACE:&str="space-demo";const DEVICE:&str="desktop-test";const REV:&str="sha256:1234567890";
fn key()->EcdsaKeyPair{let rng=SystemRandom::new();let pk=EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING,&rng).unwrap();EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING,pk.as_ref(),&rng).unwrap()}
fn input(key:&EcdsaKeyPair,client:&str,kind:&str,payload:Value,now:i64)->Exchange{
 let mut e=Exchange{client_id:client.into(),public_key:hex::encode(key.public_key().as_ref()),kind:kind.into(),nonce:uuid::Uuid::new_v4().to_string(),expires_at:now+20,payload:payload.to_string(),signature:String::new()};
 e.signature=hex::encode(key.sign(&SystemRandom::new(),&e.message(SPACE,DEVICE,REV)).unwrap().as_ref());e
}
fn store()->Store{Store::open(std::path::Path::new(":memory:"),"test").unwrap()}
fn response(value:Value)->Value{serde_json::from_str(value["evidence"]["output"]["response"].as_str().unwrap()).unwrap()}
fn execute(s:&mut Store,k:&EcdsaKeyPair,c:&str,kind:&str,payload:Value,now:i64)->Value{let e=input(k,c,kind,payload,now);response(s.execute(&uuid::Uuid::new_v4().to_string(),&e,SPACE,DEVICE,REV,now).unwrap())}
fn paired(s:&mut Store,k:&EcdsaKeyPair,c:&str){assert_eq!(execute(s,k,c,"pair",json!({"name":"测试手机"}),100)["ok"],true);s.approve(c,true,101).unwrap();}
#[test]fn explicit_approval_expiry_and_revocation(){
 let mut s=store();let k=key();let c=uuid::Uuid::new_v4().to_string();
 assert_eq!(execute(&mut s,&k,&c,"card",json!({"text":"hello","ttl":60}),100)["error"],"pairing_required");
 execute(&mut s,&k,&c,"pair",json!({"name":"手机"}),100);assert!(s.approve(&c,true,221).is_err());assert_eq!(execute(&mut s,&k,&c,"status",json!({}),222)["value"]["state"],"expired");
 let c=uuid::Uuid::new_v4().to_string();paired(&mut s,&k,&c);
 execute(&mut s,&k,&c,"card",json!({"text":"only text","ttl":60}),102);s.revoke(&c).unwrap();assert_eq!(s.view(103).unwrap()["cards"][0]["state"],"cancelled");
 assert_eq!(execute(&mut s,&k,&c,"card",json!({"text":"blocked","ttl":60}),104)["error"],"pairing_not_approved");
}
#[test]fn original_command_and_nonce_are_not_reexecuted(){
 let mut s=store();let k=key();let c=uuid::Uuid::new_v4().to_string();paired(&mut s,&k,&c);
 let e=input(&k,&c,"card",json!({"text":"once","ttl":60}),102);let a=s.execute("command-1",&e,SPACE,DEVICE,REV,102).unwrap();
 assert_eq!(s.execute("command-1",&e,SPACE,DEVICE,REV,200).unwrap(),a);
 assert_eq!(s.execute("command-2",&e,SPACE,DEVICE,REV,103).unwrap_err(),"nonce_replayed");
 assert_eq!(s.view(103).unwrap()["cards"].as_array().unwrap().len(),1);
 let other=input(&k,&c,"card",json!({"text":"different","ttl":60}),103);
 assert_eq!(s.execute("command-1",&other,SPACE,DEVICE,REV,103).unwrap_err(),"duplicate_conflict");
}
#[test]fn signature_freezes_target_content_and_identity(){
 let k=key();let c=uuid::Uuid::new_v4().to_string();let mut e=input(&k,&c,"pair",json!({"name":"手机"}),100);
 assert!(e.verify(SPACE,"wrong-device",REV,100).is_err());assert!(e.verify("wrong-space",DEVICE,REV,100).is_err());assert!(e.verify(SPACE,DEVICE,"changed-revision",100).is_err());
 e.payload="{\"name\":\"attacker\"}".into();assert!(e.verify(SPACE,DEVICE,REV,100).is_err());
}
#[test]fn presentation_is_separate_from_submission(){
 let mut s=store();let k=key();let c=uuid::Uuid::new_v4().to_string();paired(&mut s,&k,&c);
 let result=execute(&mut s,&k,&c,"card",json!({"text":"<script>plain data</script>","ttl":60}),102);
 let id=result["value"]["id"].as_str().unwrap();assert_eq!(s.view(103).unwrap()["cards"][0]["state"],"queued");
 s.presented(id,104).unwrap();assert_eq!(s.view(105).unwrap()["cards"][0]["state"],"presented");
 s.expire_content(200).unwrap();assert_eq!(s.view(200).unwrap()["cards"][0]["text"],"");
}
#[test]fn session_cas_lease_and_content_budget(){
 let mut s=store();let k=key();let c=uuid::Uuid::new_v4().to_string();paired(&mut s,&k,&c);
 assert_eq!(execute(&mut s,&k,&c,"session_create",json!({"id":"s1","text":"draft","ttl":100}),102)["ok"],true);
 assert_eq!(execute(&mut s,&k,&c,"session_claim",json!({"id":"s1","revision":1}),103)["value"]["revision"],2);
 assert_eq!(execute(&mut s,&k,&c,"session_write",json!({"id":"s1","revision":1,"text":"old"}),104)["error"],"revision_conflict");
 assert_eq!(execute(&mut s,&k,&c,"session_write",json!({"id":"s1","revision":2,"text":"next"}),104)["ok"],true);
 assert_eq!(execute(&mut s,&k,&c,"session_write",json!({"id":"s1","revision":3,"text":"late"}),134)["error"],"lease_expired");
 assert_eq!(execute(&mut s,&k,&c,"content_put",json!({"id":"content","text":"safe","sha256":"bad","ttl":10}),110)["error"],"invalid_content");
 assert_eq!(execute(&mut s,&k,&c,"content_put",json!({"id":"content","text":"safe","sha256":limelink_runtime::hash(b"safe"),"ttl":10}),111)["ok"],true);
 s.expire_content(122).unwrap();assert_eq!(s.view(122).unwrap()["contents"][0]["stale"],true);
}
#[test]fn phone_and_desktop_cannot_overwrite_each_other(){
 let mut s=store();let k=key();let c=uuid::Uuid::new_v4().to_string();paired(&mut s,&k,&c);
 execute(&mut s,&k,&c,"session_create",json!({"id":"shared","text":"first","ttl":200}),102);
 execute(&mut s,&k,&c,"session_claim",json!({"id":"shared","revision":1}),103);
 assert_eq!(s.local_session("shared",2,"session_claim",None,104).unwrap_err(),"writer_busy");
 s.local_session("shared",2,"session_claim",None,134).unwrap();
 assert_eq!(execute(&mut s,&k,&c,"session_write",json!({"id":"shared","revision":2,"text":"stale"}),135)["error"],"revision_conflict");
 assert_eq!(execute(&mut s,&k,&c,"session_write",json!({"id":"shared","revision":3,"text":"wrong writer"}),135)["error"],"lease_expired");
 s.local_session("shared",3,"session_write",Some("from desktop"),135).unwrap();
 assert_eq!(execute(&mut s,&k,&c,"session_release",json!({"id":"shared","revision":4}),136)["error"],"writer_busy");
 assert_eq!(s.view(136).unwrap()["sessions"][0]["text"],"from desktop");
 s.local_session("shared",4,"session_release",None,136).unwrap();
 assert_eq!(execute(&mut s,&k,&c,"session_claim",json!({"id":"shared","revision":5}),137)["value"]["text"],"from desktop");
}
#[test]fn diagnostics_never_exports_content_or_identity(){
 let directory=std::env::temp_dir().join(format!("limelink-check-{}",uuid::Uuid::new_v4()));std::fs::create_dir(&directory).unwrap();let path=directory.join("state.sqlite");
 let mut s=Store::open(&path,"private-identity").unwrap();let k=key();let c=uuid::Uuid::new_v4().to_string();paired(&mut s,&k,&c);
 execute(&mut s,&k,&c,"card",json!({"text":"private-body","ttl":60}),102);
 let report=limelink_runtime::diagnostics(&path).unwrap();let text=report.to_string();
 assert_eq!(report["counts"]["cards"],1);assert_eq!(report["schema_version"],1);
 for secret in ["private-body","private-identity",&c,&hex::encode(k.public_key().as_ref())]{assert!(!text.contains(secret));}
 assert_eq!(s.view(103).unwrap()["cards"][0]["text"],"private-body");
 drop(s);std::fs::remove_dir_all(directory).unwrap();
}
