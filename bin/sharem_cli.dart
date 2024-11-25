import 'dart:io';

import 'package:args/args.dart';
import 'package:sharem_cli/sharem_cli.dart';

ArgResults parseArgs(List<String> arguments) {
  final parser = ArgParser();
  final sendArgParser = ArgParser()
    ..addOption("file")
    ..addFlag("text");
  parser.addCommand("send", sendArgParser);
  parser.addCommand("recv");

  final result = parser.parse(arguments);
  return result;
}

void main(List<String> arguments) async {
  final args = parseArgs(arguments);

  if (args.command?.name == "send") {
    final filePath = args.command!.option("file");
    if (filePath != null) {
      // send file
    } else if (args.command!.flag("text")) {
      final text = args.command!.rest;
      if (text.isEmpty) {
        // use stdin;
        final file = SharemFile.fromStream("", stdin);
      } else {
        final payload = text.join(' ');
        await sendToHttpServer(, payload);
      }
    }
  } else {
    print("Args name is different ${args.command?.name}");
    // start receiving
  }

  return;

  environmentMap['SHAREM_SAVE_DIR'] = bool.hasEnvironment("SHAREM_SAVE_DIR")
      ? String.fromEnvironment("SHAREM_SAVE_DIR")
      : "/tmp/";
  if (arguments.isNotEmpty && arguments[0] == 'send') {
    final message = arguments
        .sublist(
          1,
        )
        .join(' ');
    print("Sending $message");
    await startBroadcasting(message, Duration(seconds: 1));
    return;
  }

  print("Receiving broadcasts");
  await for (final message in listenForBroadcasts()) {
    print(message);
  }
}
