package com.musichub.musichubapp

import android.media.audiofx.BassBoost
import android.media.audiofx.Equalizer
import android.media.audiofx.Virtualizer
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private val channelName = "music_hub/audio_effects"

    private var audioSessionId: Int = 0
    private var dolbyLikeEnabled: Boolean = false

    private var equalizer: Equalizer? = null
    private var bassBoost: BassBoost? = null
    private var virtualizer: Virtualizer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setAudioSessionId" -> {
                        val sessionId = (call.argument<Number>("id")?.toInt() ?: 0)
                        audioSessionId = sessionId
                        applyEffects()
                        result.success(null)
                    }

                    "setDolbyLikeEnabled" -> {
                        dolbyLikeEnabled = call.argument<Boolean>("enabled") ?: false
                        applyEffects()
                        result.success(null)
                    }

                    "disposeEffects" -> {
                        releaseEffects()
                        audioSessionId = 0
                        dolbyLikeEnabled = false
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun applyEffects() {
        releaseEffects()
        if (!dolbyLikeEnabled || audioSessionId <= 0) return

        try {
            equalizer = Equalizer(0, audioSessionId).apply {
                enabled = true
                applyDolbyLikeEqCurve(this)
            }
        } catch (_: Throwable) {
            equalizer = null
        }

        try {
            bassBoost = BassBoost(0, audioSessionId).apply {
                enabled = true
                if (strengthSupported) {
                    setStrength(700.toShort())
                }
            }
        } catch (_: Throwable) {
            bassBoost = null
        }

        try {
            virtualizer = Virtualizer(0, audioSessionId).apply {
                enabled = true
                if (strengthSupported) {
                    setStrength(650.toShort())
                }
            }
        } catch (_: Throwable) {
            virtualizer = null
        }
    }

    private fun applyDolbyLikeEqCurve(eq: Equalizer) {
        val bands = eq.numberOfBands.toInt()
        if (bands <= 0) return

        val minLevel = eq.bandLevelRange[0].toInt()
        val maxLevel = eq.bandLevelRange[1].toInt()

        for (band in 0 until bands) {
            val centerHz = eq.getCenterFreq(band.toShort()) / 1000
            val targetMilliDb = when {
                centerHz < 150 -> 450
                centerHz < 400 -> 320
                centerHz < 1000 -> 90
                centerHz < 4000 -> 220
                else -> 160
            }
            val clampedLevel = targetMilliDb.coerceIn(minLevel, maxLevel)
            eq.setBandLevel(band.toShort(), clampedLevel.toShort())
        }
    }

    private fun releaseEffects() {
        try {
            equalizer?.enabled = false
            equalizer?.release()
        } catch (_: Throwable) {
        } finally {
            equalizer = null
        }

        try {
            bassBoost?.enabled = false
            bassBoost?.release()
        } catch (_: Throwable) {
        } finally {
            bassBoost = null
        }

        try {
            virtualizer?.enabled = false
            virtualizer?.release()
        } catch (_: Throwable) {
        } finally {
            virtualizer = null
        }
    }
}
