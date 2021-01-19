// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.8

import 'dart:async';

import 'package:dds/dds.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/test/test_device.dart';
import 'package:meta/meta.dart';
import 'package:mockito/mockito.dart';
import 'package:process/process.dart';

import '../src/common.dart';
import '../src/context.dart';

void main() {
  group('Observatory and DDS setup', () {
    ProcessManager mockProcessManager;

    final Map<Type, Generator> contextOverrides = <Type, Generator>{
      ProcessManager: () => mockProcessManager,
    };

    setUp(() {
      mockProcessManager = FakeProcessManager.list(<FakeCommand>[
        const FakeCommand(
          command: <String>[
            '/',
            '--observatory-port=0',
            '--ipv6',
            '--enable-checked-mode',
            '--verify-entry-points',
            '--enable-software-rendering',
            '--skia-deterministic-rendering',
            '--enable-dart-profiling',
            '--non-interactive',
            '--use-test-fonts',
            '--packages=.dart_tool/package_config.json',
            'example.dill'
          ],
          stdout: 'Observatory listening on http://localhost:1234',
          stderr: 'failure',
          exitCode: 0,
        )
      ]);
    });

    testUsingContext('skips setting observatory port and uses the input port for for DDS instead', () async {
      final TestFlutterTesterDevice testDevice = TestFlutterTesterDevice(enableObservatory: true);
      await testDevice.start(compiledEntrypointPath: 'example.dill', serverPort: 123);
      await testDevice.observatoryUri;

      final Uri uri = await testDevice.ddsServiceUriFuture();
      expect(uri.port, 1234);
    }, overrides: contextOverrides);
  });
}

class TestFlutterTesterDevice extends FlutterTesterTestDevice {
  TestFlutterTesterDevice({@required bool enableObservatory}) : super(
    shellPath: '/',
    enableObservatory: enableObservatory,
    machine: false,
    startPaused: false,
    disableServiceAuthCodes: false,
    disableDds: false,
    explicitObservatoryPort: 1234,
    host: InternetAddress.loopbackIPv6,
    buildTestAssets: false,
    flutterProject: null,
    icudtlPath: null,
    nullAssertions: false,
    buildInfo: const BuildInfo(BuildMode.debug, '', treeShakeIcons: false, packagesPath: '.dart_tool/package_config.json'),
    compileExpression: null,
    additionalArguments: <String>[],
    fontConfigManager: FontConfigManager(),
  );

  final Completer<Uri> _ddsServiceUriCompleter = Completer<Uri>();

  Future<Uri> ddsServiceUriFuture() => _ddsServiceUriCompleter.future;

  @override
  Future<DartDevelopmentService> startDds(Uri uri) async {
    _ddsServiceUriCompleter.complete(uri);
    final MockDartDevelopmentService mock = MockDartDevelopmentService();
    when(mock.uri).thenReturn(Uri.parse('http://localhost:$explicitObservatoryPort'));
    return mock;
  }
}

class MockDartDevelopmentService extends Mock implements DartDevelopmentService {}
