import 'dart:io';

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
