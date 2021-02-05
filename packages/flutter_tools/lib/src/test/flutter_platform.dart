// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.8

import 'dart:async';

import 'package:meta/meta.dart';
import 'package:package_config/package_config.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test_core/src/platform.dart'; // ignore: implementation_imports

import '../base/common.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../build_info.dart';
import '../compile.dart';
import '../convert.dart';
import '../dart/language_version.dart';
import '../device.dart';
import '../globals.dart' as globals;
import '../project.dart';
import '../test/test_wrapper.dart';
import 'test_compiler.dart';
import 'test_config.dart';
import 'test_device.dart';
import 'watcher.dart';

/// The address at which our WebSocket server resides and at which the sky_shell
/// processes will host the Observatory server.
final Map<InternetAddressType, InternetAddress> _kHosts = <InternetAddressType, InternetAddress>{
  InternetAddressType.IPv4: InternetAddress.loopbackIPv4,
  InternetAddressType.IPv6: InternetAddress.loopbackIPv6,
};

typedef PlatformPluginRegistration = void Function(FlutterPlatform platform);

/// Configure the `test` package to work with Flutter.
///
/// On systems where each [FlutterPlatform] is only used to run one test suite
/// (that is, one Dart file with a `*_test.dart` file name and a single `void
/// main()`), you can set an observatory port explicitly.
FlutterPlatform installHook({
  TestWrapper testWrapper = const TestWrapper(),
  @required String shellPath,
  TestWatcher watcher,
  bool enableObservatory = false,
  bool machine = false,
  int port = 0,
  String precompiledDillPath,
  Map<String, String> precompiledDillFiles,
  bool updateGoldens = false,
  bool buildTestAssets = false,
  int observatoryPort,
  InternetAddressType serverType = InternetAddressType.IPv4,
  Uri projectRootDirectory,
  FlutterProject flutterProject,
  String icudtlPath,
  PlatformPluginRegistration platformPluginRegistration,
  List<String> additionalArguments,
  Device integrationTestDevice,
  DebuggingOptions debuggingOptions,
}) {
  assert(testWrapper != null);
  assert(enableObservatory || (!debuggingOptions.startPaused && observatoryPort == null));

  // registerPlatformPlugin can be injected for testing since it's not very mock-friendly.
  platformPluginRegistration ??= (FlutterPlatform platform) {
    testWrapper.registerPlatformPlugin(
      <Runtime>[Runtime.vm],
      () {
        return platform;
      },
    );
  };
  final FlutterPlatform platform = FlutterPlatform(
    shellPath: shellPath,
    watcher: watcher,
    machine: machine,
    enableObservatory: enableObservatory,
    explicitObservatoryPort: observatoryPort,
    host: _kHosts[serverType],
    port: port,
    precompiledDillPath: precompiledDillPath,
    precompiledDillFiles: precompiledDillFiles,
    updateGoldens: updateGoldens,
    buildTestAssets: buildTestAssets,
    projectRootDirectory: projectRootDirectory,
    flutterProject: flutterProject,
    icudtlPath: icudtlPath,
    additionalArguments: additionalArguments,
    integrationTestDevice: integrationTestDevice,
    debuggingOptions: debuggingOptions,
  );
  platformPluginRegistration(platform);
  return platform;
}

/// Generates the bootstrap entry point script that will be used to launch an
/// individual test file.
///
/// The [testUrl] argument specifies the path to the test file that is being
/// launched.
///
/// The [host] argument specifies the address at which the test harness is
/// running.
///
/// If [testConfigFile] is specified, it must follow the conventions of test
/// configuration files as outlined in the [flutter_test] library. By default,
/// the test file will be launched directly.
///
/// The [updateGoldens] argument will set the [autoUpdateGoldens] global
/// variable in the [flutter_test] package before invoking the test.
// NOTE: this API is used by the fuchsia source tree, do not add new
// required or position parameters.
String generateTestBootstrap({
  @required Uri testUrl,
  @required InternetAddress host,
  @required bool isIntegrationTest,
  File testConfigFile,
  bool updateGoldens = false,
  String languageVersionHeader = '',
  bool nullSafety = false,
  bool flutterTestDep = true,
  int port,
}) {
  assert(testUrl != null);
  assert(host != null);
  assert(updateGoldens != null);

  final String websocketUrl = host.type == InternetAddressType.IPv4
      ? 'ws://${host.address}'
      : 'ws://[${host.address}]';
  final String encodedWebsocketUrl = Uri.encodeComponent(websocketUrl);

  final StringBuffer buffer = StringBuffer();
  buffer.write('''
$languageVersionHeader
import 'dart:async';
import 'dart:convert';  // ignore: dart_convert_import
import 'dart:io';  // ignore: dart_io_import
import 'dart:isolate';
''');
  if (flutterTestDep) {
    buffer.write('''
import 'package:flutter_test/flutter_test.dart';
''');
  }
  if (isIntegrationTest) {
    buffer.write('''
import 'package:integration_test/integration_test.dart';
''');
  }
  buffer.write('''
import 'package:test_api/src/remote_listener.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:stack_trace/stack_trace.dart';

import '$testUrl' as test;
''');
  if (testConfigFile != null) {
    buffer.write('''
import '${Uri.file(testConfigFile.path)}' as test_config;
''');
  }
  buffer.write('''

/// Returns a serialized test suite.
StreamChannel<dynamic> serializeSuite(Function getMain()) {
  return RemoteListener.start(getMain);
}

Future<void> _testMain() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  return test.main();
}

/// Capture any top-level errors (mostly lazy syntax errors, since other are
/// caught below) and report them to the parent isolate.
void catchIsolateErrors() {
  final ReceivePort errorPort = ReceivePort();
  // Treat errors non-fatal because otherwise they'll be double-printed.
  Isolate.current.setErrorsFatal(false);
  Isolate.current.addErrorListener(errorPort.sendPort);
  errorPort.listen((dynamic message) {
    // Masquerade as an IsolateSpawnException because that's what this would
    // be if the error had been detected statically.
    final IsolateSpawnException error = IsolateSpawnException(
        message[0] as String);
    final Trace stackTrace = message[1] == null ?
        Trace(const <Frame>[]) : Trace.parse(message[1] as String);
    Zone.current.handleUncaughtError(error, stackTrace);
  });
}


void main() {
''');
  if (isIntegrationTest) {
    buffer.write('''
  String serverPort = '$port';
''');
  } else {
    buffer.write('''
    String serverPort = Platform.environment['SERVER_PORT'] ?? '';
    ''');
  }
  buffer.write('''
  String server = Uri.decodeComponent('$encodedWebsocketUrl:\$serverPort');
  StreamChannel<dynamic> channel = serializeSuite(() {
    catchIsolateErrors();
''');
  if (flutterTestDep) {
    buffer.write('''
goldenFileComparator = LocalFileComparator(Uri.parse('$testUrl'));
autoUpdateGoldenFiles = $updateGoldens;
''');
  }
  if (testConfigFile != null) {
    buffer.write('''
    return () => test_config.testExecutable(_testMain);
''');
  } else {
    buffer.write('''
    return _testMain;
''');
  }
  buffer.write('''
  });
  WebSocket.connect(server).then((WebSocket socket) {
    socket.map((dynamic x) {
      return json.decode(x as String);
    }).pipe(channel.sink);
    socket.addStream(channel.stream.map(json.encode));
  });
}
''');
  return buffer.toString();
}

typedef Finalizer = Future<void> Function();

/// The flutter test platform used to integrate with package:test.
class FlutterPlatform extends PlatformPlugin {
  FlutterPlatform({
    @required this.shellPath,
    this.watcher,
    this.enableObservatory,
    this.machine,
    this.explicitObservatoryPort,
    this.host,
    this.port,
    this.precompiledDillPath,
    this.precompiledDillFiles,
    this.updateGoldens,
    this.buildTestAssets,
    this.projectRootDirectory,
    this.flutterProject,
    this.icudtlPath,
    this.additionalArguments,
    this.integrationTestDevice,
    this.debuggingOptions,
  }) : assert(shellPath != null);

  final String shellPath;
  final TestWatcher watcher;
  final bool enableObservatory;
  final bool machine;
  final int explicitObservatoryPort;
  final InternetAddress host;
  final int port;
  final String precompiledDillPath;
  final Map<String, String> precompiledDillFiles;
  final bool updateGoldens;
  final bool buildTestAssets;
  final Uri projectRootDirectory;
  final FlutterProject flutterProject;
  final String icudtlPath;
  final List<String> additionalArguments;
  final Device integrationTestDevice;
  final DebuggingOptions debuggingOptions;

  final FontConfigManager _fontConfigManager = FontConfigManager();

  /// The test compiler produces dill files for each test main.
  ///
  /// To speed up compilation, each compile is initialized from an existing
  /// dill file from previous runs, if possible.
  TestCompiler compiler;

  // Each time loadChannel() is called, we spin up a local WebSocket server,
  // then spin up the engine in a subprocess. We pass the engine a Dart file
  // that connects to our WebSocket server, then we proxy JSON messages from
  // the test harness to the engine and back again. If at any time the engine
  // crashes, we inject an error into that stream. When the process closes,
  // we clean everything up.

  int _testCount = 0;

  @override
  Future<RunnerSuite> load(
    String path,
    SuitePlatform platform,
    SuiteConfiguration suiteConfig,
    Object message,
  ) async {
    // loadChannel may throw an exception. That's fine; it will cause the
    // LoadSuite to emit an error, which will be presented to the user.
    // Except for the Declarer error, which is a specific test incompatibility
    // error we need to catch.
    final StreamChannel<dynamic> channel = loadChannel(path, platform);
    final RunnerSuiteController controller = deserializeSuite(path, platform,
      suiteConfig, const PluginEnvironment(), channel, message);
    return controller.suite;
  }

  @override
  StreamChannel<dynamic> loadChannel(String path, SuitePlatform platform) {
    if (_testCount > 0) {
      // Fail if there will be a port conflict.
      if (explicitObservatoryPort != null) {
        throwToolExit('installHook() was called with an observatory port or debugger mode enabled, but then more than one test suite was run.');
      }
      // Fail if we're passing in a precompiled entry-point.
      if (precompiledDillPath != null) {
        throwToolExit('installHook() was called with a precompiled test entry-point, but then more than one test suite was run.');
      }
    }

    final int ourTestCount = _testCount;
    _testCount += 1;
    final StreamController<dynamic> localController = StreamController<dynamic>();
    final StreamController<dynamic> remoteController = StreamController<dynamic>();
    final Completer<_AsyncError> testCompleteCompleter = Completer<_AsyncError>();
    final _FlutterPlatformStreamSinkWrapper<dynamic> remoteSink = _FlutterPlatformStreamSinkWrapper<dynamic>(
      remoteController.sink,
      testCompleteCompleter.future,
    );
    final StreamChannel<dynamic> localChannel = StreamChannel<dynamic>.withGuarantees(
      remoteController.stream,
      localController.sink,
    );
    final StreamChannel<dynamic> remoteChannel = StreamChannel<dynamic>.withGuarantees(
      localController.stream,
      remoteSink,
    );
    testCompleteCompleter.complete(_startTest(path, localChannel, ourTestCount));
    return remoteChannel;
  }

  Future<String> _compileExpressionService(
    String isolateId,
    String expression,
    List<String> definitions,
    List<String> typeDefinitions,
    String libraryUri,
    String klass,
    bool isStatic,
  ) async {
    if (compiler == null || compiler.compiler == null) {
      throw 'Compiler is not set up properly to compile $expression';
    }
    final CompilerOutput compilerOutput =
      await compiler.compiler.compileExpression(expression, definitions,
        typeDefinitions, libraryUri, klass, isStatic);
    if (compilerOutput != null && compilerOutput.outputFilename != null) {
      return base64.encode(globals.fs.file(compilerOutput.outputFilename).readAsBytesSync());
    }
    throw 'Failed to compile $expression';
  }

  /// Binds an [HttpServer] serving from `host` on `port`.
  ///
  /// Only intended to be overridden in tests for [FlutterPlatform].
  @protected
  @visibleForTesting
  Future<HttpServer> bind(InternetAddress host, int port) => HttpServer.bind(host, port);

  PackageConfig _packageConfig;

  TestDevice _createTestDevice() {
    if (integrationTestDevice != null) {
      return IntegrationTestTestDevice(
        device: integrationTestDevice,
        debuggingOptions: debuggingOptions,
      );
    }
    return FlutterTesterTestDevice(
      shellPath: shellPath,
      enableObservatory: enableObservatory,
      machine: machine,
      explicitObservatoryPort: explicitObservatoryPort,
      host: host,
      buildTestAssets: buildTestAssets,
      flutterProject: flutterProject,
      icudtlPath: icudtlPath,
      additionalArguments: additionalArguments,
      compileExpression: _compileExpressionService,
      fontConfigManager: _fontConfigManager,
      debuggingOptions: debuggingOptions,
    );
  }

  Future<_AsyncError> _startTest(
    String testPath,
    StreamChannel<dynamic> controller,
    int ourTestCount,
  ) async {
    _packageConfig ??= debuggingOptions.buildInfo.packageConfig;
    globals.printTrace('test $ourTestCount: starting test $testPath');

    _AsyncError outOfBandError; // error that we couldn't send to the harness that we need to send via our future

    final List<Finalizer> finalizers = <Finalizer>[]; // Will be run in reverse order.
    bool controllerSinkClosed = false;
    try {
      // Callback can't throw since it's just setting a variable.
      unawaited(controller.sink.done.whenComplete(() {
        controllerSinkClosed = true;
      }));

      // Prepare our WebSocket server to talk to the engine subprocess.
      final HttpServer server = await bind(host, port);
      finalizers.add(() async {
        globals.printTrace('test $ourTestCount: shutting down test harness socket server');
        await server.close(force: true);
      });
      final Completer<WebSocket> webSocket = Completer<WebSocket>();
      server.listen(
        (HttpRequest request) {
          if (!webSocket.isCompleted) {
            webSocket.complete(WebSocketTransformer.upgrade(request));
          }
        },
        onError: (dynamic error, StackTrace stack) {
          // If you reach here, it's unlikely we're going to be able to really handle this well.
          globals.printTrace('test $ourTestCount: test harness socket server experienced an unexpected error: $error');
          if (!controllerSinkClosed) {
            controller.sink.addError(error, stack);
            controller.sink.close();
          } else {
            globals.printError('unexpected error from test harness socket server: $error');
          }
        },
        cancelOnError: true,
      );

      globals.printTrace('test $ourTestCount: starting shell process');

      String entrypointPath = testPath;
      String compiledEntrypointPath;
      if (precompiledDillPath != null) {
        compiledEntrypointPath = precompiledDillPath;
      } else if (precompiledDillFiles != null) {
        compiledEntrypointPath = precompiledDillFiles[testPath];
      } else {
        entrypointPath = _createListenerDart(finalizers, ourTestCount, testPath, server);
      }

      final TestDevice testDevice = _createTestDevice();
      await testDevice.start(
        entrypointPath: entrypointPath,
        compiledEntrypointPath: compiledEntrypointPath,
        serverPort: server.port,
      );
      finalizers.add(() async {
        globals.printTrace('test $ourTestCount: ensuring test device is terminated.');
        await testDevice.kill();
      });

      // At this point, three things can happen next:
      // The engine could crash, in which case process.exitCode will complete.
      // The engine could connect to us, in which case webSocket.future will complete.
      // The local test harness could get bored of us.
      globals.printTrace('test $ourTestCount: awaiting connection to test device');
      await Future.any<void>(<Future<void>>[
        testDevice.finished,
        testDevice.observatoryUri.then<void>((Uri processObservatoryUri) {
          if (processObservatoryUri != null) {
            globals.printTrace('test $ourTestCount: Observatory uri is available at $processObservatoryUri');
          }
          watcher?.handleStartedDevice(processObservatoryUri);

          return webSocket.future.then<void>((WebSocket remoteSocket) async {
            globals.printTrace('test $ourTestCount: connected to test harness, now awaiting test result');
            await _controlTests(
              controller: controller,
              remoteSocket: remoteSocket,
              onError: (dynamic error, StackTrace stackTrace) {
                // If you reach here, it's unlikely we're going to be able to really handle this well.
                globals.printError('test: $testPath\nerror: $error');
                if (!controllerSinkClosed) {
                  controller.sink.addError(error, stackTrace);
                  controller.sink.close();
                } else {
                  globals.printError('unexpected error: $error');
                }
              }
            );

            await watcher?.handleFinishedTest(testDevice);
          });
        })
      ]);
    } on Exception catch (error, stack) {
      Object reportedError = error;
      if (error is TestDeviceException) {
        reportedError = error.message;
      }

      globals.printTrace('test $ourTestCount: error caught testing $testPath; ${controllerSinkClosed ? "reporting to console" : "sending to test framework"}');
      if (!controllerSinkClosed) {
        controller.sink.addError(reportedError, stack);
      } else {
        globals.printError('unhandled error during test:\n$testPath\n$reportedError\n$stack');
        outOfBandError ??= _AsyncError(reportedError, stack);
      }
    } finally {
      globals.printTrace('test $ourTestCount: cleaning up...');
      // Finalizers are treated like a stack; run them in reverse order.
      for (final Finalizer finalizer in finalizers.reversed) {
        try {
          await finalizer();
        } on Exception catch (error, stack) {
          globals.printTrace('test $ourTestCount: error while cleaning up; ${controllerSinkClosed ? "reporting to console" : "sending to test framework"}');
          if (!controllerSinkClosed) {
            controller.sink.addError(error, stack);
          } else {
            globals.printError('unhandled error during finalization of test:\n$testPath\n$error\n$stack');
            outOfBandError ??= _AsyncError(error, stack);
          }
        }
      }
      if (!controllerSinkClosed) {
        // Waiting below with await.
        unawaited(controller.sink.close());
        globals.printTrace('test $ourTestCount: waiting for controller sink to close');
        await controller.sink.done;
      }
    }
    assert(controllerSinkClosed);
    if (outOfBandError != null) {
      globals.printTrace('test $ourTestCount: finished with out-of-band failure');
    } else {
      globals.printTrace('test $ourTestCount: finished');
    }
    return outOfBandError;
  }

  String _createListenerDart(
    List<Finalizer> finalizers,
    int ourTestCount,
    String testPath,
    HttpServer server,
  ) {
    // Prepare a temporary directory to store the Dart file that will talk to us.
    final Directory tempDir = globals.fs.systemTempDirectory.createTempSync('flutter_test_listener.');
    finalizers.add(() async {
      globals.printTrace('test $ourTestCount: deleting temporary directory');
      tempDir.deleteSync(recursive: true);
    });

    // Prepare the Dart file that will talk to us and start the test.
    final File listenerFile = globals.fs.file('${tempDir.path}/listener.dart');
    listenerFile.createSync();
    listenerFile.writeAsStringSync(_generateTestMain(
      testUrl: globals.fs.path.toUri(globals.fs.path.absolute(testPath)),
      serverPort: server.port,
    ));
    return listenerFile.path;
  }

  String _generateTestMain({
    Uri testUrl,
    int serverPort,
  }) {
    assert(testUrl.scheme == 'file');
    final File file = globals.fs.file(testUrl);
    final LanguageVersion languageVersion = determineLanguageVersion(
      file,
      _packageConfig[flutterProject?.manifest?.appName],
    );
    return generateTestBootstrap(
      testUrl: testUrl,
      testConfigFile: findTestConfigFile(globals.fs.file(testUrl)),
      host: host,
      port: serverPort,
      updateGoldens: updateGoldens,
      flutterTestDep: _packageConfig['flutter_test'] != null,
      languageVersionHeader: '// @dart=${languageVersion.major}.${languageVersion.minor}',
      isIntegrationTest: integrationTestDevice != null,
    );
  }

  @override
  Future<dynamic> close() async {
    if (compiler != null) {
      await compiler.dispose();
      compiler = null;
    }
    await _fontConfigManager.dispose();
  }
}

// The [_shellProcessClosed] future can't have errors thrown on it because it
// crosses zones (it's fed in a zone created by the test package, but listened
// to by a parent zone, the same zone that calls [close] below).
//
// This is because Dart won't let errors that were fed into a Future in one zone
// propagate to listeners in another zone. (Specifically, the zone in which the
// future was completed with the error, and the zone in which the listener was
// registered, are what matters.)
//
// Because of this, the [_shellProcessClosed] future takes an [_AsyncError]
// object as a result. If it's null, it's as if it had completed correctly; if
// it's non-null, it contains the error and stack trace of the actual error, as
// if it had completed with that error.
class _FlutterPlatformStreamSinkWrapper<S> implements StreamSink<S> {
  _FlutterPlatformStreamSinkWrapper(this._parent, this._shellProcessClosed);

  final StreamSink<S> _parent;
  final Future<_AsyncError> _shellProcessClosed;

  @override
  Future<void> get done => _done.future;
  final Completer<void> _done = Completer<void>();

  @override
  Future<dynamic> close() {
    Future.wait<dynamic>(<Future<dynamic>>[
      _parent.close(),
      _shellProcessClosed,
    ]).then<void>(
      (List<dynamic> futureResults) {
        assert(futureResults.length == 2);
        assert(futureResults.first == null);
        final dynamic lastResult = futureResults.last;
        if (lastResult is _AsyncError) {
          _done.completeError(lastResult.error, lastResult.stack);
        } else {
          assert(lastResult == null);
          _done.complete();
        }
      },
      onError: _done.completeError,
    );
    return done;
  }

  @override
  void add(S event) => _parent.add(event);
  @override
  void addError(dynamic errorEvent, [ StackTrace stackTrace ]) => _parent.addError(errorEvent, stackTrace);
  @override
  Future<dynamic> addStream(Stream<S> stream) => _parent.addStream(stream);
}

@immutable
class _AsyncError {
  const _AsyncError(this.error, this.stack);
  final dynamic error;
  final StackTrace stack;
}

/// Bridges the package:test controller and the remote tester.
///
/// Sets up a that allows the package:test test [controller] to communicate with
/// a [remoteSocket] that runs the test. The returned future completes when
/// either side is closed, which also indicates when the tests have finished.
Future<void> _controlTests({
  @required
  StreamChannel<dynamic> controller,
  @required
  WebSocket remoteSocket,
  @required
  void Function(dynamic, StackTrace) onError,
}) async {
  final Completer<void> harnessDone = Completer<void>();
  final StreamSubscription<dynamic> harnessToTest =
      controller.stream.listen(
    (dynamic event) {
      remoteSocket.add(json.encode(event));
    },
    onDone: harnessDone.complete,
    onError: (dynamic error, StackTrace stack) {
      globals.printError('test harness controller stream experienced an unexpected error');
      onError(error, stack);
    },
    cancelOnError: true,
  );

  final Completer<void> testDone = Completer<void>();
  final StreamSubscription<dynamic> testToHarness = remoteSocket.listen(
    (dynamic encodedEvent) {
      assert(encodedEvent is String); // we shouldn't ever get binary messages
      controller.sink.add(json.decode(encodedEvent as String));
    },
    onDone: testDone.complete,
    onError: (dynamic error, StackTrace stack) {
      globals.printError('test socket stream experienced an unexpected error');
      onError(error, stack);
    },
    cancelOnError: true,
  );

  globals.printTrace('waiting for test harness or tests to finish');

  await Future.any<void>(<Future<void>>[
    harnessDone.future.then<void>((void value) {
      globals.printTrace('test process is no longer needed by test harness');
    }),
    testDone.future.then<void>((void value) {
      globals.printTrace('test harness is no longer needed by test process');
    }),
  ]);

  await Future.wait<void>(<Future<void>>[
    harnessToTest.cancel(),
    testToHarness.cancel(),
  ]);
}
