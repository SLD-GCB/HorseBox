import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ssh/ssh_connection.dart';

/// 远端文件浏览与收发：列目录、进目录、下载到本地、从本地选文件上传。
class SshFilesPage extends StatefulWidget {
  const SshFilesPage({super.key, required this.conn, required this.title});

  final SshConnection conn;
  final String title;

  @override
  State<SshFilesPage> createState() => _SshFilesPageState();
}

class _SshFilesPageState extends State<SshFilesPage> {
  String _path = '.';
  List<SftpName> _entries = const [];
  bool _loading = true;
  String? _error;
  String? _busy;
  bool _dragging = false;

  /// 上传进度：整批文件的总字节数，画一条连续的进度条。
  SftpFileWriter? _writer;
  bool _uploadCancel = false;
  String _uploadName = '';
  int _uploadIndex = 0;
  int _uploadCount = 0;
  int _uploadDone = 0;
  int _uploadSent = 0;
  int _uploadTotal = 0;

  /// 上一次刷新进度的时间。每写一个 16KB 分片就 setState 会把 UI 线程压死，
  /// 手机上尤其明显，所以限制到大约每秒 6 次。
  DateTime _lastProgressPaint = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load([String? path]) async {
    final target = path ?? _path;
    setState(() {
      _loading = true;
      _error = null;
      _path = target;
    });
    try {
      final sftp = await widget.conn.sftp();
      final list = await sftp.listdir(target);
      final visible =
          list
              .where(
                (item) =>
                    item.filename != '.' &&
                    item.filename != '..' &&
                    // .hbpart 和它的 .meta 是没传完的临时文件，不显示；
                    // 重新上传同名文件会自动续传。
                    !item.filename.endsWith('.hbpart') &&
                    !item.filename.endsWith('.hbpart.meta'),
              )
              .toList()
            ..sort((a, b) {
              final aDir = a.attr.isDirectory;
              final bDir = b.attr.isDirectory;
              if (aDir != bDir) return aDir ? -1 : 1;
              return a.filename.toLowerCase().compareTo(
                b.filename.toLowerCase(),
              );
            });
      if (!mounted) return;
      setState(() {
        _entries = visible;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String _join(String dir, String name) {
    return dir.endsWith('/') ? dir + name : '$dir/$name';
  }

  String _parent(String dir) {
    if (dir.isEmpty || dir == '.' || dir == '/') return dir;
    final trimmed = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
    final index = trimmed.lastIndexOf('/');
    if (index < 0) return '.';
    if (index == 0) return '/';
    return trimmed.substring(0, index);
  }

  Future<Directory> _localDir() async {
    Directory? base;
    try {
      base = Platform.isAndroid
          ? await getExternalStorageDirectory()
          : await getDownloadsDirectory();
    } catch (_) {}
    base ??= await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'HorseBox'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _download(SftpName item) async {
    setState(() => _busy = '正在下载 ${item.filename}');
    try {
      final sftp = await widget.conn.sftp();
      final dir = await _localDir();
      final target = File(p.join(dir.path, item.filename));
      final sink = target.openWrite();
      await sftp.download(
        _join(_path, item.filename),
        sink,
        closeDestination: true,
      );
      _toast('已保存到 ${target.path}');
    } catch (e) {
      _toast('下载失败：$e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _upload() async {
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles();
    } catch (e) {
      _toast('打开文件选择器失败：$e');
      return;
    }
    if (picked.isEmpty) return;
    await _uploadPaths(
      picked.map((file) => file.path).whereType<String>().toList(),
    );
  }

  Future<void> _uploadFolder() async {
    String? dir;
    try {
      dir = await FilePicker.getDirectoryPath(dialogTitle: '选择要上传的文件夹');
    } catch (e) {
      _toast('打开目录选择器失败：$e');
      return;
    }
    if (dir == null || dir.isEmpty) return;
    await _uploadPaths([dir]);
  }

  /// 选文件、选目录、拖拽都走这里：目录先展开成文件列表，再逐个流式上传。
  Future<void> _uploadPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    setState(() => _busy = '正在扫描…');
    final items = <_UploadItem>[];
    // 空目录也要在远端建出来，否则传完少了几层空文件夹。
    final folders = <String>[];
    try {
      for (final path in paths) {
        final type = await FileSystemEntity.type(path);
        if (type == FileSystemEntityType.directory) {
          final base = Directory(path);
          final root = p.basename(base.path);
          folders.add(_join(_path, root));
          await for (final entity in base.list(
            recursive: true,
            followLinks: false,
          )) {
            final rel = p
                .relative(entity.path, from: base.path)
                .replaceAll('\\', '/');
            if (entity is Directory) {
              folders.add(_join(_join(_path, root), rel));
              continue;
            }
            if (entity is! File) continue;
            items.add(
              _UploadItem(
                localPath: entity.path,
                remotePath: _join(_join(_path, root), rel),
                size: await entity.length(),
                mtime: (await entity.stat()).modified.millisecondsSinceEpoch,
              ),
            );
          }
        } else if (type == FileSystemEntityType.file) {
          final file = File(path);
          items.add(
            _UploadItem(
              localPath: path,
              remotePath: _join(_path, p.basename(path)),
              size: await file.length(),
              mtime: (await file.stat()).modified.millisecondsSinceEpoch,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) setState(() => _busy = null);
      _toast('读取本地文件失败：$e');
      return;
    }
    if (items.isEmpty) {
      if (mounted) setState(() => _busy = null);
      _toast('没有可上传的文件');
      return;
    }
    await _runUpload(items, folders);
  }

  /// 逐个文件上传：流式写 + 断点续传。
  ///
  /// 上传中的内容先写在 `<名字>.hbpart`，全部写完后才改名成正式文件。
  /// 中途取消或断线时 `.hbpart` 保留，下次传同名文件会从它的长度接着写。
  Future<void> _runUpload(List<_UploadItem> items, List<String> folders) async {
    _uploadCancel = false;
    _uploadDone = 0;
    _uploadSent = 0;
    _uploadTotal = items.fold<int>(0, (sum, item) => sum + item.size);
    _uploadCount = items.length;
    _uploadIndex = 0;
    _uploadName = '';
    setState(() => _busy = '正在上传');

    var ok = 0;
    var resumed = 0;
    final failed = <String>[];
    final dirs = <String>{};
    try {
      final sftp = await widget.conn.sftp();
      for (final folder in folders) {
        await _ensureDir(sftp, '$folder/.', dirs);
      }
      for (var i = 0; i < items.length; i++) {
        if (_uploadCancel) break;
        final item = items[i];
        if (mounted) {
          setState(() {
            _uploadIndex = i + 1;
            _uploadName = p.basename(item.localPath);
          });
        }
        SftpFile? remoteFile;
        try {
          await _ensureDir(sftp, item.remotePath, dirs);
          final part = '${item.remotePath}.hbpart';
          final meta = '${item.remotePath}.hbpart.meta';
          final offset = await _resumeOffset(sftp, item, part, meta);
          if (item.size > 0 && offset >= item.size) {
            // 上次已经写完，只是没来得及改名。
            await _finishPart(sftp, part, item.remotePath, meta);
          } else {
            remoteFile = await sftp.open(
              part,
              mode: offset == 0
                  ? SftpFileOpenMode.create |
                        SftpFileOpenMode.write |
                        SftpFileOpenMode.truncate
                  : SftpFileOpenMode.create | SftpFileOpenMode.write,
            );
            // 先记下本地文件的大小和修改时间，下次续传前用它确认是同一个文件。
            await _writeRemoteText(
              sftp,
              meta,
              jsonEncode({'size': item.size, 'mtime': item.mtime}),
            );
            final writer = remoteFile.write(
              File(item.localPath).openRead(offset).map(Uint8List.fromList),
              offset: offset,
              onProgress: (sent) {
                final now = DateTime.now();
                if (now.difference(_lastProgressPaint).inMilliseconds < 160) {
                  return;
                }
                _lastProgressPaint = now;
                if (!mounted) return;
                setState(() => _uploadSent = _uploadDone + offset + sent);
              },
            );
            _writer = writer;
            await writer.done;
            _writer = null;
            await remoteFile.close();
            remoteFile = null;
            if (_uploadCancel) break;
            await _finishPart(sftp, part, item.remotePath, meta);
            if (offset > 0) resumed++;
          }
          _uploadDone += item.size;
          _uploadSent = _uploadDone;
          ok++;
        } catch (e) {
          failed.add(p.basename(item.localPath));
          _uploadDone += item.size;
          _uploadSent = _uploadDone;
          if (mounted) _toast('上传 ${item.remotePath} 失败：$e');
        } finally {
          try {
            await remoteFile?.close();
          } catch (_) {}
        }
      }
    } catch (e) {
      _toast('上传失败：$e');
    } finally {
      _writer = null;
      if (mounted) {
        setState(() {
          _busy = null;
          _uploadName = '';
          _uploadTotal = 0;
          _uploadSent = 0;
        });
      }
    }

    if (_uploadCancel) {
      _toast('已取消，已传完 $ok 个；未完成的会保留断点，重新上传同名文件可续传');
    } else if (failed.isNotEmpty) {
      _toast('已上传 $ok 个，失败 ${failed.length} 个：${failed.join('、')}');
    } else if (ok > 0) {
      _toast(resumed > 0 ? '已上传 $ok 个（$resumed 个续传）' : '已上传 $ok 个文件');
    }
    if (ok > 0 && mounted) await _load();
  }

  /// 逐级创建远端目录；已存在就跳过（服务器返回的错误直接忽略）。
  Future<void> _ensureDir(
    SftpClient sftp,
    String remoteFile,
    Set<String> created,
  ) async {
    final index = remoteFile.lastIndexOf('/');
    if (index <= 0) return;
    final dir = remoteFile.substring(0, index);
    if (created.contains(dir)) return;
    final absolute = dir.startsWith('/');
    var current = '';
    for (final part in dir.split('/')) {
      if (part.isEmpty) continue;
      current = current.isEmpty
          ? (absolute ? '/$part' : part)
          : '$current/$part';
      if (created.contains(current)) continue;
      try {
        await sftp.mkdir(current);
      } catch (_) {}
      created.add(current);
    }
  }

  /// 把 .hbpart 换成正式文件名。
  ///
  /// 先直接改名：目标不存在时（新文件）这是唯一需要的操作。改名失败再退回到
  /// 「删掉旧文件 + 改名」，避免每个新文件都先发一个注定失败的 remove。
  Future<void> _finishPart(
    SftpClient sftp,
    String part,
    String target,
    String meta,
  ) async {
    try {
      await sftp.rename(part, target);
    } catch (_) {
      try {
        await sftp.remove(target);
      } catch (_) {}
      await sftp.rename(part, target);
    }
    try {
      await sftp.remove(meta);
    } catch (_) {}
  }

  /// 上次传到一半的文件能续多少字节。
  ///
  /// 只有「同名、大小和修改时间都没变」才续传；换了一个同名文件就丢掉旧断点，
  /// 从头开始，避免把两个不同文件拼在一起。
  Future<int> _resumeOffset(
    SftpClient sftp,
    _UploadItem item,
    String part,
    String meta,
  ) async {
    if (item.size <= 0) return 0;
    var partSize = 0;
    try {
      final attrs = await sftp.stat(part);
      partSize = attrs.size ?? 0;
    } catch (_) {
      return 0;
    }
    if (partSize <= 0 || partSize > item.size) return 0;
    var matched = false;
    try {
      final file = await sftp.open(meta, mode: SftpFileOpenMode.read);
      final raw = await file.readBytes();
      await file.close();
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is Map) {
        final size = (decoded['size'] as num?)?.toInt() ?? -1;
        final mtime = (decoded['mtime'] as num?)?.toInt() ?? -1;
        matched = size == item.size && mtime == item.mtime;
      }
    } catch (_) {
      matched = false;
    }
    if (matched) return partSize;
    // 记录对不上，清掉旧断点重来。
    try {
      await sftp.remove(part);
    } catch (_) {}
    try {
      await sftp.remove(meta);
    } catch (_) {}
    return 0;
  }

  /// 写一个小文本文件（用于 .hbpart 的元信息）。
  Future<void> _writeRemoteText(
    SftpClient sftp,
    String path,
    String text,
  ) async {
    final file = await sftp.open(
      path,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.writeBytes(Uint8List.fromList(utf8.encode(text)));
    } finally {
      await file.close();
    }
  }

  /// 取消正在进行的上传：停掉当前文件的数据流，已传完的文件保留。
  void _cancelUpload() {
    if (_busy == null || _uploadTotal <= 0) return;
    _uploadCancel = true;
    final writer = _writer;
    if (writer != null) unawaited(writer.abort());
    setState(() {});
  }

  /// 进度文案：上传时显示第几个/共几个、文件名和百分比；其它操作直接显示状态。
  String _progressLabel() {
    final busy = _busy ?? '';
    if (_uploadTotal <= 0) return busy;
    final percent = (_uploadSent * 100 / _uploadTotal).clamp(0, 100).round();
    final name = _uploadName.isEmpty ? '' : ' · $_uploadName';
    return '正在上传 $_uploadIndex/$_uploadCount$name · $percent%';
  }

  String _sizeLabel(SftpName item) {
    if (item.attr.isDirectory) return '';
    final size = item.attr.size;
    if (size == null) return '';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    }
    if (size < 1024 * 1024 * 1024) {
      return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: const TextStyle(fontSize: 14)),
            Text(
              _path,
              style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: '上传',
            enabled: _busy == null,
            icon: const Icon(Icons.upload_file_outlined, size: 20),
            onSelected: (value) {
              if (value == 'files') unawaited(_upload());
              if (value == 'folder') unawaited(_uploadFolder());
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'files', child: Text('上传文件')),
              PopupMenuItem(value: 'folder', child: Text('上传文件夹')),
            ],
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _busy == null ? () => _load() : null,
            icon: const Icon(Icons.refresh, size: 20),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_busy != null)
            LinearProgressIndicator(
              value: _uploadTotal > 0
                  ? (_uploadSent / _uploadTotal).clamp(0.0, 1.0)
                  : null,
              minHeight: 2,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          if (_busy != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _progressLabel(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (_uploadTotal > 0)
                    TextButton(
                      onPressed: _cancelUpload,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('取消', style: TextStyle(fontSize: 11.5)),
                    ),
                ],
              ),
            ),
          Expanded(child: _dropArea(scheme)),
        ],
      ),
    );
  }

  /// 桌面端支持把文件拖进来直接传到当前目录；Android 没有系统拖放，直接用列表。
  Widget _dropArea(ColorScheme scheme) {
    final content = _body(scheme);
    if (Platform.isAndroid) return content;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        unawaited(
          _uploadPaths(details.files.map((file) => file.path).toList()),
        );
      },
      child: Stack(
        children: [
          Positioned.fill(child: content),
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: scheme.primary.withValues(alpha: 0.12),
                  alignment: Alignment.center,
                  child: Text(
                    '松开即可上传到当前目录',
                    style: TextStyle(fontSize: 13, color: scheme.primary),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: scheme.error,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: () => _load(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: _entries.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == 0) {
          return ListTile(
            dense: true,
            leading: const Icon(Icons.arrow_upward, size: 18),
            title: const Text('返回上级', style: TextStyle(fontSize: 12.5)),
            onTap: _path == '.' || _path == '/'
                ? null
                : () => _load(_parent(_path)),
          );
        }
        final item = _entries[index - 1];
        final isDir = item.attr.isDirectory;
        return ListTile(
          dense: true,
          leading: Icon(
            isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
            size: 18,
            color: isDir ? scheme.primary : scheme.onSurfaceVariant,
          ),
          title: Text(
            item.filename,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5),
          ),
          subtitle: _sizeLabel(item).isEmpty
              ? null
              : Text(
                  _sizeLabel(item),
                  style: TextStyle(
                    fontSize: 10.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
          trailing: isDir
              ? const Icon(Icons.chevron_right, size: 18)
              : IconButton(
                  tooltip: '下载',
                  onPressed: _busy == null ? () => _download(item) : null,
                  icon: const Icon(Icons.download_outlined, size: 18),
                ),
          onTap: isDir ? () => _load(_join(_path, item.filename)) : null,
        );
      },
    );
  }
}

/// 一个待上传的文件：本地路径、远端完整路径、大小。
class _UploadItem {
  const _UploadItem({
    required this.localPath,
    required this.remotePath,
    required this.size,
    required this.mtime,
  });

  final String localPath;
  final String remotePath;
  final int size;

  /// 本地文件的修改时间（毫秒），续传前用来确认还是同一个文件。
  final int mtime;
}
