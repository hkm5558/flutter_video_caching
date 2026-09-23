import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:native_dio_adapter/native_dio_adapter.dart';
import 'package:synchronized/synchronized.dart';

import '../cache/lru_cache_singleton.dart';
import '../ext/file_ext.dart';
import '../ext/gesture_ext.dart';
import '../ext/log_ext.dart';
import '../http/http_client_builder.dart';
import 'download_status.dart';
import 'download_task.dart';

/// The maximum number of isolates allowed in the pool.
const int MAX_POOL_SIZE = 1;

/// The maximum task priority value.
const int MAX_TASK_PRIORITY = 9999;

/// The minimum interval (in milliseconds) for updating download progress.
const int MIN_PROGRESS_UPDATE_INTERVAL = 500;

class DownloadPool {
  /// Lock for synchronizing access to the pool to ensure thread safety.
  final Lock _lock = Lock();

  /// The maximum number of isolates allowed in the pool.
  final int _poolSize;

  /// List of all download tasks managed by the pool.
  final List<DownloadTask> _taskList = [];

  /// HTTP client used for downloading files.
  late final Dio _client;

  /// Stream controller for broadcasting download task updates to listeners.
  late final StreamController<DownloadTask> _streamController;

  /// The last time progress was updated.

  /// Constructs a [DownloadPool] with the specified [poolSize].
  /// Throws an [ArgumentError] if the pool size is less than or equal to zero.
  ///
  /// [httpClientBuilder] lets the caller supply the client this pool downloads
  /// with — to attach an interceptor, for instance. It is only used when given:
  /// the default stays `NativeAdapter`, and swapping that for a plain [Dio]
  /// would quietly move prefetching off the platform stack.
  DownloadPool({
    int poolSize = MAX_POOL_SIZE,
    HttpClientBuilder? httpClientBuilder,
  }) : _poolSize = poolSize {
    if (_poolSize <= 0) {
      throw ArgumentError('Pool size must be greater than 0');
    }
    _client = httpClientBuilder?.create() ??
        (Dio()..httpClientAdapter = _createHttpClientAdapter());
    _streamController = StreamController.broadcast();
  }

  /// The client this pool downloads with.
  @visibleForTesting
  Dio get client => _client;

  /// How many times the pool has built its own adapter.
  ///
  /// Under `flutter test` the native library is absent, so both paths end up
  /// on the same fallback adapter and the client alone cannot tell them apart.
  /// This counts the path actually taken, which is the thing worth pinning:
  /// routing the default through a builder would move prefetching off the
  /// platform stack.
  @visibleForTesting
  static int debugOwnAdapterBuilds = 0;

  /// Returns the stream controller for task updates.
  StreamController<DownloadTask> get streamController => _streamController;

  /// Returns the list of all tasks in the pool.
  List<DownloadTask> get taskList => _taskList;

  /// Returns the list of tasks that are not currently downloading.
  List<DownloadTask> get prepareTasks => _taskList
      .where((task) => task.status != DownloadStatus.DOWNLOADING)
      .toList();

  /// Returns the list of tasks that are currently downloading.
  List<DownloadTask> get downloadingTasks => _taskList
      .where((task) => task.status == DownloadStatus.DOWNLOADING)
      .toList();

  HttpClientAdapter _createHttpClientAdapter() {
    debugOwnAdapterBuilds++;
    try {
      return NativeAdapter();
    } catch (error) {
      // Some simulator/runtime combinations cannot load native_dio_adapter's
      // Objective-C dynamic library. Falling back keeps VideoProxy usable; the
      // default Dio adapter still supports the Range requests used here.
      logW(
          '[DownloadPool] NativeAdapter unavailable, fallback to Dio default: $error');
      return HttpClientAdapter();
    }
  }

  /// Finds a task in the pool by its [taskId].
  DownloadTask? findTaskById(String taskId) =>
      _taskList.where((task) => task.id == taskId).firstOrNull;

  /// Finds a task in the pool by its [url].
  DownloadTask? findTaskByUrl(String url) =>
      _taskList.where((task) => task.url == url).firstOrNull;

  /// Adds a new [task] to the pool, creating a cache directory if needed.
  Future<DownloadTask> addTask(DownloadTask task) async {
    logV('[DownloadPool] addTask: ${task.toString()}');
    DownloadTask? existTask =
        _taskList.where((e) => e.matchUrl == task.matchUrl).firstOrNull;
    if (existTask != null) {
      _promoteTaskPriorityIfNeeded(existTask, task);
      return existTask;
    }
    if (task.cacheDir.isEmpty) {
      String cachePath = await FileExt.createCachePath();
      task.cacheDir = cachePath;
    }
    _taskList.add(task);
    return task;
  }

  /// Executes a [task], replacing any existing lower-priority task with the same cache key.
  /// Schedules the isolate pool for task execution.
  Future<DownloadTask> executeTask(DownloadTask task) async {
    DownloadTask? existTask =
        _taskList.where((e) => e.matchUrl == task.matchUrl).firstOrNull;
    if (existTask != null) {
      _promoteTaskPriorityIfNeeded(existTask, task);
    } else if (existTask == null) {
      await addTask(task);
    }
    FunctionProxy.debounce(roundTask);
    return task;
  }

  void _promoteTaskPriorityIfNeeded(
    DownloadTask existingTask,
    DownloadTask incomingTask,
  ) {
    if (existingTask.priority >= incomingTask.priority) return;

    // Keep the existing task object so listeners waiting on this cache key
    // continue to observe the same download, but promote it in the scheduler.
    existingTask.priority = incomingTask.priority;
    if (existingTask.status == DownloadStatus.PAUSED) {
      existingTask.status = DownloadStatus.IDLE;
    }
    FunctionProxy.debounce(roundTask);
  }

  void updateTaskById(String taskId, DownloadStatus status) {
    final task = findTaskById(taskId);
    if (task != null) {
      task.status = status;
      if (status == DownloadStatus.DOWNLOADING) {
        if (downloadingTasks.length > _poolSize) {
          DownloadTask lowest = downloadingTasks
              .where((e) => e.id != taskId)
              .reduce((a, b) => a.priority < b.priority ? a : b);
          lowest.status = DownloadStatus.PAUSED;
        }
        _download(task);
      } else if (status == DownloadStatus.COMPLETED ||
          status == DownloadStatus.FAILED ||
          status == DownloadStatus.CANCELLED) {
        _taskList.removeWhere((task) => task.id == taskId);
        _notifyTask(task);
      }
    }
  }

  void updateTaskByUrl(String url, DownloadStatus status) {
    final task = findTaskByUrl(url);
    if (task != null) {
      task.status = status;
      if (status == DownloadStatus.DOWNLOADING) {
        if (downloadingTasks.length > _poolSize) {
          DownloadTask lowest = downloadingTasks
              .where((e) => e.url != url)
              .reduce((a, b) => a.priority < b.priority ? a : b);
          lowest.status = DownloadStatus.PAUSED;
        }
        _download(task);
      } else if (status == DownloadStatus.COMPLETED ||
          status == DownloadStatus.FAILED ||
          status == DownloadStatus.CANCELLED) {
        _taskList.removeWhere((task) => task.url == url);
        _notifyTask(task);
      }
    }
  }

  /// Schedules the pool to run tasks, ensuring only one thread runs this logic at a time.
  Future<void> roundTask() async {
    await _lock.synchronized(() async {
      if (_taskList.isEmpty) return;
      _taskList.sort((a, b) => b.priority - a.priority);
      if (_taskList.length > _poolSize) {
        for (var task in _taskList.sublist(_poolSize)) {
          if (task.status == DownloadStatus.DOWNLOADING) {
            task.status = DownloadStatus.PAUSED;
            _notifyTask(task);
          }
        }
      }
      if (downloadingTasks.length < _poolSize) {
        for (int i = 0; i < _taskList.length; i++) {
          DownloadTask task = _taskList[i];
          if (task.status == DownloadStatus.DOWNLOADING) continue;
          if (downloadingTasks.length >= _poolSize) {
            task.status = DownloadStatus.PAUSED;
            _notifyTask(task);
            continue;
          }
          task.status = DownloadStatus.DOWNLOADING;
          _notifyTask(task);
          _download(task);
        }
      }
    });
  }

  Future<void> _download(DownloadTask task) async {
    DateTime startTime = DateTime.now();
    if (task.cancelToken == null) {
      task.cancelToken = CancelToken();
    }
    bool append = task.cachedBytes > 0;
    Map<String, Object> headers = _downloadHeader(task);
    // Write to a temp file and atomically rename it to the final name once the
    // download completes. An interruption (or a killed process) leaves only a
    // `.tmp` file, never a half-written segment under its final name (`.tmp` is
    // skipped during startup restore — see LruCacheSingleton._storageInit).
    final String tmpPath = '${task.savePath}.tmp';
    await _client.download(
      task.url,
      tmpPath,
      cancelToken: task.cancelToken,
      fileAccessMode: append ? FileAccessMode.append : FileAccessMode.write,
      deleteOnError: false,
      onReceiveProgress: (received, total) {
        _downloadProgress(task, received, total);
        if (task.status == DownloadStatus.PAUSED ||
            task.status == DownloadStatus.COMPLETED) {
          task.cachedBytes += task.downloadedBytes;
          task.downloadedBytes = task.cachedBytes;
          task.cancelToken?.cancel();
          task.cancelToken = null;
          _updateProgress(task);
        }
      },
      options: Options(headers: headers),
    ).then((response) async {
      await _downloadResponse(task, startTime);
    }).catchError((error) {
      _downloadError(task, error);
    });
  }

  Map<String, Object> _downloadHeader(DownloadTask task) {
    Map<String, Object> headers = {};
    // Set up HTTP Range header for resuming or partial downloads.
    String range = '';
    if (task.startRange > 0 || task.cachedBytes > 0) {
      range = 'bytes=${task.startRange + task.cachedBytes}-';
    }
    if (task.endRange != null) {
      if (range.isEmpty) range = 'bytes=0-';
      range += '${task.endRange}';
    }
    if (range.isNotEmpty) {
      headers.putIfAbsent('Range', () => range);
    }
    // Add custom headers except 'host' and 'range'.
    if (task.headers != null) {
      task.headers!.forEach((key, value) {
        String keyLower = key.toLowerCase();
        if (keyLower == 'host' || keyLower == 'range') return;
        headers.putIfAbsent(key, () => value);
      });
    }
    return headers;
  }

  void _downloadProgress(DownloadTask task, int received, int total) {
    // Calculate the total file size
    task.downloadedBytes = task.cachedBytes + received;
    task.totalBytes = total == -1 ? 0 : (task.cachedBytes + total);

    // Throttle per task, not pool-wide: with a single shared timestamp,
    // k concurrent downloads share one emission budget and each task
    // reports only every k * MIN_PROGRESS_UPDATE_INTERVAL ms — progress
    // bars stutter and rate estimates derived from the events read low.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (task.status == DownloadStatus.DOWNLOADING &&
        nowMs - task.lastProgressUpdateMs >= MIN_PROGRESS_UPDATE_INTERVAL) {
      _updateProgress(task);
      task.lastProgressUpdateMs = nowMs;
    }
  }

  Future<void> _downloadResponse(DownloadTask task, DateTime startTime) async {
    final File tmpFile = File('${task.savePath}.tmp');
    final File saveFile = File(task.savePath);
    // Atomic publish: rename the completed `.tmp` to the final name. On Windows,
    // renaming onto an existing path throws, so delete any stale file first. This
    // guarantees the final name always points to a complete segment.
    if (await saveFile.exists()) {
      await saveFile.delete();
    }
    await tmpFile.rename(task.savePath);
    task.progress = 1;
    task.data = saveFile.readAsBytesSync();
    updateTaskById(task.id, DownloadStatus.COMPLETED);
    try {
      // Cache registration is an optimization after the network download has
      // succeeded. Do not turn cache bookkeeping failures into download errors.
      await LruCacheSingleton().memoryPut(
        task.matchUrl,
        Uint8List.fromList(task.data),
      );
      await LruCacheSingleton().storagePut(task.matchUrl, saveFile);
    } catch (e) {
      logE('[DownloadPool] Cache registration failed: $e');
    }
    int duration = DateTime.now().difference(startTime).inSeconds;
    logV('[DownloadPool] Download done time: $duration s: ${task.toString()}');
    FunctionProxy.debounce(roundTask);
  }

  void _downloadError(DownloadTask task, dynamic error) {
    // Partial data lives in the `.tmp` file: keep it on cancel (= pause) so the
    // download can resume, delete it on a real failure, and never let it reach
    // the final name.
    File tmpFile = File('${task.savePath}.tmp');
    // Check if the download was cancelled.
    if (error is DioException && CancelToken.isCancel(error)) {
      logV('[DownloadPool] Download file size: '
          '${tmpFile.existsSync() ? tmpFile.lengthSync() : 0}');
      logV('[DownloadPool] Download ${task.status.name}: ${task.url}');
    } else {
      // Handle HTTP errors and retry logic.
      if (tmpFile.existsSync()) tmpFile.deleteSync();
      updateTaskById(task.id, DownloadStatus.FAILED);
      logV('[DownloadPool] Download error: $error');
      if (error is DioException && error.response?.statusCode == 416) {
        task.retryTimes = 0;
      }
      if (task.retryTimes > 0) {
        logV('[DownloadPool] Download retry ${task.retryTimes}: ${task.uri}');
        task.retryTimes--;
        _download(task);
      }
      FunctionProxy.debounce(roundTask);
    }
  }

  void _updateProgress(DownloadTask task) {
    if (task.totalBytes > 0) {
      task.progress = task.downloadedBytes / task.totalBytes;
    }
    _notifyTask(task);
    logV("[DownloadPool] DOWNLOADING ${task.toString()}");
  }

  void _notifyTask(DownloadTask task) {
    if (_streamController.isClosed) return;
    _streamController.sink.add(task);
  }

  void dispose() {
    // Force-cancel all in-flight download requests directly.
    // When the app returns from background, TCP connections are dead and
    // Dio's onReceiveProgress callback will never fire, so we must cancel
    // tokens explicitly to unblock any pending futures.
    for (final task in _taskList) {
      task.cancelToken?.cancel('DownloadPool disposed');
    }
    _taskList.clear();
    _streamController.close();
    _client.close();
    DownloadTask.resetId();
  }
}
