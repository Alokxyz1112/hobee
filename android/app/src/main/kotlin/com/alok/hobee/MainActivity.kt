package com.alok.hobee

import android.content.ContentValues
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hobee/media").setMethodCallHandler { call, result ->
            Thread {
                try {
                    when (call.method) {
                        "sdk" -> runOnUiThread { result.success(Build.VERSION.SDK_INT) }
                        "mux" -> {
                            mux(call.argument<String>("video")!!, call.argument<String>("audio")!!, call.argument<String>("out")!!)
                            runOnUiThread { result.success(true) }
                        }
                        "save" -> {
                            val uri = save(call.argument<String>("path")!!, call.argument<String>("name")!!,
                                call.argument<String>("mime")!!, call.argument<Boolean>("video")!!)
                            runOnUiThread { result.success(uri) }
                        }
                        else -> runOnUiThread { result.notImplemented() }
                    }
                } catch (e: Exception) {
                    runOnUiThread { result.error("ERR", e.toString(), null) }
                }
            }.start()
        }
    }

    /** Merge a video-only mp4 and an audio-only mp4 (Reddit DASH tracks) into one mp4, no re-encode. */
    private fun mux(video: String, audio: String, out: String) {
        val muxer = MediaMuxer(out, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val ve = MediaExtractor().apply { setDataSource(video) }
        val ae = MediaExtractor().apply { setDataSource(audio) }
        fun pick(ex: MediaExtractor, prefix: String): Int {
            for (i in 0 until ex.trackCount) {
                val m = ex.getTrackFormat(i).getString(android.media.MediaFormat.KEY_MIME) ?: ""
                if (m.startsWith(prefix)) { ex.selectTrack(i); return muxer.addTrack(ex.getTrackFormat(i)) }
            }
            return -1
        }
        val vt = pick(ve, "video/"); val at = pick(ae, "audio/")
        muxer.start()
        val buf = ByteBuffer.allocate(4 * 1024 * 1024)
        val info = MediaCodec.BufferInfo()
        for ((ex, t) in listOf(ve to vt, ae to at)) {
            if (t < 0) continue
            while (true) {
                val size = ex.readSampleData(buf, 0)
                if (size < 0) break
                info.offset = 0; info.size = size; info.presentationTimeUs = ex.sampleTime
                info.flags = if (ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                muxer.writeSampleData(t, buf, info)
                ex.advance()
            }
        }
        muxer.stop(); muxer.release(); ve.release(); ae.release()
    }

    /** True if a file with this name already exists in Pictures/ or Movies/. */
    private fun taken(coll: android.net.Uri, dir: String, name: String): Boolean {
        contentResolver.query(coll, arrayOf(MediaStore.MediaColumns._ID),
            "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?",
            arrayOf(name, "$dir/"), null)?.use { return it.count > 0 }
        return false
    }

    /** Adds _1, _2, ... before the extension until the name is free. */
    private fun freeName(base: String, exists: (String) -> Boolean): String {
        if (!exists(base)) return base
        val dot = base.lastIndexOf('.')
        val stem = if (dot > 0) base.substring(0, dot) else base
        val ext = if (dot > 0) base.substring(dot) else ""
        var n = 1
        while (exists("${stem}_$n$ext")) n++
        return "${stem}_$n$ext"
    }

    /** Save into plain Pictures/ or Movies/ via MediaStore (API 29+) or legacy public dir. No title or description is set. */
    private fun save(path: String, base: String, mime: String, video: Boolean): String {
        val dir = if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_PICTURES
        if (Build.VERSION.SDK_INT >= 29) {
            val coll = if (video) MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
                       else MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val name = freeName(base) { taken(coll, dir, it) }
            val v = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "$dir/")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(coll, v) ?: throw Exception("MediaStore insert failed")
            contentResolver.openOutputStream(uri)!!.use { o -> FileInputStream(path).use { it.copyTo(o) } }
            v.clear(); v.put(MediaStore.MediaColumns.IS_PENDING, 0)
            contentResolver.update(uri, v, null, null)
            return uri.toString()
        } else {
            @Suppress("DEPRECATION")
            val d = Environment.getExternalStoragePublicDirectory(dir).apply { mkdirs() }
            val f = File(d, freeName(base) { File(d, it).exists() })
            File(path).copyTo(f, overwrite = true)
            MediaScannerConnection.scanFile(this, arrayOf(f.absolutePath), arrayOf(mime), null)
            return f.absolutePath
        }
    }
}
