package com.jz.musichelper.network

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSession
import java.security.cert.X509Certificate

// 统一 HTTP GET 客户端：移动 UA + Referer + 超时
// 所有网络调用强制在 IO 线程执行（Android 禁止主线程网络请求）
object ApiClient {

    const val MOBILE_UA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .followRedirects(true)
        // 酷狗 CDN 证书 hostname 不匹配（实测确认），仅对该域名放行 hostname 校验，其余域名保持严格校验。
        // 注意：不能用 HttpsURLConnection.getDefaultHostnameVerifier()——它只在 JDK 的 HttpsURLConnection
        // 上下文里可靠，拿 OkHttp 的 SSLSession 去问它在桌面 JVM 上一律返回 false（
        // 现象就是所有 https 直链报 "Hostname xxx not verified"）。这里自己按 SAN 做通配匹配。
        .hostnameVerifier { hostname, session ->
            hostname == "mobilecdn.kugou.com" || StrictHostnames.verify(hostname, session)
        }
        .build()

    /** GET 返回原始文本（suspend：在 IO 线程执行） */
    suspend fun get(url: String, headers: Map<String, String> = emptyMap(), timeoutSec: Long = 15): String {
        return withContext(Dispatchers.IO) {
            val builder = Request.Builder().url(url)
                .header("User-Agent", MOBILE_UA)
                .header("Accept", "application/json, text/javascript, */*; q=0.01")
                .header("Referer", "https://music.qq.com/")
            headers.forEach { (k, v) -> builder.header(k, v) }
            val req = builder.build()
            val okClient = if (timeoutSec != 15L) {
                client.newBuilder().readTimeout(timeoutSec, TimeUnit.SECONDS).build()
            } else client
            okClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) throw ApiError.HTTP(resp.code)
                resp.body?.string() ?: ""
            }
        }
    }

    /** POST 返回原始文本（suspend：在 IO 线程执行） */
    suspend fun post(url: String, body: String, headers: Map<String, String> = emptyMap(), timeoutSec: Long = 15): String {
        return withContext(Dispatchers.IO) {
            val builder = Request.Builder().url(url)
                .header("User-Agent", MOBILE_UA)
                .header("Accept", "application/json, text/javascript, */*; q=0.01")
                .post(body.toRequestBody("application/json; charset=utf-8".toMediaType()))
            headers.forEach { (k, v) -> builder.header(k, v) }
            val req = builder.build()
            val okClient = if (timeoutSec != 15L) {
                client.newBuilder().readTimeout(timeoutSec, TimeUnit.SECONDS).build()
            } else client
            okClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) throw ApiError.HTTP(resp.code)
                resp.body?.string() ?: ""
            }
        }
    }

    /** POST 表单体（v2.1.91：网易识曲接口吃 form-urlencoded） */
    suspend fun postForm(
        url: String,
        body: String,
        headers: Map<String, String> = emptyMap(),
        timeoutSec: Long = 15
    ): String {
        return withContext(Dispatchers.IO) {
            val builder = Request.Builder().url(url)
                .header("User-Agent", MOBILE_UA)
                .header("Accept", "application/json")
                .post(body.toRequestBody("application/x-www-form-urlencoded; charset=UTF-8".toMediaType()))
            headers.forEach { (k, v) -> builder.header(k, v) }
            val req = builder.build()
            val okClient = if (timeoutSec != 15L) {
                client.newBuilder().readTimeout(timeoutSec, TimeUnit.SECONDS).build()
            } else client
            okClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) throw ApiError.HTTP(resp.code)
                resp.body?.string() ?: ""
            }
        }
    }

    /** POST 二进制体（v2.1.80：听歌识曲上传 PCM；Content-Type 默认 octet-stream） */
    suspend fun postBytes(
        url: String,
        bytes: ByteArray,
        contentType: String = "application/octet-stream",
        headers: Map<String, String> = emptyMap(),
        timeoutSec: Long = 15
    ): String {
        return withContext(Dispatchers.IO) {
            val builder = Request.Builder().url(url)
                .header("User-Agent", MOBILE_UA)
                .header("Accept", "*/*")
                .post(bytes.toRequestBody(contentType.toMediaType()))
            headers.forEach { (k, v) -> builder.header(k, v) }
            val req = builder.build()
            val okClient = if (timeoutSec != 15L) {
                client.newBuilder().readTimeout(timeoutSec, TimeUnit.SECONDS).build()
            } else client
            okClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) throw ApiError.HTTP(resp.code)
                resp.body?.string() ?: ""
            }
        }
    }

    /** GET 解析为 JSONObject */
    suspend fun getJson(url: String, headers: Map<String, String> = emptyMap(), timeoutSec: Long = 15): JSONObject {
        return JSONObject(get(url, headers, timeoutSec))
    }

    /** GET 解析为 JSONArray */
    suspend fun getJsonArray(url: String, headers: Map<String, String> = emptyMap(), timeoutSec: Long = 15): JSONArray {
        return JSONArray(get(url, headers, timeoutSec))
    }
}

sealed class ApiError : Exception() {
    class HTTP(val code: Int) : ApiError()
    class Parse(val msg: String) : ApiError()
    object Timeout : ApiError()
}

/**
 * 严格的主机名校验（等价 OkHttp 默认行为，但不依赖 sun.* 实现）。
 * 按证书 SAN 通配匹配：`*.y.qq.com` 匹配 `c.y.qq.com`，但**不**匹配 `a.b.y.qq.com`。
 */
object StrictHostnames {

    fun verify(hostname: String, session: SSLSession): Boolean = try {
        val cert = session.peerCertificates.firstOrNull() as? X509Certificate ?: return false
        val sans = cert.subjectAlternativeNames
        var ok = false
        if (sans != null) {
            for (san in sans) {
                val type = san.getOrNull(0) as? Int ?: continue
                val value = san.getOrNull(1) as? String ?: continue
                // 2 = dNSName, 7 = iPAddress
                if ((type == 2 || type == 7) && (match(hostname, value) || (type == 7 && hostname == value))) {
                    ok = true
                    break
                }
            }
        }
        if (!ok) {
            // 老式证书没有 SAN：退回 CN
            val cn = cert.subjectX500Principal.name
                .split(',')
                .map { it.trim() }
                .firstOrNull { it.startsWith("CN=", ignoreCase = true) }
                ?.substring(3)
            if (cn != null) ok = match(hostname, cn)
        }
        ok
    } catch (_: Exception) {
        false
    }

    private fun match(host: String, pattern: String): Boolean {
        val h = host.trimEnd('.').lowercase()
        val p = pattern.trimEnd('.').lowercase()
        if (h == p) return true
        if (!p.startsWith("*.")) return false
        val suffix = p.substring(1)          // ".y.qq.com"
        if (!h.endsWith(suffix)) return false
        val prefix = h.removeSuffix(suffix)  // "c" / "a.b"
        return prefix.isNotEmpty() && !prefix.contains('.')
    }
}