/// Pages 应用层入口：把 HarnessStore 的根目录交给纯 Dart 仓储层。
///
/// `PagesRepository` 不依赖 Flutter，便于独立测试；App 内统一通过本类
/// 拿到真实 App 私有目录下的 `pages.json` 与 `pages/<id>/v<n>.html`。

import 'store.dart';
import 'pages_repository.dart';

export 'pages_repository.dart';

class PagesService extends PagesRepository {
  PagesService(HarnessStore store) : super(store.root);
}
