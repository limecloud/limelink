package run.limeai.link

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import run.limeai.iot.core.SessionStore
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class SecureStore(context:Context):SessionStore {
    private val preferences=context.getSharedPreferences("limelink.secure",Context.MODE_PRIVATE)
    private val key:SecretKey
    private val mutex=Mutex()
    init {
        val store=KeyStore.getInstance("AndroidKeyStore");store.load(null)
        val alias="run.limeai.limelink.storage"
        key=if(store.containsAlias(alias)){store.getKey(alias,null) as SecretKey}else{
            val generator=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore")
            generator.init(KeyGenParameterSpec.Builder(alias,KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT).setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setRandomizedEncryptionRequired(true).build());generator.generateKey()
        }
    }
    override suspend fun load(origin:String):String? = mutex.withLock {
        val record=preferences.getString(origin,null)?:return@withLock null
        val bytes=Base64.decode(record,Base64.NO_WRAP)
        check(bytes.size>=29){"secure_record_corrupt"}
        val cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.DECRYPT_MODE,key,GCMParameterSpec(128,bytes.copyOfRange(0,12)));cipher.updateAAD(origin.toByteArray())
        cipher.doFinal(bytes.copyOfRange(12,bytes.size)).toString(Charsets.UTF_8)
    }
    override suspend fun save(origin:String,value:String?) = mutex.withLock {
        if(value==null){check(preferences.edit().remove(origin).commit()){ "secure_storage_failed" };return@withLock}
        val cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key);cipher.updateAAD(origin.toByteArray())
        val record=Base64.encodeToString(cipher.iv+cipher.doFinal(value.toByteArray()),Base64.NO_WRAP)
        check(preferences.edit().putString(origin,record).commit()){ "secure_storage_failed" }
    }
}
