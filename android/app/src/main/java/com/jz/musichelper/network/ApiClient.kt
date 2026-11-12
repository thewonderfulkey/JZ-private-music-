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

// 统一 HTTP GET 客户端：移动 UA + Referer + 超时
// 所有网络调用强制在 IO 线程执行（Android 禁止主线程网络请求）
object ApiClient {

    const val MOBILE_UA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .followRedirects(true)
        // 酷狗 CDN 证书 hostname 不匹配（实测确认），仅对该域名放行 hostname 校验，其余域名保持严格校验
        .hostnameVerifier { hostname, session ->
            hostname == "mobilecdn.kugou.com" ||
                HttpsURLConnection.getDefaultHostnameVerifier().verify(hostname, session)
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
