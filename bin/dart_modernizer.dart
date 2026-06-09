import 'dart:io';

import 'package:dart_modernizer/src/cli.dart' as cli;

Future<void> main(List<String> args) async {
  exitCode = await cli.run(args);
}
