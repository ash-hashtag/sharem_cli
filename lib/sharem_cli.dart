import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:sharem_cli/unique_name.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

final myHash = generateUniqueHash();

class SharemMessage {
  final InternetAddress fromAddress;
  final int fromPort;
  final Uint8List data;

  const SharemMessage({
    required this.fromAddress,
    required this.fromPort,
    required this.data,
  });

  @override
  String toString() {
    return "SharemMessage { from: ${fromAddress.host}:$fromPort, data: ${String.fromCharCodes(data)} }";
  }
}

const defaultPort = 6972;
Future<void> startBroadcasting(
    InternetAddress broadcastAddress, String payload, Duration interval,
    [int port = defaultPort]) async {
  final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  sender.broadcastEnabled = true;

  final data = utf8.encode(payload);

  while (true) {
    await Future.delayed(
        interval, () => sender.send(data, broadcastAddress, port));
  }
}

Future<void> sendBroadcast(String payload, InternetAddress broadcastAddress,
    [int port = defaultPort]) async {
  final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  sender.broadcastEnabled = true;
  sender.send(utf8.encode(payload), broadcastAddress, port);
}

Stream<SharemMessage> listenForBroadcasts([int port = defaultPort]) async* {
  final receiver = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
  receiver.broadcastEnabled = true;

  await for (final event in receiver) {
    if (event == RawSocketEvent.read) {
      final datagram = receiver.receive();
      if (datagram != null) {
        yield SharemMessage(
            fromAddress: datagram.address,
            fromPort: datagram.port,
            data: datagram.data);
      }
    }
  }
}

Stream<SharemPeer> listenForPeers() async* {
  await for (final message in listenForBroadcasts()) {
    try {
      final msgText = utf8.decode(message.data);
      final peerMsg = SharemPeerMessage.fromJSON(msgText);
      final peer = SharemPeer.fromMessage(peerMsg, message.fromAddress);
      if (peer.uniqueHash != myHash) {
        yield peer;
      }
    } catch (e) {
      stderr.writeln("parsing broadcast datagram failed, ignoring");
    }
  }
}

class SharemFile {
  final String fileName;
  final Uint8List? _rawBody;
  final String? _path;
  final Stream<List<int>>? _stream;
  final int? _streamLength;

  SharemFile._(this.fileName, this._rawBody, this._path, this._stream,
      this._streamLength);

  factory SharemFile.fromPath(String path) {
    final fileName = p.basename(path);
    return SharemFile._(fileName, null, path, null, null);
  }

  factory SharemFile.fromBody(String fileName, Uint8List body) {
    return SharemFile._(fileName, body, null, null, null);
  }

  factory SharemFile.fromStream(
      String fileName, Stream<List<int>> stream, int length) {
    return SharemFile._(fileName, null, null, stream, length);
  }

  Stream<Uint8List> asStream(
      {int chunkSize = 128 * 1024,
      ProgressCallback progressCallback = emptyProgressCallback}) async* {
    assert(chunkSize > 0);
    final totalByteLength = await fileLength();
    final progress = Progress(totalByteLength);
    if (_path != null) {
      final reader = await File(_path).open();

      while (true) {
        final chunk = await reader.read(chunkSize);
        if (chunk.lengthInBytes == 0) {
          break;
        }
        yield chunk;
        progressCallback(progress.addProgress(chunk.lengthInBytes));

        // throttle
        // await Future.delayed(Duration(milliseconds: 5));
      }
    } else if (_rawBody != null) {
      var sentInBytes = 0;
      while (sentInBytes < _rawBody.lengthInBytes) {
        final chunk = _rawBody.sublist(
            sentInBytes, min(sentInBytes + chunkSize, _rawBody.lengthInBytes));
        yield chunk;
        progressCallback(progress.addProgress(chunk.lengthInBytes));
      }
    } else if (_stream != null) {
      await for (final chunk in _stream) {
        yield Uint8List.fromList(chunk);
        progressCallback(progress.addProgress(chunk.length));
      }
    }
  }

  Future<int> fileLength() async {
    if (_path != null) {
      return await File(_path).length();
    } else if (_rawBody != null) {
      return _rawBody.lengthInBytes;
    } else if (_stream != null && _streamLength != null) {
      return _streamLength;
    }
    throw Exception("Invalid File Format");
  }
}

typedef ProgressCallback = void Function(Progress progress);

void emptyProgressCallback(Progress _) {}

class ServerCallbacks {
  FutureOr<void> Function(String uniqueName, InternetAddress, String text)
      onTextCallback;
  FutureOr<void> Function(String uniqueName, String uniqueCode, SharemFile file)
      onFileCallback;

  FutureOr<bool> Function(SharemFileShareRequest request) onFileShareRequest;

  ServerCallbacks({
    required this.onTextCallback,
    required this.onFileCallback,
    required this.onFileShareRequest,
  });
}

Future<HttpServer> startHttpServer(int port,
    {ServerCallbacks? callbacks}) async {
  return await shelf_io.serve(
      (req) => requestHandler(req, callbacks), '0.0.0.0', port);
}

Future<Response> requestHandler(
    Request request, ServerCallbacks? callbacks) async {
  if (request.method == "POST") {
    return handlePost(request, callbacks: callbacks);
  }

  return Response(404);
}

Future<Response> handlePost(
  Request request, {
  ServerCallbacks? callbacks,
}) async {
  final clientAddress =
      (request.context['shelf.io.connection_info'] as HttpConnectionInfo?)
          ?.remoteAddress
          .address;
  if (clientAddress == null) {
    return Response(400, body: "Client Address Can't be found");
  }

  switch (request.url.path) {
    case "file":
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

        final uniqueName = request.headers['x-sharem-unique-name'];
        final uniqueCode = request.headers['x-sharem-unique-code'];

        if ((uniqueName == null || uniqueCode == null) ||
            (uniqueName.isEmpty || uniqueCode.isEmpty)) {
          return Response(400,
              body:
                  "Missing x-sharem-unique-name or x-sharem-unique-code headers");
        }

        if (null != callbacks) {
          await callbacks.onFileCallback(
              uniqueName,
              uniqueCode,
              SharemFile.fromStream(
                  fileName, request.read(), contentLengthInBytes));
        }

        return Response(200);
      }

    case "text":
      {
        final uniqueName = request.headers['x-sharem-unique-name'];
        if (uniqueName == null || uniqueName.isEmpty) {
          return Response(400, body: 'missing x-sharem-unique-name header');
        }
        final body = await request.readAsString();
        if (callbacks != null) {
          await callbacks.onTextCallback(
              uniqueName, InternetAddress(clientAddress), body);
        }
        return Response(200);
      }

    case "files":
      {
        final body = await request.readAsString();

        final fileRequest = SharemFileShareRequest.fromJSON(
            InternetAddress(clientAddress), body);

        if (null != callbacks) {
          if (await callbacks.onFileShareRequest(fileRequest)) {
            return Response(200, body: "Ready to accept these files");
          } else {
            return Response(403, body: "Rejected");
          }
        }

        return Response(503, body: "Unreachable");
      }

    default:
      return Response(404, body: "Invalid Path ${request.url.path}");
  }
}

bool isValidFileName(String fileName) {
  return !fileName.contains(RegExp(r'[\\/]'));
}

class SharemFileShareRequest {
  final String uniqueName;
  final InternetAddress address;
  final Map<String, int> fileNameAndLength;
  final String uniqueCode;

  const SharemFileShareRequest(
      this.uniqueName, this.address, this.fileNameAndLength, this.uniqueCode);

  factory SharemFileShareRequest.fromJSON(
      InternetAddress address, String body) {
    final map = Map<String, dynamic>.from(json.decode(body));
    assert(map['version'] == protocolVersion);
    return SharemFileShareRequest(map['uniqueName'], address,
        Map<String, int>.from(map['files']), map['uniqueCode']);
  }

  String toJSON() {
    return json.encode({
      'uniqueName': uniqueName,
      'files': fileNameAndLength,
      'version': protocolVersion,
      'uniqueCode': uniqueCode,
    });
  }
}

const protocolVersion = "sharem-0.0.1";

class SharemPeerMessage {
  final int port;
  final String uniqueName;
  final String uniqueHash;

  SharemPeerMessage(this.port, this.uniqueName, this.uniqueHash);

  String toJSON() {
    return json.encode({
      'version': protocolVersion,
      'port': port,
      'uniqueName': uniqueName,
      'uniqueHash': uniqueHash,
    });
  }

  factory SharemPeerMessage.fromJSON(String s) {
    final map = Map<String, dynamic>.from(json.decode(s));
    if (map['version'] != protocolVersion) {
      throw ("Invalid Protocol Version expected $protocolVersion received ${map['version']}");
    }

    return SharemPeerMessage(map['port'], map['uniqueName'], map['uniqueHash']);
  }
}

enum ShareType {
  file,
  files,
  text,
}

class SharemPeer {
  final InternetAddress address;
  final int port;
  final String uniqueName;
  final String uniqueHash;

  SharemPeer({
    required this.address,
    required this.port,
    required this.uniqueName,
    required this.uniqueHash,
  });

  static Future<SharemPeer> initalize(
      {String? myName, String? uniqueHash, ServerCallbacks? callbacks}) async {
    final server = await startHttpServer(0, callbacks: callbacks);
    return SharemPeer(
      port: server.port,
      address: server.address,
      uniqueName: myName ?? generateUniqueName(),
      uniqueHash: uniqueHash ?? myHash,
    );
  }

  factory SharemPeer.fromMessage(
      SharemPeerMessage message, InternetAddress address) {
    return SharemPeer(
        address: address,
        port: message.port,
        uniqueName: message.uniqueName,
        uniqueHash: message.uniqueHash);
  }

  SharemPeerMessage toMessage() {
    return SharemPeerMessage(port, uniqueName, uniqueHash);
  }

  Uri buildUri(ShareType shareType, [String? fileName]) {
    switch (shareType) {
      case ShareType.file:
        final url = "http://${address.host}:$port/file?fileName=$fileName";
        if (fileName == null || !isValidFileName(fileName)) {
          throw Exception(
              "Filename is empty or invalid for ShareType.File $url");
        }

        return Uri.parse(url);

      case ShareType.text:
        return Uri.parse("http://${address.host}:$port/text");
      case ShareType.files:
        return Uri.parse("http://${address.host}:$port/files");
    }
  }

  Future<void> sendText(String myUniqueName, String text) async {
    final headers = <String, String>{};
    headers['x-sharem-unique-name'] = myUniqueName;
    final response =
        await http.post(buildUri(ShareType.text), body: text, headers: headers);
    final body = response.body;
    if (response.statusCode != 200) {
      throw Exception("Response ${response.statusCode} $body");
    }
  }

  Future<void> sendFile(
      String myUniqueName, String myUniqueCode, SharemFile file,
      {ProgressCallback progressCallback = emptyProgressCallback}) async {
    final headers = <String, String>{};
    headers['content-length'] = (await file.fileLength()).toString();
    headers['x-sharem-unique-name'] = myUniqueName;
    headers['x-sharem-unique-code'] = myUniqueCode;
    final uri = buildUri(ShareType.file, file.fileName);
    final request = http.StreamedRequest("POST", uri);
    request.headers.addAll(headers);
    request.sink
        .addStream(file.asStream(progressCallback: progressCallback))
        .then((_) => request.sink.close());

    final response = await request.send();
    final body = String.fromCharCodes(await response.stream.toBytes());
    log("Send File $uri Response ${response.statusCode} $body");
    if (response.statusCode != 200) {
      throw Exception("Response ${response.statusCode} $body");
    }
  }

  Future<void> sendFiles(String myUniqueName, List<SharemFile> files,
      {void Function(String fileName, Progress progress)? progressCallback,
      String? uniqueCode}) async {
    {
      for (final file in files) {
        if (!isValidFileName(file.fileName)) {
          throw Exception(
              "File can be rejected because of the file name '${file.fileName}' ");
        }
      }

      final map = Map.fromEntries(await Future.wait(
          files.map((e) async => MapEntry(e.fileName, await e.fileLength()))));

      uniqueCode ??= generateUniqueCode();
      final payload = SharemFileShareRequest(
        myUniqueName,
        InternetAddress.anyIPv4,
        map,
        uniqueCode,
      ).toJSON();

      final uri = buildUri(ShareType.files);
      final response = await http.post(uri, body: payload);

      final body = response.body;
      if (response.statusCode != 200) {
        // Rejected
        throw Exception("Response ${response.statusCode} $body");
      }
      // Accepted

      await Future.wait(files.map((e) => sendFile(myUniqueName, uniqueCode!, e,
          progressCallback: progressCallback == null
              ? emptyProgressCallback
              : (progress) => progressCallback(e.fileName, progress))));
    }
  }
}

class PeerState {
  final SharemPeer selfPeer;

  PeerState._(this.selfPeer);

  static Future<PeerState> initalize(InternetAddress broadcastAddress,
      {String? myName, ServerCallbacks? callbacks}) async {
    final selfPeer =
        await SharemPeer.initalize(callbacks: callbacks, myName: myName);
    final payload = selfPeer.toMessage().toJSON();
    startBroadcasting(broadcastAddress, payload, const Duration(seconds: 1));
    final state = PeerState._(selfPeer);
    return state;
  }
}

class PeerGatherer {
  final Map<String, SharemPeer> _peers = {};
  StreamSubscription? _subscription;
  PeerGatherer();

  void startGathering([void Function(SharemPeer)? callback]) {
    _subscription = listenForPeers().listen((peer) {
      if (_peers[peer.uniqueName.toLowerCase()] == null) {
        if (callback != null) {
          callback(peer);
        }
      }
      _peers[peer.uniqueName.toLowerCase()] = peer;
    });
  }

  SharemPeer? getPeerByName(String name) {
    return _peers[name.toLowerCase()];
  }

  get length => _peers.length;

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}

// final _logFile =
//     File("/tmp/sharem_cli-${DateTime.now().millisecondsSinceEpoch}.log")
//         .openWrite();
void log(String s) {
  // _logFile.writeln(s);
}

Future<void> flushLog() async {
  // await _logFile.flush();
  // await _logFile.close();
}

String formatBytes(int n, [int fixed = 2]) {
  const kilo = 1000;
  const mega = 1000 * kilo;
  const giga = 1000 * mega;
  const tera = 1000 * giga;

  if (n < kilo) {
    return "${n}B";
  }

  if (n < mega) {
    return "${(n / kilo).toStringAsFixed(fixed)}KB";
  }

  if (n < giga) {
    return "${(n / mega).toStringAsFixed(fixed)}MB";
  }

  if (n < tera) {
    return "${(n / giga).toStringAsFixed(fixed)}GB";
  }

  return "${(n / tera).toStringAsFixed(fixed)}TB";
}

class Progress {
  int bytesTransferred;
  final int totalBytes;

  Progress(this.totalBytes, [this.bytesTransferred = 0]);

  Progress addProgress(int bytes) {
    assert(bytesTransferred + bytes <= totalBytes);
    bytesTransferred += bytes;
    return Progress(totalBytes, bytesTransferred);
  }

  String toPrettyString() {
    return "${formatBytes(bytesTransferred)}/${formatBytes(totalBytes)} ${(100 * bytesTransferred / totalBytes).toStringAsFixed(2)} %";
  }

  bool isComplete() {
    return bytesTransferred == totalBytes;
  }

  setProgress(int bytesTransferred) {
    this.bytesTransferred = bytesTransferred;
  }
}

String generateUniqueCode([int length = 6]) {
  var s = '';

  final rng = Random();
  for (var i = 0; i < length; i++) {
    s += rng.nextInt(10).toString();
  }

  return s;
}
