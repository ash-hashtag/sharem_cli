import 'dart:io';

// const clearLine = '\x1B[2K\x1B[1G';
const clearLine = '\x1B[F\x1B[2K';
void main() async {
  const lineCount = 3;
  while (true) {
    for (int i = 0; i < lineCount; i++) {
      stdout.write("$i ${DateTime.now()}\n");
      await Future.delayed(Duration(seconds: 1));
    }

    for (int i = 0; i < lineCount; i++) {
      stdout.write(clearLine);
    }
  }
}
