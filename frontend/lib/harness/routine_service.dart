/// Routine 服务层：把纯 Dart 仓储绑定到 App 私有存储目录。
///
/// 与 PagesService 同样的分层：`RoutineStore` 可独立单测，
/// `RoutineService` 只负责注入 [HarnessStore.root]。

import 'routine_store.dart';
import 'store.dart';

export 'routine_store.dart';
export 'routine_schedule.dart';

class RoutineService extends RoutineStore {
  RoutineService(HarnessStore store) : super(store.root);
}
