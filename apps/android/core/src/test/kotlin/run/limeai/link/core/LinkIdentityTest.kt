package run.limeai.link.core

import java.security.*
import java.security.spec.*
import java.math.BigInteger
import java.time.Instant
import kotlinx.serialization.json.*
import kotlin.test.*

class LinkIdentityTest {
    @Test fun signatureBindsTargetAndUtf8Payload() {
        val identity=LinkIdentity.create();val payload="""{"text":"你好","ttl":60}"""
        val e=identity.exchange("space-a","desktop-a","sha256:test","card",payload,Instant.ofEpochSecond(100))
        fun bytes(text:String)=text.chunked(2).map{it.toInt(16).toByte()}.toByteArray()
        val public=bytes(identity.publicKey)
        val parameters=AlgorithmParameters.getInstance("EC");parameters.init(ECGenParameterSpec("secp256r1"))
        val key=KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1,public.copyOfRange(1,33)),BigInteger(1,public.copyOfRange(33,65))),parameters.getParameterSpec(ECParameterSpec::class.java)))
        val message=listOf("limelink.exchange/v1","space-a","desktop-a","sha256:test",identity.id,"card",e["nonce"]!!.jsonPrimitive.content,"120",hash(payload)).joinToString("\n")
        fun verify(text:String):Boolean{val verifier=Signature.getInstance("SHA256withECDSA");verifier.initVerify(key);verifier.update(text.toByteArray());return verifier.verify(bytes(e["signature"]!!.jsonPrimitive.content))}
        assertTrue(verify(message));assertFalse(verify(message.replace("desktop-a","desktop-b")))
        assertFailsWith<IllegalArgumentException>{identity.exchange("s","d","r","card","x".repeat(4097))}
    }
}
