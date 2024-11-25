import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

const port = 6972;
final environmentMap = <String, String>{};

class Message {
  final InternetAddress fromAddress;
  final int fromPort;
  final Uint8List data;

  const Message({
    required this.fromAddress,
    required this.fromPort,
    required this.data,
  });

  @override
  String toString() {
    return "Message { from: ${fromAddress.host}:$fromPort, data: ${String.fromCharCodes(data)} }";
  }
}

// final broadcastAddress = InternetAddress("255.255.255.255");
final broadcastAddress = InternetAddress("127.0.0.1");

Future<void> startBroadcasting(String payload, Duration interval) async {
  while (true) {
    await Future.delayed(interval, () => sendBroadcast(payload));
  }
}

Future<void> sendBroadcast(String payload) async {
  final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  sender.send(payload.codeUnits, broadcastAddress, port);
}

Stream<Message> listenForBroadcasts() async* {
  final receiver = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);

  await for (final event in receiver) {
    if (event == RawSocketEvent.read) {
      final datagram = receiver.receive();
      if (datagram != null) {
        yield Message(
            fromAddress: datagram.address,
            fromPort: datagram.port,
            data: datagram.data);
      }
    }
  }
}

class SharemFile {
  final String fileName;
  final Uint8List? _rawBody;
  final String? _path;
  final Stream<List<int>>? _stream;

  SharemFile._(this.fileName, this._rawBody, this._path, this._stream);

  factory SharemFile.fromPath(String path) {
    final fileName = p.basename(path);
    return SharemFile._(fileName, null, path, null);
  }

  factory SharemFile.fromBody(String fileName, Uint8List body) {
    return SharemFile._(fileName, body, null, null);
  }

  factory SharemFile.fromStream(String fileName, Stream<List<int>> stream) {
    return SharemFile._(fileName, null, null, stream);
  }

  Stream<Uint8List> asStream([int chunkSize = 64 * 1024]) async* {
    assert(chunkSize > 0);
    if (_path != null) {
      final reader = await File(_path).open();
      while (true) {
        final chunk = await reader.read(chunkSize);
        if (chunk.lengthInBytes == 0) {
          break;
        }
        yield chunk;
      }
    } else if (_rawBody != null) {
      var sentInBytes = 0;
      while (sentInBytes < _rawBody.lengthInBytes) {
        final chunk = _rawBody.sublist(
            sentInBytes, min(sentInBytes + chunkSize, _rawBody.lengthInBytes));
        yield chunk;
      }
    } else if (_stream != null) {
      await for (final chunk in _stream) {
        yield Uint8List.fromList(chunk);
      }
    }
  }

  Future<int> fileLength() async {
    if (_path != null) {
      return File(_path).length();
    } else if (_rawBody != null) {
      return _rawBody.lengthInBytes;
    }
    throw Exception("Invalid File Format");
  }
}

Future<void> sendToHttpServer(
  SharemPeer peer, {
  SharemFile? file,
  String? text,
}) async {
  final headers = <String, String>{};

  if (file != null) {
    headers['Content-Length'] = (await file.fileLength()).toString();
    final uri = peer.buildUri(ShareType.file);
    final request = http.StreamedRequest("POST", uri);
    request.headers.addAll(headers);
    request.sink.addStream(file.asStream());
    final response = await request.send();
    final body = await response.stream.toBytes();
    if (response.statusCode == 200) {
      print("Response ${response.statusCode} ${String.fromCharCodes(body)}");
    } else {
      throw Exception(
          "Response ${response.statusCode} ${String.fromCharCodes(body)}");
    }
  } else if (text != null) {
    final response = await http.post(peer.buildUri(ShareType.text), body: text);
    final body = response.body;
    if (response.statusCode == 200) {
      print("Response ${response.statusCode} $body");
    } else {
      throw Exception("Response ${response.statusCode} $body");
    }
  }
}

typedef CloseFunction = void Function();

class ServerCallbacks {
  FutureOr<void> Function(String text) onTextCallback;
  FutureOr<void> Function(
      String fileName, int fileLength, Stream<List<int>> stream) onFileCallback;

  ServerCallbacks({
    required this.onTextCallback,
    required this.onFileCallback,
  });

  factory ServerCallbacks.empty() {
    return ServerCallbacks(
      onTextCallback: (String text) {},
      onFileCallback:
          (String fileName, int fileLength, Stream<List<int>> stream) {},
    );
  }
}

Future<CloseFunction> startHttpServer(int port,
    {ServerCallbacks? callbacks}) async {
  final server = await shelf_io.serve(requestHandler, '0.0.0.0', port);
  return () => server.close();
}

Future<Response> requestHandler(Request request) async {
  if (request.method == "POST") {
    return handlePost(request);
  }

  return Response(404);
}

Future<Response> handlePost(
  Request request, {
  ServerCallbacks? callbacks,
}) async {
  switch (request.url.path) {
    case "/file":
      {
        final fileName = request.url.queryParameters['fileName'];
        if (fileName == null || !isValidFileName(fileName)) {
          return Response(400,
              body:
                  "fileName query parameter is missing or has invalid characters");
        }
        final contentLength = request.headers['content-length'];
        if (contentLength == null) {
          return Response(400, body: "Missing Content Length");
        }
        final contentLengthInBytes = int.tryParse(contentLength);
        if (contentLengthInBytes == null || contentLengthInBytes <= 0) {
          return Response(400, body: "Invalid Content Length");
        }

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

        if (null != callbacks) {
          await callbacks.onFileCallback(
              fileName, contentLengthInBytes, request.read());
        }

        return Response(200);
      }

    case "/text":
      {
        final body = await request.readAsString();
        if (callbacks != null) {
          await callbacks.onTextCallback(body);
        }
        return Response(200);
      }

    default:
      return Response(404, body: "Invalid Path");
  }
}

bool isValidFileName(String fileName) {
  final regexp = RegExp(r'[. A-Za-z0-9_-]+');
  return regexp.stringMatch(fileName) == fileName;
}

class SharemBroadcastMessage {
  final int port;
  final String uniqueName;

  static const version = "sharem-0.0.1";

  SharemBroadcastMessage(this.port, this.uniqueName);

  String toJSON() {
    return json.encode({
      'version': version,
      'port': port,
      'uniqueName': uniqueName,
    });
  }

  factory SharemBroadcastMessage.fromJSON(String s) {
    final map = Map<String, dynamic>.from(json.decode(s));
    assert(map['version'] == version);
    return SharemBroadcastMessage(map['port'], map['uniqueName']);
  }
}

enum ShareType {
  file,
  text,
}

class SharemPeer {
  final InternetAddress address;
  final int port;
  final String uniqueName;

  SharemPeer({
    required this.address,
    required this.port,
    required this.uniqueName,
  });

  Uri buildUri(ShareType shareType, [String? fileName]) {
    switch (shareType) {
      case ShareType.file:
        if (fileName == null || !isValidFileName(fileName)) {
          throw Exception("Filename is empty or invalid for ShareType.File");
        }

        return Uri.parse(
            "http://${address.host}:$port/file?fileName=$fileName");

      case ShareType.text:
        return Uri.parse("http://${address.host}:$port/text");
    }
  }
}
