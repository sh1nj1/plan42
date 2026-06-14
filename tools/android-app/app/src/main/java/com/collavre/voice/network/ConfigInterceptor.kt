package com.collavre.voice.network

import com.collavre.voice.data.SettingsRepository
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.Response

/**
 * The server URL and API token are runtime settings (the user can point at a
 * self-hosted Collavre or a tailscale preview, and paste a token), so we keep a
 * placeholder baseUrl on Retrofit and rewrite each request's scheme/host/port to
 * the configured server here, attaching the bearer token. This avoids rebuilding
 * Retrofit whenever a setting changes.
 */
class ConfigInterceptor(private val settings: SettingsRepository) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val cfg = runBlocking { settings.snapshot() }
        var request = chain.request()

        cfg.serverUrl.toHttpUrlOrNull()?.let { base ->
            val rewritten = request.url.newBuilder()
                .scheme(base.scheme)
                .host(base.host)
                .port(base.port)
                .build()
            val builder = request.newBuilder().url(rewritten)
            if (cfg.token.isNotBlank()) {
                builder.header("Authorization", "Bearer ${cfg.token}")
            }
            request = builder.build()
        }
        return chain.proceed(request)
    }
}
