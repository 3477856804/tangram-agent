/// 通话记录服务：把纯 Dart 仓储绑定到 App 私有存储目录。

import 'call_store.dart';
import 'store.dart';

export 'call_store.dart';

class CallService extends CallStore {
  CallService(HarnessStore store) : super(store.root);
}
