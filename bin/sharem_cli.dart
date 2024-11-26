import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import 'package:args/args.dart';
import 'package:sharem_cli/sharem_cli.dart';
import 'package:sharem_cli/unique_name.dart';

ArgParser getParser() {
  final parser = ArgParser();
  parser.addCommand(
      "send",
      ArgParser()
        ..addOption("name", abbr: 'n', help: "Set Receiver name")
        ..addMultiOption("file", abbr: 'f', help: "File path to send")
        ..addFlag("text", abbr: 't', help: "Text mode, reads from stdin"));
  parser.addCommand(
      "recv",
      ArgParser()
        ..addOption("name",
            abbr: "n",
            defaultsTo: generateUniqueName(),
            help: "Set your name for others"));
  parser.addCommand("list", ArgParser()..addOption("timeout", abbr: "t"));

  return parser;
}

ArgResults parseArgs(List<String> arguments) {
  final result = getParser().parse(arguments);
  return result;
}

void main(List<String> arguments) async {
  final args = parseArgs(arguments);

  if (args.command?.name != null) {
    switch (args.command!.name!) {
      case "send":
        {
          final sendTo = args.command!.option("name");
          if (sendTo == null) {
            print("missing --name option to send to");
            exitOut(1);
            return;
          }

          await sendCommand(
            sendTo: sendTo,
            filePaths: args.command!.multiOption("file"),
          );
        }
        return;
      case "recv":
        await receiveCommand(myName: args.command!.option("name"));
        return;
      case "list":
        await listCommand(Duration(seconds: 4));
        exitOut(0);
        return;
      default:
    }
  }
  print("Unknown command");
  printUsage();
  exitOut(3);
}

void printUsage() {
  final executable = p.basename(Platform.script.toString());
  final s = """
    $executable [command] <options>
    
    commands:
      send
          -n receiver_name required
          -t flag reads from stdin and sends to receiver
          -f file paths to send
      recv
          -n your_name if not passed, generates a unique name
      list
          lists nearby active peers
    Example Usage:
      $executable recv -n JaneDoe
      echo 'Hello World' | $executable send -n  JaneDoe
      $executable send -n JaneDoe -f ./README.md ./cat-video.mp4
      $executable list
  """;
  print(s);
}

Future<PeerGatherer> listCommand(
    [Duration duration = const Duration(seconds: 4)]) async {
  print("Gathering Peers...");
  final gatherer = PeerGatherer();
  gatherer.startGathering((peer) =>
      print("${peer.address.address}:${peer.port} ${peer.uniqueName}"));
  await Future.delayed(duration);
  gatherer.dispose();

  print("Found ${gatherer.length} Peers");
  return gatherer;
}

Future<void> sendCommand(
    {required String sendTo,
    List<String> filePaths = const [],
    Duration timeout = const Duration(seconds: 5)}) async {
  final gatherer = PeerGatherer();
  final payload = <int>[];

  if (filePaths.isEmpty) {
    await for (final chunk in stdin) {
      payload.addAll(chunk);
    }
  }

  gatherer.startGathering((peer) async {
    if (peer.uniqueName.toLowerCase() == sendTo.toLowerCase()) {
      print("Found '$sendTo' at ${peer.address.host}:${peer.port} ");

      gatherer.dispose();
      final text = utf8.decode(payload);
      if (filePaths.isEmpty) {
        peer.sendText(text).whenComplete(() => exitOut(0));
      } else {
        final files = filePaths.map(SharemFile.fromPath).toList();
        final progresses = Map.fromEntries(await Future.wait(files.map(
            (e) async =>
                MapEntry(e.fileName, Progress(await e.fileLength())))));

        printProgresses("Sending", progresses);
        await peer.sendFiles(generateUniqueName(), files,
            progressCallback: (fileName, progress) {
          progresses[fileName] = progress;
          printProgresses("Sending", progresses, true);
        });

        exitOut(0);
        // }
      }
    }
  });
}

Future<void> receiveCommand({String? myName}) async {
  SharemFileShareRequest? pendingRequest;
  Map<String, Progress> progresses = {};

  final directoryPath = getEnvironmentVariable("SHAREM_SAVE_DIR") ?? "/tmp/";
  final callbacks = ServerCallbacks(onTextCallback: (text) {
    print("Received '$text'");
  }, onFileCallback: (fileName, fileLength, stream) async {
    if (pendingRequest != null) {
      if (pendingRequest!.fileNameAndLength[fileName] != fileLength) {
        print(
            "Rejected, File Lengths mismatch expected ${pendingRequest!.fileNameAndLength[fileName]} got $fileLength");
        return;
      }
      final file = File(p.join(directoryPath, fileName));
      final sink = file.openWrite();
      final progress = progresses[fileName]!;

      await for (final chunk in stream) {
        sink.add(chunk);
        progress.addProgress(chunk.length);
        printProgresses("Receiving", progresses, true);
      }

      await sink.flush();
      await sink.close();

      if (progresses.entries.every((e) => e.value.isComplete())) {
        for (final fileName in progresses.keys) {
          print("File Saved ${p.join(directoryPath, fileName)}");
        }
        progresses.clear();
        pendingRequest = null;
      }

      return;
    }

    // print("Receiving a File '$fileName' of Length $fileLength");
    // if (!askAccept()) {
    //   return;
    // }

    // // TODO: Do Validation of file name

    // final file = File(p.join(directoryPath, fileName));
    // final sink = file.openWrite();
    // final progress = Progress(fileLength);

    // await for (final chunk in stream) {
    //   sink.add(chunk);
    //   progress.addProgress(chunk.length);

    //   stdout.write("${clearLine}Received ${progress.toPrettyString()}");
    // }
    // stdout.writeln();

    // await sink.flush();
    // await sink.close();

    // print("Saved File ${file.path}");
  }, onFileShareRequest: (request) {
    if (pendingRequest != null) {
      print(
          "WARN: Ignored other file share request from ${request.uniqueName}");
      return false;
    }

    print("'${request.uniqueName}' wants to send these files to you");
    print('================================');
    for (final entry in request.fileNameAndLength.entries) {
      print('filename: ${entry.key} size: ${formatBytes(entry.value)}');
    }
    print('================================');
    if (askAccept()) {
      pendingRequest = request;
      progresses.clear();
      for (final entry in request.fileNameAndLength.entries) {
        progresses[entry.key] = Progress(entry.value);
      }
      printProgresses("Receiving", progresses);
      return true;
    } else {
      return false;
    }
  });
  final state = await PeerState.initalize(callbacks: callbacks, myName: myName);
  print(
      "Ready to receive at ${state.selfPeer.address.host}:${state.selfPeer.port} as ${state.selfPeer.uniqueName}");
}

bool askAccept() {
  stdout.write("Accept [Y/n] ");
  final answer = stdin.readLineSync()?.trim();
  if (answer == null) {
    return false;
  }
  if (answer.isEmpty || answer == 'y' || answer == 'Y') {
    return true;
  } else if (answer.isNotEmpty && (answer == 'n' || answer == 'N')) {
    return false;
  } else {
    print("Invalid Option, Rejecting request");
    return false;
  }
}

void printProgresses(String prefix, Map<String, Progress> progresses,
    [bool clear = false]) {
  const moveUpAndClearLine = '\x1B[F\x1B[2K';

  if (clear) {
    for (var i = 0; i < progresses.length; i++) {
      stdout.write(moveUpAndClearLine);
    }
  }

  for (final entry in progresses.entries) {
    print("$prefix ${entry.key} ${entry.value.toPrettyString()}");
  }
}

void exitOut([int code = 0]) {
  flushLog().whenComplete(() => exit(code));
}
