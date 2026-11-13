/// TGA 内置三语词典（简体中文 /繁體中文 / English）。
///
/// 轻量实现：key→三语 Map + [BuildContext] 扩展 `context.t(key)`，
/// 不引 gen-l10n 重型工具链。语言真源是 PersonaStore.language，
/// [TgaL10n.localeOf] 把它映射为 MaterialApp.locale，同时驱动
/// 系统组件（时间/日期选择器等）经 flutter_localizations 本地化。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

class TgaL10n {
  TgaL10n._();

  static const List<LocalizationsDelegate<dynamic>> delegates =
      <LocalizationsDelegate<dynamic>>[
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    _TgaDictDelegate(),
  ];

  static const List<Locale> supported = <Locale>[
    Locale('zh', 'CN'),
    Locale('zh', 'TW'),
    Locale('en'),
  ];

  /// PersonaStore.language（简体中文/繁體中文/English）→ Locale。
  static Locale localeOf(String language) => switch (language) {
        '繁體中文' => const Locale('zh', 'TW'),
        'English' => const Locale('en'),
        _ => const Locale('zh', 'CN'),
      };

  /// 当前激活语言（由 [_TgaLocalizations] 加载时同步，供 Tga 组件与
  /// 非 Widget 代码读取）。
  static String activeLanguage = '简体中文';
}

/// 词典本地化实例：加载时把语言写入 [TgaL10n.activeLanguage]，
/// 让不经过 context 的代码也能取到当前语言文案。
class _TgaLocalizations {
  _TgaLocalizations(this.locale) {
    TgaL10n.activeLanguage = switch (locale.languageCode +
        (locale.countryCode ?? '')) {
      'zhTW' => '繁體中文',
      'en' => 'English',
      _ => '简体中文',
    };
  }
  final Locale locale;
  String t(String key, {String? zh}) {
    final Map<String, String>? row = TgaStrings.table[key];
    if (row == null) return zh ?? key;
    return switch (locale.languageCode + (locale.countryCode ?? '')) {
      'zhTW' => row['tw'] ?? row['cn']!,
      'en' => row['en'] ?? row['cn']!,
      _ => row['cn']!,
    };
  }
}

class _TgaDictDelegate
    extends LocalizationsDelegate<_TgaLocalizations> {
  const _TgaDictDelegate();
  @override
  bool isSupported(Locale locale) =>
      <String>['zh', 'en'].contains(locale.languageCode);
  @override
  Future<_TgaLocalizations> load(Locale locale) async =>
      _TgaLocalizations(locale);
  @override
  bool shouldReload(_TgaDictDelegate old) => false;
}

/// 推荐用法：`context.t('settings.title')`。
extension TgaT on BuildContext {
  String t(String key, {String? zh}) {
    final _TgaLocalizations? loc =
        Localizations.of<_TgaLocalizations>(this, _TgaLocalizations);
    if (loc != null) return loc.t(key, zh: zh);
    return zh ?? TgaStrings.table[key]?['cn'] ?? key;
  }
}

/// key → {cn, tw, en}。覆盖高频界面：侧边栏/首页/设置/个人/
/// 工作台页标题/通用按钮与状态词。
class TgaStrings {
  TgaStrings._();

  static const Map<String, Map<String, String>> table =
      <String, Map<String, String>>{
    // ---- 通用 ----
    'common.cancel': {'cn': '取消', 'tw': '取消', 'en': 'Cancel'},
    'common.ok': {'cn': '确定', 'tw': '確定', 'en': 'OK'},
    'common.save': {'cn': '保存', 'tw': '儲存', 'en': 'Save'},
    'common.delete': {'cn': '删除', 'tw': '刪除', 'en': 'Delete'},
    'common.add': {'cn': '添加', 'tw': '新增', 'en': 'Add'},
    'common.close': {'cn': '关闭', 'tw': '關閉', 'en': 'Close'},
    'common.refresh': {'cn': '刷新', 'tw': '重新整理', 'en': 'Refresh'},
    'common.retry': {'cn': '重试', 'tw': '重試', 'en': 'Retry'},
    'common.later': {'cn': '以后再说', 'tw': '以後再說', 'en': 'Later'},
    'common.download': {'cn': '立即下载', 'tw': '立即下載', 'en': 'Download'},
    'common.install': {'cn': '安装', 'tw': '安裝', 'en': 'Install'},
    'common.enabled': {'cn': '已启用', 'tw': '已啟用', 'en': 'Enabled'},
    'common.disabled': {'cn': '已停用', 'tw': '已停用', 'en': 'Disabled'},
    'common.connected': {'cn': '已连接', 'tw': '已連線', 'en': 'Connected'},
    'common.disconnected': {'cn': '未连接', 'tw': '未連線', 'en': 'Disconnected'},
    'common.connecting': {'cn': '连接中', 'tw': '連線中', 'en': 'Connecting'},
    // ---- 首页问候 ----
    'home.greet.night': {'cn': '夜深了，我能帮你做什么？', 'tw': '夜深了，我能幫你做什麼？', 'en': 'Late night — how can I help?'},
    'home.greet.early': {'cn': '早上好，我能帮你做什么？', 'tw': '早上好，我能幫你做什麼？', 'en': 'Good morning. How can I help?'},
    'home.greet.am': {'cn': '上午好，我能帮你做什么？', 'tw': '上午好，我能幫你做什麼？', 'en': 'Good morning. How can I help?'},
    'home.greet.noon': {'cn': '中午好，我能帮你做什么？', 'tw': '中午好，我能幫你做什麼？', 'en': 'Good noon. How can I help?'},
    'home.greet.afternoon': {'cn': '下午好，我能帮你做什么？', 'tw': '下午好，我能幫你做什麼？', 'en': 'Good afternoon. How can I help?'},
    'home.greet.evening': {'cn': '晚上好，我能帮你做什么？', 'tw': '晚上好，我能幫你做什麼？', 'en': 'Good evening. How can I help?'},
    'home.inputHint': {'cn': '给 TGA 发送消息…', 'tw': '給 TGA 傳送訊息…', 'en': 'Message TGA…'},
    'home.deepThink': {'cn': '深度思考', 'tw': '深度思考', 'en': 'Deep Think'},
    'home.smartSearch': {'cn': '智能搜索', 'tw': '智慧搜尋', 'en': 'Smart Search'},
    'home.engine': {'cn': 'TGA 引擎', 'tw': 'TGA 引擎', 'en': 'TGA Engine'},
    // ---- 侧边栏 ----
    'sidebar.newChat': {'cn': '新对话', 'tw': '新對話', 'en': 'New Chat'},
    'sidebar.training': {'cn': '训练设置', 'tw': '訓練設定', 'en': 'Training'},
    'sidebar.persona': {'cn': '人格设置', 'tw': '人格設定', 'en': 'Persona'},
    'sidebar.sandbox': {'cn': '内置沙箱', 'tw': '內建沙箱', 'en': 'Sandbox'},
    'sidebar.store': {'cn': '模型商店', 'tw': '模型商店', 'en': 'Model Store'},
    'sidebar.plugins': {'cn': '插件社区', 'tw': '外掛社群', 'en': 'Plugins'},
    'sidebar.workspace': {'cn': '工作区域', 'tw': '工作區域', 'en': 'Workspace'},
    'sidebar.channels': {'cn': '更多通信', 'tw': '更多通訊', 'en': 'Channels'},
    'sidebar.models': {'cn': '模型管理', 'tw': '模型管理', 'en': 'Models'},
    'sidebar.graph': {'cn': '知识图谱', 'tw': '知識圖譜', 'en': 'Knowledge Graph'},
    'sidebar.settings': {'cn': '设置', 'tw': '設定', 'en': 'Settings'},
    'sidebar.profile': {'cn': '个人', 'tw': '個人', 'en': 'Profile'},
    // ---- 页面标题 ----
    'settings.title': {'cn': '设置', 'tw': '設定', 'en': 'Settings'},
    'profile.title': {'cn': '个人', 'tw': '個人', 'en': 'Profile'},
    'channels.title': {'cn': '更多通信', 'tw': '更多通訊', 'en': 'Channels'},
    'store.title': {'cn': '模型商店', 'tw': '模型商店', 'en': 'Model Store'},
    'plugins.title': {'cn': '插件社区', 'tw': '外掛社群', 'en': 'Plugin Community'},
    'sandbox.title': {'cn': '内置沙箱', 'tw': '內建沙箱', 'en': 'Built-in Sandbox'},
    'workspace.title': {'cn': '工作区域', 'tw': '工作區域', 'en': 'Workspace'},
    'graph.title': {'cn': '知识图谱', 'tw': '知識圖譜', 'en': 'Knowledge Graph'},
    'training.title': {'cn': '训练设置', 'tw': '訓練設定', 'en': 'Training Settings'},
    'persona.title': {'cn': '人格设置', 'tw': '人格設定', 'en': 'Persona Settings'},
    'models.title': {'cn': '模型管理', 'tw': '模型管理', 'en': 'Model Manager'},
    // ---- 设置页 ----
    'settings.general': {'cn': '通用设置', 'tw': '通用設定', 'en': 'General'},
    'settings.notifications': {'cn': '消息通知', 'tw': '訊息通知', 'en': 'Notifications'},
    'settings.notificationsSub': {'cn': '接收 Agent 任务完成提醒', 'tw': '接收 Agent 任務完成提醒', 'en': 'Agent task-completion alerts'},
    'settings.language': {'cn': '语言', 'tw': '語言', 'en': 'Language'},
    'settings.voice': {'cn': '音色设置', 'tw': '音色設定', 'en': 'Voice'},
    'settings.theme': {'cn': '颜色模式', 'tw': '顏色模式', 'en': 'Appearance'},
    'settings.themeSystem': {'cn': '跟随系统', 'tw': '跟隨系統', 'en': 'System'},
    'settings.themeLight': {'cn': '浅色', 'tw': '淺色', 'en': 'Light'},
    'settings.themeDark': {'cn': '深色', 'tw': '深色', 'en': 'Dark'},
    'settings.modelService': {'cn': '模型与服务', 'tw': '模型與服務', 'en': 'Models & Services'},
    'settings.defaultModel': {'cn': '默认模型', 'tw': '預設模型', 'en': 'Default Model'},
    'settings.apiService': {'cn': 'API 服务', 'tw': 'API 服務', 'en': 'API Service'},
    'settings.onDevice': {'cn': '端侧推理', 'tw': '端側推理', 'en': 'On-device Inference'},
    'settings.data': {'cn': '数据设置', 'tw': '資料設定', 'en': 'Data'},
    'settings.localData': {'cn': '本地数据', 'tw': '本機資料', 'en': 'Local Data'},
    'settings.checkUpdate': {'cn': '检查更新', 'tw': '檢查更新', 'en': 'Check for Updates'},
    'settings.clearCache': {'cn': '清理缓存', 'tw': '清理快取', 'en': 'Clear Cache'},
    'settings.about': {'cn': '关于', 'tw': '關於', 'en': 'About'},
    'settings.version': {'cn': '版本', 'tw': '版本', 'en': 'Version'},
    'settings.sponsor': {'cn': '赞助', 'tw': '贊助', 'en': 'Sponsor'},
    'settings.latest': {'cn': '已是最新版本', 'tw': '已是最新版本', 'en': 'Up to date'},
    'settings.newVersion': {'cn': '发现新版本', 'tw': '發現新版本', 'en': 'New version'},
    'settings.downloadUpdate': {'cn': '下载更新', 'tw': '下載更新', 'en': 'Downloading'},
    'settings.tagline': {'cn': 'Tangram Agent · 让每个人拥有自己的模型', 'tw': 'Tangram Agent · 讓每個人擁有自己的模型', 'en': 'Tangram Agent · Your own model for everyone'},
    // ---- 个人页 ----
    'profile.diary': {'cn': '我的日记', 'tw': '我的日記', 'en': 'My Diary'},
    'profile.works': {'cn': '我的作品', 'tw': '我的作品', 'en': 'My Works'},
    'profile.agents': {'cn': '智能体中心', 'tw': '智慧體中心', 'en': 'Agents'},
    'profile.messages': {'cn': '消息中心', 'tw': '訊息中心', 'en': 'Messages'},
    'profile.tasks': {'cn': '定时任务', 'tw': '定時任務', 'en': 'Scheduled Tasks'},
    // ---- 通信页 ----
    'channels.authorize': {'cn': '去授权', 'tw': '去授權', 'en': 'Authorize'},
    'channels.qrExpiry': {'cn': '二维码 5 分钟内有效', 'tw': 'QR Code 5 分鐘內有效', 'en': 'QR code valid for 5 minutes'},
    'channels.newCode': {'cn': '要新码', 'tw': '要新碼', 'en': 'New code'},
    // ---- 侧边栏（问题#11 收尾：抽屉/会话行） ----
    'sidebar.collapse': {'cn': '收起', 'tw': '收起', 'en': 'Collapse'},
    'sidebar.more': {'cn': '更多…', 'tw': '更多…', 'en': 'More…'},
    'sidebar.conversations': {'cn': '会话', 'tw': '對話', 'en': 'Chats'},
    'sidebar.search': {'cn': '搜索会话', 'tw': '搜尋對話', 'en': 'Search chats'},
    'sidebar.starred': {'cn': '已收藏', 'tw': '已收藏', 'en': 'Starred'},
    'sidebar.empty': {'cn': '还没有会话', 'tw': '還沒有對話', 'en': 'No chats yet'},
    'sidebar.noMatch': {'cn': '没有匹配“{q}”的会话', 'tw': '沒有匹配「{q}」的對話', 'en': 'No chats matching "{q}"'},
    'sidebar.justNow': {'cn': '刚刚', 'tw': '剛剛', 'en': 'Just now'},
    'sidebar.unitMinute': {'cn': '分钟', 'tw': '分鐘', 'en': 'm'},
    'sidebar.unitHour': {'cn': '小时', 'tw': '小時', 'en': 'h'},
    'sidebar.unitDay': {'cn': '天', 'tw': '天', 'en': 'd'},
    'sidebar.star': {'cn': '收藏', 'tw': '收藏', 'en': 'Star'},
    'sidebar.unstar': {'cn': '取消收藏', 'tw': '取消收藏', 'en': 'Unstar'},
    'sidebar.rename': {'cn': '重命名', 'tw': '重命名', 'en': 'Rename'},
    'sidebar.share': {'cn': '分享', 'tw': '分享', 'en': 'Share'},
    // ---- 首页输入区（composer） ----
    'home.listening': {'cn': '正在听…', 'tw': '正在聽…', 'en': 'Listening…'},
    'home.transcribing': {'cn': '识别中…', 'tw': '辨識中…', 'en': 'Transcribing…'},
    'home.stopRecording': {'cn': '停止录音', 'tw': '停止錄音', 'en': 'Stop recording'},
    'home.voiceInput': {'cn': '语音输入', 'tw': '語音輸入', 'en': 'Voice input'},
    'home.attach': {'cn': '添加附件', 'tw': '新增附件', 'en': 'Attach files'},
    'home.switchModelTooltip': {'cn': '切换模型（Ctrl + M）', 'tw': '切換模型（Ctrl + M）', 'en': 'Switch model (Ctrl + M)'},
    'home.switchModelSemantics': {'cn': '切换模型，快捷键 Ctrl 或 Command 加 M', 'tw': '切換模型，快捷鍵 Ctrl 或 Command 加 M', 'en': 'Switch model — press Ctrl or Command + M'},
    'home.ampPending': {'cn': '振幅未接入', 'tw': '振幅未接入', 'en': 'amplitude N/A'},
    'home.modelGroupBuiltin': {'cn': '内置', 'tw': '內建', 'en': 'Built-in'},
    'home.modelGroupCloud': {'cn': '云端模型（API）', 'tw': '雲端模型（API）', 'en': 'Cloud models (API)'},
    'home.modelGroupLocal': {'cn': '本地模型（权重）', 'tw': '本地模型（權重）', 'en': 'Local models (weights)'},
  };
}
