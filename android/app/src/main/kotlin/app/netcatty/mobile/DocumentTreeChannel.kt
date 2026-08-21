package app.netcatty.mobile

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URLConnection
import java.util.concurrent.Executors

class DocumentTreeChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    companion object {
        private const val CHANNEL = "app.netcatty.mobile/storage"
        private const val REQUEST_MOUNT_TREE = 8042
        private const val PREFS = "netcatty_document_tree"
        private const val PREF_TREE_URI = "tree_uri"
        private val PROJECTION = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val preferences = activity.getSharedPreferences(PREFS, Activity.MODE_PRIVATE)
    private var pendingMount: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler(::handleCall)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_MOUNT_TREE) return false
        val result = pendingMount ?: return true
        pendingMount = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return true
        }
        val treeUri = data.data!!
        val permissionFlags = data.flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        try {
            activity.contentResolver.takePersistableUriPermission(treeUri, permissionFlags)
            val oldUri = preferences.getString(PREF_TREE_URI, null)
            if (oldUri != null && oldUri != treeUri.toString()) {
                runCatching {
                    activity.contentResolver.releasePersistableUriPermission(
                        Uri.parse(oldUri),
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                    )
                }
            }
            preferences.edit().putString(PREF_TREE_URI, treeUri.toString()).apply()
            runIo(result) { mountInfo(treeUri) }
        } catch (error: Exception) {
            result.error("mount_failed", error.message, null)
        }
        return true
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getMount" -> runIo(result) {
                val tree = mountedTreeUri()
                if (tree == null) mapOf("mounted" to false) else mountInfo(tree)
            }
            "mount" -> mount(result)
            "list" -> runIo(result) { list(requirePath(call, "path")) }
            "stat" -> runIo(result) {
                val tree = requireTree()
                val path = requirePath(call, "path")
                val document = if (path == "/") {
                    queryDocument(rootDocument(tree))
                } else {
                    val (parentPath, name) = splitParent(path)
                    val parent = resolve(tree, parentPath)
                    findChild(tree, parent.uri, name)
                }
                document?.let {
                    mapOf(
                        "isDirectory" to it.isDirectory,
                        "size" to it.size,
                    )
                }
            }
            "copyToCache" -> runIo(result) { copyToCache(requirePath(call, "path")) }
            "copyFromCache" -> runIo(result) {
                copyFromCache(
                    requirePath(call, "path"),
                    call.argument<String>("cachePath")
                        ?: throw IllegalArgumentException("缺少缓存文件路径"),
                    call.argument<Boolean>("append") == true,
                )
                null
            }
            "mkdir" -> runIo(result) {
                createDirectory(requirePath(call, "path"), false)
                null
            }
            "ensureDirectory" -> runIo(result) {
                createDirectory(requirePath(call, "path"), true)
                null
            }
            "rename" -> runIo(result) {
                rename(
                    requirePath(call, "from"),
                    requirePath(call, "to"),
                )
                null
            }
            "delete" -> runIo(result) {
                delete(requirePath(call, "path"))
                null
            }
            else -> result.notImplemented()
        }
    }

    private fun mount(result: MethodChannel.Result) {
        if (pendingMount != null) {
            result.error("mount_active", "目录选择器已经打开", null)
            return
        }
        pendingMount = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
            mountedTreeUri()?.let {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, it)
            }
        }
        activity.startActivityForResult(intent, REQUEST_MOUNT_TREE)
    }

    private fun runIo(result: MethodChannel.Result, action: () -> Any?) {
        executor.execute {
            try {
                val value = action()
                mainHandler.post { result.success(value) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error("storage_error", error.message ?: error.toString(), null)
                }
            }
        }
    }

    private fun mountedTreeUri(): Uri? {
        val value = preferences.getString(PREF_TREE_URI, null) ?: return null
        val uri = Uri.parse(value)
        val permission = activity.contentResolver.persistedUriPermissions.firstOrNull {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        }
        if (permission != null) return uri
        preferences.edit().remove(PREF_TREE_URI).apply()
        return null
    }

    private fun mountInfo(treeUri: Uri): Map<String, Any?> {
        val root = rootDocument(treeUri)
        return mapOf(
            "mounted" to true,
            "name" to queryDocument(root).name,
        )
    }

    private fun list(path: String): List<Map<String, Any?>> {
        val tree = requireTree()
        val parent = resolve(tree, path)
        if (!parent.isDirectory) throw IllegalArgumentException("目标不是目录")
        return queryChildren(tree, parent.uri).map { child ->
            mapOf(
                "name" to child.name,
                "path" to joinPath(path, child.name),
                "isDirectory" to child.isDirectory,
                "size" to child.size,
                "modified" to child.modified,
            )
        }.sortedWith(
            compareByDescending<Map<String, Any?>> { it["isDirectory"] == true }
                .thenBy(String.CASE_INSENSITIVE_ORDER) { it["name"].toString() },
        )
    }

    private fun copyToCache(path: String): String {
        val document = resolve(requireTree(), path)
        if (document.isDirectory) throw IllegalArgumentException("无法把目录作为文件读取")
        val target = File.createTempFile("netcatty-saf-", ".tmp", activity.cacheDir)
        activity.contentResolver.openInputStream(document.uri).use { input ->
            if (input == null) throw IllegalStateException("无法打开手机文件")
            target.outputStream().use { output -> input.copyTo(output) }
        }
        return target.absolutePath
    }

    private fun copyFromCache(path: String, cachePath: String, append: Boolean) {
        val cache = File(cachePath)
        if (!cache.isFile) throw IllegalArgumentException("上传缓存文件不存在")
        val (parentPath, name) = splitParent(path)
        val tree = requireTree()
        val parent = resolve(tree, parentPath)
        var target = findChild(tree, parent.uri, name)
        if (target?.isDirectory == true) throw IllegalArgumentException("同名目录已存在")
        if (target == null) {
            val mime = URLConnection.guessContentTypeFromName(name) ?: "application/octet-stream"
            val uri = DocumentsContract.createDocument(
                activity.contentResolver,
                parent.uri,
                mime,
                name,
            ) ?: throw IllegalStateException("无法创建手机文件")
            target = queryDocument(uri)
        }
        val mode = if (append) "wa" else "wt"
        activity.contentResolver.openOutputStream(target.uri, mode).use { output ->
            if (output == null) throw IllegalStateException("无法写入手机文件")
            cache.inputStream().use { it.copyTo(output) }
        }
    }

    private fun createDirectory(path: String, allowExisting: Boolean) {
        val (parentPath, name) = splitParent(path)
        val tree = requireTree()
        val parent = resolve(tree, parentPath)
        val existing = findChild(tree, parent.uri, name)
        if (existing != null) {
            if (allowExisting && existing.isDirectory) return
            throw IllegalArgumentException("同名文件或目录已存在")
        }
        DocumentsContract.createDocument(
            activity.contentResolver,
            parent.uri,
            DocumentsContract.Document.MIME_TYPE_DIR,
            name,
        ) ?: throw IllegalStateException("无法创建目录")
    }

    private fun rename(from: String, to: String) {
        val (fromParent, _) = splitParent(from)
        val (toParent, newName) = splitParent(to)
        if (fromParent != toParent) throw IllegalArgumentException("重命名不能跨目录移动")
        val document = resolve(requireTree(), from)
        DocumentsContract.renameDocument(activity.contentResolver, document.uri, newName)
            ?: throw IllegalStateException("无法重命名文件")
    }

    private fun delete(path: String) {
        if (path == "/") throw IllegalArgumentException("不能删除挂载目录")
        val document = resolve(requireTree(), path)
        if (!DocumentsContract.deleteDocument(activity.contentResolver, document.uri)) {
            throw IllegalStateException("无法删除文件")
        }
    }

    private fun requireTree(): Uri = mountedTreeUri()
        ?: throw IllegalStateException("请先选择并挂载手机目录")

    private fun resolve(tree: Uri, path: String): DocumentInfo {
        var current = queryDocument(rootDocument(tree))
        for (segment in pathSegments(path)) {
            current = findChild(tree, current.uri, segment)
                ?: throw IllegalArgumentException("手机目录中的路径不存在：$path")
        }
        return current
    }

    private fun findChild(tree: Uri, parent: Uri, name: String): DocumentInfo? =
        queryChildren(tree, parent).firstOrNull { it.name == name }

    private fun queryChildren(tree: Uri, parent: Uri): List<DocumentInfo> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            tree,
            DocumentsContract.getDocumentId(parent),
        )
        val result = mutableListOf<DocumentInfo>()
        activity.contentResolver.query(childrenUri, PROJECTION, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) result.add(documentFromCursor(tree, cursor))
        } ?: throw IllegalStateException("无法读取手机目录")
        return result
    }

    private fun queryDocument(uri: Uri): DocumentInfo {
        activity.contentResolver.query(uri, PROJECTION, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return documentFromCursor(uri, cursor)
        }
        throw IllegalArgumentException("无法读取手机文件信息")
    }

    private fun documentFromCursor(tree: Uri, cursor: android.database.Cursor): DocumentInfo {
        val id = cursor.getString(0)
        val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
        val name = cursor.getString(1) ?: "未命名"
        val mime = cursor.getString(2)
        val size = if (cursor.isNull(3)) 0L else cursor.getLong(3)
        val modified = if (cursor.isNull(4)) 0L else cursor.getLong(4)
        return DocumentInfo(
            uri = uri,
            name = name,
            isDirectory = mime == DocumentsContract.Document.MIME_TYPE_DIR,
            size = size,
            modified = modified,
        )
    }

    private fun rootDocument(tree: Uri): Uri = DocumentsContract.buildDocumentUriUsingTree(
        tree,
        DocumentsContract.getTreeDocumentId(tree),
    )

    private fun requirePath(call: MethodCall, name: String): String {
        val path = call.argument<String>(name)
            ?: throw IllegalArgumentException("缺少路径参数")
        pathSegments(path)
        return path
    }

    private fun pathSegments(path: String): List<String> {
        if (!path.startsWith('/')) throw IllegalArgumentException("目录路径无效")
        val parts = path.split('/').filter { it.isNotEmpty() }
        if (parts.any { it == "." || it == ".." }) {
            throw IllegalArgumentException("目录路径无效")
        }
        return parts
    }

    private fun splitParent(path: String): Pair<String, String> {
        val parts = pathSegments(path)
        if (parts.isEmpty()) throw IllegalArgumentException("不能修改挂载目录本身")
        val name = parts.last()
        val parent = if (parts.size == 1) "/" else "/" + parts.dropLast(1).joinToString("/")
        return parent to name
    }

    private fun joinPath(parent: String, name: String): String =
        if (parent == "/") "/$name" else "$parent/$name"

    private data class DocumentInfo(
        val uri: Uri,
        val name: String,
        val isDirectory: Boolean,
        val size: Long,
        val modified: Long,
    )
}
