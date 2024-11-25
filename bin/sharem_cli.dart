import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import 'package:args/args.dart';
import 'package:sharem_cli/sharem_cli.dart';
import 'package:sharem_cli/unique_name.dart';

const clearLine = '\x1B[2K\x1B[1G';
ArgResults parseArgs(List<String> arguments) {
  final parser = ArgParser();
  parser.addCommand(
      "send",
      ArgParser()
        ..addOption("name", abbr: 'n')
        ..addOption("file", abbr: 'f')
        ..addFlag("text", abbr: 't'));
  parser.addCommand("recv", ArgParser()..addOption("name", abbr: "n"));
  parser.addCommand("list");

  final result = parser.parse(arguments);
  return result;
}

void main(List<String> arguments) async {
  final args = parseArgs(arguments);

  if (args.command?.name != null) {
    switch (args.command!.name!) {
      case "send":
        {
          sendCommand(
            sendTo: args.command!.option("name"),
            filePath: args.command!.option("file"),
          );
        }
        break;
      case "recv":
        await receiveCommand(myName: args.command!.option("name"));
        break;
      case "list":
        await listCommand(Duration(seconds: 4));
        exit(0);
      default:
        print("Unknown command");
        exit(3);
    }
  }
}

class PeerState {
  final SharemPeer selfPeer;

  PeerState._(this.selfPeer);

  static Future<PeerState> initalize(
      {String? myName, ServerCallbacks? callbacks}) async {
    final selfPeer =
        await SharemPeer.initalize(callbacks: callbacks, myName: myName);
    final payload = selfPeer.toMessage().toJSON();
    startBroadcasting(payload, const Duration(seconds: 1));
    final state = PeerState._(selfPeer);
    return state;
  }
}

class PeerGatherer {
  final Map<String, SharemPeer> peers = {};
  StreamSubscription? _subscription;
  PeerGatherer();

  void startGathering([void Function(SharemPeer)? callback]) {
    _subscription = listenForPeers().listen((peer) {
      if (peers[peer.uniqueName] == null) {
        if (callback != null) {
          callback(peer);
        }
        // print("Peer found: ${peer.uniqueName} from ${peer.address}");
      }
      peers[peer.uniqueName] = peer;
    });
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}

Future<PeerGatherer> listCommand(
    [Duration duration = const Duration(seconds: 4)]) async {
  print("Gathering Peers...");
  final gatherer = PeerGatherer();
  gatherer.startGathering();
  await Future.delayed(duration);
  gatherer.dispose();

  print("Found ${gatherer.peers.length} Peers");
  for (final peer in gatherer.peers.values) {
    print("${peer.address.address}:${peer.port} ${peer.uniqueName}");
  }
  return gatherer;
}

Future<void> sendCommand(
    {String? sendTo,
    String? filePath,
    Duration timeout = const Duration(seconds: 5)}) async {
  if (sendTo != null) {
    final gatherer = PeerGatherer();
    final payload = <int>[];

    if (filePath == null) {
      await for (final chunk in stdin) {
        payload.addAll(chunk);
      }
    }

    gatherer.startGathering((peer) {
      if (peer.uniqueName.toLowerCase() == sendTo.toLowerCase()) {
        print("Found '$sendTo' at ${peer.address.host}:${peer.port} ");

        gatherer.dispose();
        final text = utf8.decode(payload);
        if (filePath == null) {
          peer.sendText(text).whenComplete(() => exit(0));
        } else {
          print("Sending File $filePath");

          final file = SharemFile.fromPath(filePath);

          peer
              .sendFile(file,
                  progressCallback: (bytesSent, totalBytes) => stdout.write(
                      "${clearLine}Sending $bytesSent/$totalBytes = ${100 * bytesSent / totalBytes}%"))
              .whenComplete(() {
            stdout.writeln();
            exit(0);
          });
        }
      }
    });

    return;
  }

  final gatherer = await listCommand();

  while (true) {
    print("Enter Sender Unique Name : ");
    final line = stdin.readLineSync()?.trim();
    if (line == null || line.isEmpty) {
      continue;
    }
    final key = gatherer.peers.keys.singleWhere(
        (e) => e.toLowerCase() == line.toLowerCase(),
        orElse: () => "");
    if (key.isEmpty) {
      print("Invalid peer name, retry");
      continue;
    }

    final peer = gatherer.peers[key]!;
    await peer.sendText("Hello World, This is ${generateUniqueName()}");
    break;
  }
}

Future<void> receiveCommand({String? myName}) async {
  final callbacks = ServerCallbacks(onTextCallback: (text) {
    print("Received '$text'");
  }, onFileCallback: (fileName, fileLength, stream) async {
    print("Receiving a File '$fileName' of Length $fileLength");

    // final downloadDirPath = environmentMap["SHAREM_SAVE_DIR"];
    // if (downloadDirPath == null) {
    //   throw Exception("SHAREM_SAVE_DIR is not set");
    // }
    // final file = File(p.join(downloadDirPath, fileName));
    // final sink = await file.open(mode: FileMode.write);
    // await for (final chunk in request.read()) {
    //   await sink.writeFrom(chunk);
    // }

    // await sink.flush();
    // await sink.close();

    // TODO: Do Validation of file name
    final key = "SHAREM_SAVE_DIR";
    final directoryPath =
        bool.hasEnvironment(key) ? String.fromEnvironment(key) : "/tmp/";

    final file = File(p.join(directoryPath, fileName));
    final sink = file.openWrite();
    var bytesReceived = 0;

    await for (final chunk in stream) {
      sink.add(chunk);
      bytesReceived += chunk.length;

      stdout.write(
          "${clearLine}Receiveing $bytesReceived/$fileLength = ${100 * bytesReceived / fileLength}%");
    }
    stdout.writeln();

    await sink.flush();
    await sink.close();

    print("Saved File ${file.path}");
  });
  final state = await PeerState.initalize(callbacks: callbacks, myName: myName);
  print(
      "Ready to receive at ${state.selfPeer.address.host}:${state.selfPeer.port} as ${state.selfPeer.uniqueName}");
}
