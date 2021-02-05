// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.8

import 'dart:async';
import 'dart:io' as io; // ignore: dart_io_import;

import 'package:dds/dds.dart';
import 'package:flutter_tools/src/android/android_device.dart';
import 'package:meta/meta.dart';
import 'package:vm_service/vm_service.dart' as vm_service;

import '../application_package.dart';
import '../base/common.dart';
import '../base/file_system.dart';
import '../base/io.dart';
import '../build_info.dart';
import '../convert.dart';
import '../device.dart';
import '../globals.dart' as globals;
import '../project.dart';
import '../vmservice.dart';
import 'test_compiler.dart';

/// A remote device where tests can be executed on.
abstract class TestDevice {
  /// Starts the test device with the provided entrypoint.
  ///
  /// A [compiledEntrypointPath] can also be passed. Some platforms, when passed
  /// this, will skip compiling [entrypointPath], and use the former instead.
  ///
  /// [serverPort] will indicate the port on the localhost to establish a
  /// websocket connection for tests to be controlled.
  Future<void> start({
    @required String entrypointPath,
    String compiledEntrypointPath,
    @required int serverPort,
  });

  /// Should complete with null if the observatory is not enabled.
  Future<Uri> get observatoryUri;

  /// Terminates the test device.
  ///
  /// A [TestDeviceException] can be thrown if it did not stop gracefully.
  Future<void> kill();

  /// Waits for the test device to stop.
  ///
  /// A [TestDeviceException] can be thrown if it did not stop gracefully.
  Future<void> get finished;
}

/// Thrown when the test device encounters a problem in it's lifecycle.
class TestDeviceException implements Exception {
  TestDeviceException(this.message);

  final String message;

  @override
  String toString() => 'TestDeviceException($message)';
}

class IntegrationTestTestDevice implements TestDevice {
  IntegrationTestTestDevice({
    @required this.device,
    @required this.debuggingOptions,
  });

  final Device device;
  final DebuggingOptions debuggingOptions;

  ApplicationPackage _applicationPackage;
  final Completer<void> _finished = Completer<void>();
  Uri _observatoryUri;

  @override
  Future<void> start({
    @required String entrypointPath,
    String compiledEntrypointPath,
    @required int serverPort,
  }) async {
    assert(
      compiledEntrypointPath == null,
      'Passing a compiled entrypoint to an IntegrationTestTestDevice is not supported.',
    );

    final TargetPlatform targetPlatform = await device.targetPlatform;
    _applicationPackage = await ApplicationPackageFactory.instance.getPackageForPlatform(
      targetPlatform,
      buildInfo: debuggingOptions.buildInfo,
    );

    // Hack.
    // - Reverse API is missing from the forwarder.
    // - The port on the device here is forced to match what is used on the host.
    //   If there is something already listening on that port on the device,
    //   this will fail.
    // - If we want to let this API tell us what the port should be, we cannot
    //   bundle this port as part of codegen.
    if (targetPlatform == TargetPlatform.android ||
        targetPlatform == TargetPlatform.android_arm ||
        targetPlatform == TargetPlatform.android_arm64 ||
        targetPlatform == TargetPlatform.android_x64 ||
        targetPlatform == TargetPlatform.android_x86) {
      await(device.portForwarder as AndroidDevicePortForwarder).reverse(serverPort);
    }

    final LaunchResult launchResult = await device.startApp(
      _applicationPackage,
      mainPath: entrypointPath,
      platformArgs: <String, Object>{
        'uri': 'helloweb',
      },
      // route: route,
      debuggingOptions: debuggingOptions,
      // applicationBinary: applicationBinary,
      //   userIdentifier: userIdentifier,
      //   prebuiltApplication: prebuiltApplication,
    );


    assert(launchResult.started);

    _observatoryUri = launchResult.observatoryUri;

    // TODO: Connect the logs as part of the interface.

    // final DeviceLogReader logReader = await device.getLogReader(app: applicationPackage);
    // // logReader.logLines.listen(_logger.printStatus);

    // final vm_service.VM vm = await _vmService.getVM();
    // logReader.appPid = vm.pid;
  }

  @override
  Future<Uri> get observatoryUri async => _observatoryUri;

  // TODO: Figure this out.
  String userIdentifier;

  @override
  Future<void> kill() async {
    if (!await device.stopApp(_applicationPackage, userIdentifier: userIdentifier)) {
        globals.printError('Failed to stop app');
    }
    if (!await device.uninstallApp(_applicationPackage, userIdentifier: userIdentifier)) {
      globals.printError('Failed to uninstall app');
    }

    await device.dispose();
    _finished.complete();
  }

  @override
  Future<void> get finished => _finished.future;
}

/// Implementation of [TestDevice] with the Flutter Tester over a [Process].
class FlutterTesterTestDevice extends TestDevice {
  FlutterTesterTestDevice({
    @required this.shellPath,
    @required this.enableObservatory,
    @required this.machine,
    @required this.explicitObservatoryPort,
    @required this.host,
    @required this.buildTestAssets,
    @required this.flutterProject,
    @required this.icudtlPath,
    @required this.additionalArguments,
    @required this.compileExpression,
    @required this.fontConfigManager,
    @required this.debuggingOptions,
  })  : assert(shellPath != null), // Please provide the path to the shell in the SKY_SHELL environment variable.
        assert(!debuggingOptions.startPaused || enableObservatory);

  final String shellPath;
  final bool enableObservatory;
  final bool machine;
  final int explicitObservatoryPort;
  final InternetAddress host;
  final bool buildTestAssets;
  final FlutterProject flutterProject;
  final String icudtlPath;
  final List<String> additionalArguments;
  final CompileExpression compileExpression;
  final FontConfigManager fontConfigManager;
  final DebuggingOptions debuggingOptions;

  Process _process;
  Completer<Uri> _gotProcessObservatoryUri;
  // TODO is a global the best way to do this?
  /// The test compiler produces dill files for each test main.
  ///
  /// To speed up compilation, each compile is initialized from an existing
  /// dill file from previous runs, if possible.
  static TestCompiler compiler;

  @override
  Future<void> start({
    @required String entrypointPath,
    String compiledEntrypointPath,
    @required int serverPort,
  }) async {
    assert(_process == null);
    assert(_gotProcessObservatoryUri == null);

    // If a kernel file is given, then use that to launch the test.
    // If mapping is provided, look kernel file from mapping.
    // If all fails, create a "listener" dart that invokes actual test.
    String mainDart = entrypointPath;
    if (compiledEntrypointPath != null) {
      mainDart = compiledEntrypointPath;
    } else {
      // Lazily instantiate compiler so it is built only if it is actually used.
      compiler ??= TestCompiler(debuggingOptions.buildInfo, flutterProject);
      mainDart = await compiler.compile(globals.fs.file(mainDart).uri);

      if (mainDart == null) {
        throw TestDeviceException('Compilation failed');
      }
    }

    final List<String> command = <String>[
      shellPath,
      if (enableObservatory) ...<String>[
        // Some systems drive the _FlutterPlatform class in an unusual way, where
        // only one test file is processed at a time, and the operating
        // environment hands out specific ports ahead of time in a cooperative
        // manner, where we're only allowed to open ports that were given to us in
        // advance like this. For those esoteric systems, we have this feature
        // whereby you can create _FlutterPlatform with a pair of ports.
        //
        // I mention this only so that you won't be tempted, as I was, to apply
        // the obvious simplification to this code and remove this entire feature.
        '--observatory-port=${debuggingOptions.disableDds ? explicitObservatoryPort : 0}',
        if (debuggingOptions.startPaused) '--start-paused',
        if (debuggingOptions.disableServiceAuthCodes) '--disable-service-auth-codes',
      ]
      else
        '--disable-observatory',
      if (host.type == InternetAddressType.IPv6) '--ipv6',
      if (icudtlPath != null) '--icu-data-file-path=$icudtlPath',
      '--enable-checked-mode',
      '--verify-entry-points',
      '--enable-software-rendering',
      '--skia-deterministic-rendering',
      '--enable-dart-profiling',
      '--non-interactive',
      '--use-test-fonts',
      '--packages=${debuggingOptions.buildInfo.packagesPath}',
      if (debuggingOptions.nullAssertions)
        '--dart-flags=--null_assertions',
      ...?additionalArguments,
      mainDart,
    ];
    globals.printTrace(command.join(' '));
    // If the FLUTTER_TEST environment variable has been set, then pass it on
    // for package:flutter_test to handle the value.
    //
    // If FLUTTER_TEST has not been set, assume from this context that this
    // call was invoked by the command 'flutter test'.
    final String flutterTest = globals.platform.environment.containsKey('FLUTTER_TEST')
        ? globals.platform.environment['FLUTTER_TEST']
        : 'true';
    final Map<String, String> environment = <String, String>{
      'FLUTTER_TEST': flutterTest,
      'FONTCONFIG_FILE': fontConfigManager.fontConfigFile.path,
      'SERVER_PORT': serverPort.toString(),
      'APP_NAME': flutterProject?.manifest?.appName ?? '',
      if (buildTestAssets)
        'UNIT_TEST_ASSETS': globals.fs.path.join(flutterProject?.directory?.path ?? '', 'build', 'unit_test_assets'),
    };
    _process = await globals.processManager.start(command, environment: environment);

    globals.printTrace('Started flutter_tester process at pid ${_process.pid}');

    _gotProcessObservatoryUri = Completer<Uri>();
    if (!enableObservatory) {
      _gotProcessObservatoryUri.complete();
    }

    // Pipe stdout and stderr from the subprocess to our printStatus console.
    // We also keep track of what observatory port the engine used, if any.
    _pipeStandardStreamsToConsole(
      _process,
      reportObservatoryUri: (Uri detectedUri) async {
        assert(!_gotProcessObservatoryUri.isCompleted);
        assert(explicitObservatoryPort == null ||
            explicitObservatoryPort == detectedUri.port);

        Uri forwardingUri;
        if (!debuggingOptions.disableDds) {
          final DartDevelopmentService dds = await startDds(detectedUri);
          forwardingUri = dds.uri;
          globals.printTrace('Dart Development Service started at ${dds.uri}, forwarding to VM service at ${dds.remoteVmServiceUri}.');
        } else {
          forwardingUri = detectedUri;
        }
        {
          globals.printTrace('Connecting to service protocol: $forwardingUri');
          final Future<vm_service.VmService> localVmService = connectToVmService(
            forwardingUri,
            // TODO this is needed for integration test debugging.
            compileExpression: compileExpression,
          );
          unawaited(localVmService.then((vm_service.VmService vmservice) {
            globals.printTrace('Successfully connected to service protocol: $forwardingUri');
          }));
        }
        if (debuggingOptions.startPaused && !machine) {
          globals.printStatus('The test process has been started.');
          globals.printStatus('You can now connect to it using observatory. To connect, load the following Web site in your browser:');
          globals.printStatus('  $forwardingUri');
          globals.printStatus('You should first set appropriate breakpoints, then resume the test in the debugger.');
        }
        _gotProcessObservatoryUri.complete(forwardingUri);
      },
    );
  }

  @override
  Future<Uri> get observatoryUri {
    assert(_gotProcessObservatoryUri != null);
    return _gotProcessObservatoryUri.future;
  }

  @override
  Future<void> kill() async {
    if (_process == null) {
      return;
    }
    _process.kill(io.ProcessSignal.sigkill);
    return finished;
  }

  @override
  Future<void> get finished async {
    if (_process == null) {
      return;
    }
    final int exitCode = await _process.exitCode;
    _process = null;
    _gotProcessObservatoryUri = null;

    // ProcessSignal.SIGKILL. Negative because signals are returned as negative
    // exit codes.
    if (exitCode == -9) {
      // We expect SIGKILL (9) because we could have tried to [kill] it.
      return;
    }
    throw TestDeviceException(_getErrorMessage(_getExitCodeMessage(exitCode), shellPath));
  }

  Uri get _ddsServiceUri {
    return Uri(
      scheme: 'http',
      host: (host.type == InternetAddressType.IPv6 ?
        InternetAddress.loopbackIPv6 :
        InternetAddress.loopbackIPv4
      ).host,
      port: explicitObservatoryPort ?? 0,
    );
  }

  @visibleForTesting
  @protected
  Future<DartDevelopmentService> startDds(Uri uri) {
    return DartDevelopmentService.startDartDevelopmentService(
      uri,
      serviceUri: _ddsServiceUri,
      enableAuthCodes: !debuggingOptions.disableServiceAuthCodes,
      ipv6: host.type == InternetAddressType.IPv6,
    );
  }

  @override
  String toString() {
    final String status = _process != null ? 'pid: ${_process.pid}' : 'idle';
    return 'Flutter Tester process ($status)';
  }
}

void _pipeStandardStreamsToConsole(
  Process process, {
  Future<void> reportObservatoryUri(Uri uri),
}) {
  const String observatoryString = 'Observatory listening on ';
  for (final Stream<List<int>> stream in <Stream<List<int>>>[
    process.stderr,
    process.stdout,
  ]) {
    stream
        .transform<String>(utf8.decoder)
        .transform<String>(const LineSplitter())
        .listen(
      (String line) async {
        if (line.startsWith("error: Unable to read Dart source 'package:test/")) {
          globals.printTrace('Shell: $line');
          globals.printError('\n\nFailed to load test harness. Are you missing a dependency on flutter_test?\n');
        } else if (line.startsWith(observatoryString)) {
          globals.printTrace('Shell: $line');
          try {
            final Uri uri = Uri.parse(line.substring(observatoryString.length));
            if (reportObservatoryUri != null) {
              await reportObservatoryUri(uri);
            }
          } on Exception catch (error) {
            globals.printError('Could not parse shell observatory port message: $error');
          }
        } else if (line != null) {
          globals.printStatus('Shell: $line');
        }
      },
      onError: (dynamic error) {
        globals. printError('shell console stream for process pid ${process.pid} experienced an unexpected error: $error');
      },
      cancelOnError: true,
    );
  }
}

String _getErrorMessage(String what, String shellPath) {
  return '$what\nShell: $shellPath\n\n';
}

String _getExitCodeMessage(int exitCode) {
  switch (exitCode) {
    case 1:
      return 'Shell subprocess cleanly reported an error. Check the logs above for an error message.';
    case 0:
      return 'Shell subprocess ended cleanly. Did main() call exit()?';
    case -0x0f: // ProcessSignal.SIGTERM
      return 'Shell subprocess crashed with SIGTERM ($exitCode).';
    case -0x0b: // ProcessSignal.SIGSEGV
      return 'Shell subprocess crashed with segmentation fault.';
    case -0x06: // ProcessSignal.SIGABRT
      return 'Shell subprocess crashed with SIGABRT ($exitCode).';
    case -0x02: // ProcessSignal.SIGINT
      return 'Shell subprocess terminated by ^C (SIGINT, $exitCode).';
    default:
      return 'Shell subprocess crashed with unexpected exit code $exitCode.';
  }
}

class FontConfigManager {
  Directory _fontsDirectory;
  File _cachedFontConfig;

  Future<void> dispose() async {
    if (_fontsDirectory != null) {
      globals.printTrace('Deleting ${_fontsDirectory.path}...');
      await _fontsDirectory.delete(recursive: true);
      _fontsDirectory = null;
    }
  }

  /// Returns a Fontconfig config file that limits font fallback to the artifact
  /// cache directory.
  File get fontConfigFile {
    if (_cachedFontConfig != null) {
      return _cachedFontConfig;
    }

    final StringBuffer sb = StringBuffer();
    sb.writeln('<fontconfig>');
    sb.writeln('  <dir>${globals.cache.getCacheArtifacts().path}</dir>');
    sb.writeln('  <cachedir>/var/cache/fontconfig</cachedir>');
    sb.writeln('</fontconfig>');

    if (_fontsDirectory == null) {
      _fontsDirectory = globals.fs.systemTempDirectory.createTempSync('flutter_test_fonts.');
      globals.printTrace('Using this directory for fonts configuration: ${_fontsDirectory.path}');
    }

    _cachedFontConfig = globals.fs.file('${_fontsDirectory.path}/fonts.conf');
    _cachedFontConfig.createSync();
    _cachedFontConfig.writeAsStringSync(sb.toString());
    return _cachedFontConfig;
  }
}
