import 'dart:io';

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
