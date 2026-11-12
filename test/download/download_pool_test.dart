import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_video_caching/download/download_pool.dart';
import 'package:flutter_video_caching/flutter_video_caching.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationCachePath() async {
    return Directory.systemTemp.path;
  }
}

void main() {
  _poolClientTests();
  _resumeTests();
  TestWidgetsFlutterBinding.ensureInitialized();
  group('DownloadIsolatePool', () {
    late DownloadPool pool;

    setUp(() {
      PathProviderPlatform.instance = FakePathProviderPlatform();
      VideoProxy.urlMatcherImpl = UrlMatcherDefault();
      pool = DownloadPool(poolSize: 1);
      DownloadTask.resetId();
    });

    tearDown(() async {
      pool.dispose();
    });

    test('marking a segment reaches the task that is actually in the pool',
        () async {
      // A prefetch got there first; the serve loop's own object is discarded.
      final pooled = DownloadTask(uri: Uri.parse('https://a.com/wait.mp4'));
      await pool.addTask(pooled);

      final fromServeLoop = DownloadTask(uri: Uri.parse('https://a.com/wait.mp4'));
      pool.markTaskAwaited(fromServeLoop);

      expect(pooled.awaitedByPlayback, isTrue, reason: '池里那个没标上，发请求的人读不到');
      expect(fromServeLoop.awaitedByPlayback, isTrue, reason: '手上这个也要标，它可能才是进池的那个');
    });

    test('a read-ahead task does not wipe out a mark someone is waiting on',
        () async {
      final pooled = DownloadTask(uri: Uri.parse('https://a.com/keep.mp4'));
      await pool.addTask(pooled);
      pool.markTaskAwaited(pooled);

      // Both paths fold an incoming task into the pooled one: concurrent()
      // comes in through executeTask, push() — what precache uses — through
      // addTask. Neither carries a mark.
      await pool
          .executeTask(DownloadTask(uri: Uri.parse('https://a.com/keep.mp4')));
      expect(pooled.awaitedByPlayback, isTrue, reason: '预取接了同一段的活儿，把已有记号抹掉了');

      await pool.addTask(DownloadTask(uri: Uri.parse('https://a.com/keep.mp4')));
      expect(pooled.awaitedByPlayback, isTrue, reason: '走 addTask 那条路时被抹掉了');
    });

    test('a mark survives being folded into a higher-priority prefetch',
        () async {
      // precache(priority:) is public, so the pooled task can already outrank
      // the serve loop's — the priority guard returns early on that path.
      final pooled = DownloadTask(uri: Uri.parse('https://a.com/pri.mp4'), priority: 9);
      await pool.addTask(pooled);

      final waiting = DownloadTask(uri: Uri.parse('https://a.com/pri.mp4'), priority: 3)
        ..awaitedByPlayback = true;
      await pool.executeTask(waiting);

      expect(pooled.awaitedByPlayback, isTrue, reason: '抄记号被优先级早退挡住了');
      expect(pooled.priority, 9, reason: '优先级只升不降，这条不该被改');
    });

    test('addTask adds task to pool', () async {
      final task = DownloadTask(uri: Uri.parse('https://a.com/1.mp4'));
      await pool.addTask(task);
      expect(pool.taskList.length, 1);
      expect(pool.taskList.first.uri, task.uri);
    });

    test('findTaskById returns correct task', () async {
      final task = DownloadTask(uri: Uri.parse('https://a.com/2.mp4'));
      await pool.addTask(task);
      final found = pool.findTaskById(task.id);
      expect(found, isNotNull);
      expect(found!.uri, task.uri);
    });

    test('executeTask replaces lower priority', () async {
      final t1 =
          DownloadTask(uri: Uri.parse('https://a.com/3.mp4'), priority: 1);
      final t2 =
          DownloadTask(uri: Uri.parse('https://a.com/3.mp4'), priority: 5);
      await pool.executeTask(t1);
      await pool.executeTask(t2);
      expect(pool.taskList.length, 1);
      expect(pool.taskList.first.priority, 5);
    });

    test('addTask promotes existing task priority for the same cache key',
        () async {
      final t1 =
          DownloadTask(uri: Uri.parse('https://a.com/4.mp4'), priority: 1);
      final t2 =
          DownloadTask(uri: Uri.parse('https://a.com/4.mp4'), priority: 3);

      await pool.addTask(t1);
      final promoted = await pool.addTask(t2);

      expect(pool.taskList.length, 1);
      expect(identical(promoted, t1), isTrue);
      expect(pool.taskList.first.priority, 3);
    });

    test('notifyIsolate can pause and resume', () async {
      final task = DownloadTask(uri: Uri.parse('https://a.com/5.mp4'));
      await pool.executeTask(task);
      await Future.delayed(const Duration(milliseconds: 1000));
      final findTask = pool.findTaskById(task.id);
      expect(findTask, isNotNull);
      pool.updateTaskById(task.id, DownloadStatus.PAUSED);
      await Future.delayed(const Duration(milliseconds: 500));
      expect(findTask!.status, DownloadStatus.PAUSED);
      pool.updateTaskById(task.id, DownloadStatus.DOWNLOADING);
      await Future.delayed(const Duration(milliseconds: 500));
      expect(findTask.status, DownloadStatus.DOWNLOADING);
    });

    test('dispose clears all', () async {
      final task = DownloadTask(uri: Uri.parse('https://a.com/6.mp4'));
      await pool.executeTask(task);
      await Future.delayed(const Duration(milliseconds: 1000));
      pool.dispose();
      expect(pool.taskList, isEmpty);
    });
  });
}

/// Keeps the options of every request and never lets it finish, so a test can
/// read what rode along in `extra` while the request is still in flight —
/// which is when a serve loop marks a segment. Failing it instead would drop
/// the task from the pool and there would be nothing left to mark.
class _CapturingClientBuilder extends HttpClientBuilder {
  final List<RequestOptions> seen = <RequestOptions>[];

  @override
  Dio create() => Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => seen.add(options),
      ),
    );
}

/// A builder that hands out a client the caller can recognise later.
class _MarkedClientBuilder extends HttpClientBuilder {
  int createCalls = 0;

  @override
  Dio create() {
    createCalls++;
    return Dio(BaseOptions(headers: {'x-marked': 'yes'}));
  }
}

void _poolClientTests() {
  group('DownloadPool http client', () {
    setUp(() => DownloadPool.debugOwnAdapterBuilds = 0);

    test('the request carries the task itself, so a later mark is still readable',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      PathProviderPlatform.instance = FakePathProviderPlatform();
      VideoProxy.urlMatcherImpl = UrlMatcherDefault();

      final builder = _CapturingClientBuilder();
      final pool = DownloadPool(poolSize: 1, httpClientBuilder: builder);
      addTearDown(pool.dispose);

      final task = DownloadTask(uri: Uri.parse('https://a.com/inflight.mp4'));
      await pool.executeTask(task);
      // roundTask is debounced before anything goes out.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (builder.seen.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(builder.seen, isNotEmpty, reason: '请求没发出来，后面断言无从谈起');

      final carried = builder.seen.first.extra[DownloadTask.extraKey];
      expect(identical(carried, task), isTrue, reason: '带的不是任务本身，飞行途中的记号读不到');

      // What actually happens in production: a prefetch is already in flight
      // when the serve loop reaches this segment, and the loop marks it
      // through a task object of its own.
      pool.markTaskAwaited(DownloadTask(uri: Uri.parse('https://a.com/inflight.mp4')));
      expect(
        (carried as DownloadTask).awaitedByPlayback,
        isTrue,
        reason: '带的是拍下来的值，不是引用',
      );
    });

    test('builds its own adapter when no builder is given', () {
      // Prefetching runs on NativeAdapter. Routing the default through a
      // builder would move every prefetch off the platform stack, silently.
      //
      // The adapter itself is not asserted on: NativeAdapter needs a native
      // library that is absent under `flutter test`, so both paths land on the
      // same fallback and comparing them would say nothing. What is pinned is
      // that the pool went down its own path at all.
      final pool = DownloadPool(poolSize: 1);
      addTearDown(pool.dispose);

      expect(DownloadPool.debugOwnAdapterBuilds, 1);
    });

    test('uses the builder when one is given, and builds no adapter itself',
        () {
      final builder = _MarkedClientBuilder();
      final pool = DownloadPool(poolSize: 1, httpClientBuilder: builder);
      addTearDown(pool.dispose);

      expect(builder.createCalls, 1);
      expect(pool.client.options.headers['x-marked'], 'yes');
      expect(DownloadPool.debugOwnAdapterBuilds, 0);
    });
  });
}

/// 续传起点只认磁盘上 `.tmp` 的实际长度：内存计数一旦和文件对不上，
/// Range 要么越界拿到 416，要么从错位处接着写。
void _resumeTests() {
  group('DownloadTask.expectedLength', () {
    test('a segment is as long as its range', () {
      final task = DownloadTask(
          uri: Uri.parse('https://a.com/len.mp4'),
          startRange: 100,
          endRange: 199);
      expect(task.expectedLength, 100);
    });

    test('a whole file is unknown until a response tells its length', () {
      final task = DownloadTask(uri: Uri.parse('https://a.com/len.mp4'));
      expect(task.expectedLength, isNull, reason: '还没拿到总长，不能拿 0 去和 .tmp 比');
      task.totalBytes = 300;
      expect(task.expectedLength, 300);
    });

    test('a length that is not positive counts as unknown', () {
      final whole = DownloadTask(uri: Uri.parse('https://a.com/len.mp4'))
        ..totalBytes = -1;
      expect(whole.expectedLength, isNull);
      final inverted = DownloadTask(
          uri: Uri.parse('https://a.com/len.mp4'), startRange: 10, endRange: 5);
      expect(inverted.expectedLength, isNull);
    });
  });

  group('DownloadPool resume', () {
    final body = List<int>.generate(300, (i) => i % 256);
    late Directory dir;
    late _FakeServer server;
    late DownloadPool pool;

    setUp(() {
      PathProviderPlatform.instance = FakePathProviderPlatform();
      VideoProxy.urlMatcherImpl = UrlMatcherDefault();
      DownloadTask.resetId();
      // 不放进缓存根目录：缓存初始化会把那里的 .tmp 当孤儿删掉
      dir = Directory.systemTemp.createTempSync('vc_resume_');
      server = _FakeServer(body);
      pool = DownloadPool(
          poolSize: 1, httpClientBuilder: _FakeServerClientBuilder(server));
    });

    tearDown(() {
      pool.dispose();
      dir.deleteSync(recursive: true);
    });

    DownloadTask segment(String name) => DownloadTask(
          uri: Uri.parse('https://a.com/$name.mp4'),
          startRange: 100,
          endRange: 199,
          cacheDir: dir.path,
        );

    DownloadTask wholeFile(String name) => DownloadTask(
          uri: Uri.parse('https://a.com/$name.mp4'),
          cacheDir: dir.path,
        );

    Future<void> start(DownloadTask task) async {
      await pool.addTask(task);
      pool.updateTaskById(task.id, DownloadStatus.DOWNLOADING);
    }

    Future<_FakeRequest> nthRequest(int n) async {
      await _until(() => server.requests.length >= n, '第 $n 个请求');
      return server.requests[n - 1];
    }

    // 暂停要等下一块数据到达才生效：先送 first 字节并等它写完，再暂停、送 second 字节，
    // 等取消落地后再恢复。
    Future<void> pauseAndResume(
        DownloadTask task, _FakeRequest request, int first, int second) async {
      final written = task.downloadedBytes + first;
      request.send(first);
      await _until(() => task.downloadedBytes == written, '写到 $written 字节');
      pool.updateTaskById(task.id, DownloadStatus.PAUSED);
      request.send(second);
      await _until(() => task.cancelToken == null, '暂停生效');
      pool.updateTaskById(task.id, DownloadStatus.DOWNLOADING);
    }

    Future<List<int>> published(DownloadTask task) async {
      await _until(() => File(task.savePath).existsSync(), '落盘成正式文件');
      return File(task.savePath).readAsBytesSync();
    }

    test('resumes from the length on disk after pausing twice', () async {
      final task = segment('twice');
      await start(task);

      final first = await nthRequest(1);
      expect(first.range, 'bytes=100-199');
      await pauseAndResume(task, first, 30, 10);

      final second = await nthRequest(2);
      expect(second.range, 'bytes=140-199');
      await pauseAndResume(task, second, 20, 10);

      final third = await nthRequest(3);
      expect(third.range, 'bytes=170-199',
          reason: '第二次暂停起已缓存字节被重复累加，起点越过分段末尾就是 416');
      third.sendRest();
      expect(await published(task), body.sublist(100, 200));
    });

    test('a segment already whole in .tmp is published without a request',
        () async {
      final task = segment('full');
      File('${task.savePath}.tmp').writeAsBytesSync(body.sublist(100, 200));
      final notified = <DownloadStatus>[];
      pool.streamController.stream
          .where((t) => t.id == task.id)
          .listen((t) => notified.add(t.status));
      await start(task);

      await _until(() => task.status == DownloadStatus.COMPLETED, '直接按完成落盘');
      await _until(
          () async =>
              await LruCacheSingleton().storageGet(task.matchUrl) != null,
          '登记进磁盘缓存');
      expect(server.requests, isEmpty, reason: '数据已齐还请求，只会从文件末尾要数据（416）');
      expect(File(task.savePath).readAsBytesSync(), body.sublist(100, 200));
      expect(File('${task.savePath}.tmp').existsSync(), isFalse);
      expect(task.progress, 1);
      expect(task.data, body.sublist(100, 200));
      expect(pool.findTaskById(task.id), isNull, reason: '和正常完成一样移出任务池');
      expect(notified, contains(DownloadStatus.COMPLETED));
      expect(await LruCacheSingleton().memoryGet(task.matchUrl),
          body.sublist(100, 200));
    });

    test('an oversized segment .tmp is thrown away and fetched afresh',
        () async {
      // 内存计数已经和磁盘对不上
      final task = segment('oversized')..cachedBytes = 30;
      File('${task.savePath}.tmp').writeAsBytesSync(List<int>.filled(150, 7));
      await start(task);

      final request = await nthRequest(1);
      expect(request.range, 'bytes=100-199', reason: '比分段还长说明写坏了，要从头下');
      expect(request.cachedBytesAtStart, 0, reason: '从头下要用写模式，不能接着坏数据追加');
      expect(File(task.savePath).existsSync(), isFalse, reason: '坏数据不能发布');
      request.sendRest();
      expect(await published(task), body.sublist(100, 200));
    });

    test('a segment with no .tmp on disk goes to the network', () async {
      final task = segment('fresh');
      await start(task);

      final request = await nthRequest(1);
      expect(request.range, 'bytes=100-199');
      expect(request.cachedBytesAtStart, 0);
      expect(File(task.savePath).existsSync(), isFalse);
    });

    test('a whole file whose last chunk lands as it is paused still completes',
        () async {
      final task = wholeFile('last');
      await start(task);

      final request = await nthRequest(1);
      expect(request.range, isNull);
      request.send(260);
      await _until(() => task.downloadedBytes == 260, '写到 260 字节');
      pool.updateTaskById(task.id, DownloadStatus.PAUSED);
      request.sendRest();

      expect(await published(task), body);
      await _until(() => task.status == DownloadStatus.COMPLETED, '按完成收尾');
      expect(server.requests, hasLength(1),
          reason: '数据已齐还取消，续传只会从文件末尾要数据（416）');
    });

    test('a whole file keeps its full length across a resume', () async {
      final task = wholeFile('whole');
      await start(task);

      final first = await nthRequest(1);
      await pauseAndResume(task, first, 100, 20);
      expect(task.expectedLength, 300);

      final second = await nthRequest(2);
      expect(second.range, 'bytes=120-');
      second.send(10);
      await _until(() => task.downloadedBytes == 130, '写到 130 字节');
      expect(task.expectedLength, 300, reason: '续传响应只有剩下那段的长度，加上起点才是完整长度');
      second.sendRest();
      expect(await published(task), body);
    });

    test('a retry after a failure starts over in write mode', () async {
      final task = segment('retry')..retryTimes = 1;
      await start(task);

      await pauseAndResume(task, await nthRequest(1), 30, 10);
      final second = await nthRequest(2);
      second.send(20);
      await _until(() => task.downloadedBytes == 60, '写到 60 字节');
      second.fail();

      final retry = await nthRequest(3);
      expect(retry.range, 'bytes=100-199', reason: '失败时 .tmp 已删，重试要从分段开头下');
      expect(retry.cachedBytesAtStart, 0, reason: '文件已删还追加写，正式文件会缺前半截');
      retry.sendRest();
      expect(await published(task), body.sublist(100, 200));
    });
  });
}

Future<void> _until(FutureOr<bool> Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等不到：$what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _FakeServerClientBuilder extends HttpClientBuilder {
  _FakeServerClientBuilder(this.server);

  final _FakeServer server;

  @override
  Dio create() => Dio()..httpClientAdapter = server;
}

/// 假服务端：按 Range 从 [body] 切出响应，数据由测试一块一块地送，
/// 好在任意字节处暂停；起点越界时和真服务端一样回 416。
class _FakeServer implements HttpClientAdapter {
  _FakeServer(this.body);

  final List<int> body;
  final List<_FakeRequest> requests = [];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final task = options.extra[DownloadTask.extraKey] as DownloadTask;
    final range = options.headers['Range'] as String?;
    var start = 0;
    var end = body.length - 1;
    if (range != null) {
      final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
      start = int.parse(match[1]!);
      if (match[2]!.isNotEmpty) end = math.min(int.parse(match[2]!), end);
    }
    final isSatisfiable = start <= end;
    final request = _FakeRequest(
      range,
      task.cachedBytes,
      isSatisfiable ? body.sublist(start, end + 1) : const <int>[],
    );
    requests.add(request);
    if (!isSatisfiable) return ResponseBody.fromString('', 416);
    return ResponseBody(
      request.controller.stream,
      range == null ? 200 : 206,
      headers: {
        Headers.contentLengthHeader: ['${request.content.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeRequest {
  _FakeRequest(this.range, this.cachedBytesAtStart, this.content);

  final String? range;

  /// 发请求那一刻任务的 cachedBytes；大于 0 时下载池用追加模式写 `.tmp`。
  final int cachedBytesAtStart;
  final List<int> content;
  final StreamController<Uint8List> controller = StreamController<Uint8List>();
  int _sent = 0;

  /// 送完整段就收尾，让下载正常结束。
  void send(int count) {
    final end = math.min(_sent + count, content.length);
    controller.add(Uint8List.fromList(content.sublist(_sent, end)));
    _sent = end;
    if (_sent == content.length) controller.close();
  }

  void sendRest() => send(content.length - _sent);

  void fail() => controller.addError(const SocketException('连接断了'));
}
