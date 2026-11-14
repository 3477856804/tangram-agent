/// 应用版本单一真源。
///
/// 构建时由 `--dart-define=TANGRAM_VERSION` 全平台注入，与 CI 标签、
/// pubspec version、Release tag、PackageInfo 保持一致；兜底值仅在未注入时生效。
/// 所有 UI 展示、能力协商、MCP 握手都引用本常量，避免散落的硬编码版本。
library;

const String kAppVersion = String.fromEnvironment(
  'TANGRAM_VERSION',
  defaultValue: '0.0.4',
);
