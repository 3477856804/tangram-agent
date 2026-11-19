/// GGUF 权重文件头探测（纯 Dart，不依赖 llamadart native）。
///
/// 独立于推理引擎，便于在任意宿主（含 x64 CI）直接单测；
/// 加载大模型前先用它挡住「下载中断 / HTML 错误页 / 截断文件」，
/// 避免把损坏文件喂给 llama.cpp 后吐出一堆看不懂的 diagnostics。

import 'dart:io';

/// 字节序列是否为合法 GGUF 文件头（'GGUF' = 47 47 55 46）。
bool isGgufMagic(List<int> bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x47 &&
    bytes[1] == 0x47 &&
    bytes[2] == 0x55 &&
    bytes[3] == 0x46;

/// 读取文件头 4 字节校验 GGUF 魔数；返回 null 表示合法，否则返回可读错误。
Future<String?> checkGgufMagicFile(File f) async {
  try {
    final header = f.openSync(mode: FileMode.read);
    try {
      final magic = header.readSync(4);
      if (!isGgufMagic(magic)) {
        return '权重文件不是合法 GGUF（文件头不是 GGUF 魔数），'
            '通常是下载中断或下载到了错误页面，请删除后重新下载';
      }
    } finally {
      header.closeSync();
    }
  } on Object catch (e) {
    return '读取权重文件头失败：$e';
  }
  return null;
}
