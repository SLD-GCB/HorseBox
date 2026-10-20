import 'dart:async';
import 'dart:io';

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
              .where((item) => item.filename != '.' && item.filename != '..')
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

  /// 选文件上传和拖拽上传共用这一段。
  Future<void> _uploadPaths(List<String> paths) async {
    if (paths.isEmpty) return;
    setState(() => _busy = '正在上传');
    var ok = 0;
    try {
      final sftp = await widget.conn.sftp();
      for (final local in paths) {
        final name = p.basename(local);
        setState(() => _busy = '正在上传 $name');
        try {
          final bytes = await File(local).readAsBytes();
          final remote = _join(_path, name);
          final remoteFile = await sftp.open(
            remote,
            mode:
                SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.truncate,
          );
          await remoteFile.writeBytes(bytes);
          await remoteFile.close();
          ok++;
        } catch (e) {
          _toast('上传 $name 失败：$e');
        }
      }
    } catch (e) {
      _toast('上传失败：$e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (ok > 0) {
      _toast('已上传 $ok 个文件');
      await _load();
    }
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
          IconButton(
            tooltip: '上传文件',
            onPressed: _busy == null ? _upload : null,
            icon: const Icon(Icons.upload_file_outlined, size: 20),
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
              minHeight: 2,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          if (_busy != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _busy!,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
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
