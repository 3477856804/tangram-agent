import 'package:flutter/material.dart';
import 'package:tangram/app_version.dart';

import '../design/dsh_tokens.dart';
import '../harness/ui_customization.dart' show UiCustomizationConfig;
import 'app_config.dart';
import 'flows/sidebar/settings_config.dart';
import 'flows/chat/chat_experience_config.dart';
import 'flows/sidebar/sidebar_config.dart';
import 'flows/workspace/workspace_sections.dart';
import 'providers/ai_provider.dart';
import 'providers/local_voice_provider.dart';
import 'providers/openai_compatible_voice_provider.dart';
import 'providers/speech_voice_provider.dart';
import 'providers/storage_provider.dart';
import 'providers/tangram_auth_provider.dart';
import 'providers/voice_credentials.dart';
import 'providers/voice_provider.dart';
import 'providers/voice_provider_registry.dart';
import '../services/secret_vault.dart';
import 'widgets/tangram_surfaces.dart';

/// 主页顶栏「静音」开关（设计稿 2026-11-13：白底圆形按钮，与顶栏其他按钮同构）。
/// 仅本地 UI 态，切换图标；不谎称已关闭系统音量。
class _MuteAction extends StatefulWidget {
  const _MuteAction();
  @override
  State<_MuteAction> createState() => _MuteActionState();
}

class _MuteActionState extends State<_MuteAction> {
  bool _muted = false;
  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Tooltip(
      message: _muted ? '取消静音' : '静音',
      child: InkWell(
        onTap: () => setState(() => _muted = !_muted),
        customBorder: const CircleBorder(),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: c.inputMajor,
            shape: BoxShape.circle,
            boxShadow: dshSoftShadow(blur: 10, lift: 2, alpha: 0.05),
          ),
          alignment: Alignment.center,
          child: Icon(
            _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            size: 18,
            color: c.labelPrimary,
          ),
        ),
      ),
    );
  }
}

AppScaffoldConfig buildTangramConfig({
  required AiProvider aiProvider,
  required StorageProvider storageProvider,
  // 由 main.dart 从后端 model_route{list} 拉取真实模型卡；没有模型就是空列表，
  // 不再预置「我训练的模型 / 本地基底 / API 教师」这类编造条目。
  List<ModelOption> availableModels = const <ModelOption>[],
  // UI 自定义的可见导航项；null / 空集合 = 全部入口（配置缺失时不缩减侧栏）。
  List<String>? visibleNavKeys,
  // Kokoro 本地 TTS（OpenAI 兼容协议）：默认关闭。不传 kokoroBaseUrl
  // 时与以前完全一致；传了也仍默认本地 Edge TTS，只有同时传
  // preferredVoiceBackend 为 VoiceProviderKind.openAiCompatible 时
  // 才切到 Kokoro（见 _resolveVoiceProvider）。密钥走安全存储
  // （voiceCredentials 未传时用 FlutterSecretVault），Kokoro 本地
  // 服务通常无密钥，无密钥时请求不带 Authorization 头。
  // 不新增操作页面：开关与地址目前只走本函数参数（调用方传入），
  // UI 设置入口待以后接现有语音/模型配置页时再加。
  String? kokoroBaseUrl,
  String kokoroTtsVoice = OpenAiCompatibleVoiceProvider.kokoroDefaultVoice,
  String kokoroTtsModel = OpenAiCompatibleVoiceProvider.kokoroDefaultModel,
  VoiceCredentials? voiceCredentials,
  VoiceProviderKind preferredVoiceBackend = VoiceProviderKind.local,
}) => AppScaffoldConfig(
  authProvider: TangramLocalAuthProvider(),
  aiProvider: aiProvider,
  storageProvider: storageProvider,
  // 语音输入：默认本地后端（LocalVoiceProvider）——STT 仍走平台语音识别
  // （speech_to_text）真实实现，TTS 补上已实测的 Edge TTS；注入后 app_router
  // 自动启用 enableVoice，麦克风按钮、录音波形（真实声级）、转写全部生效。
  // 云端后端（OpenAI 兼容 / ElevenLabs）由 VoiceProviderRegistry 切换，
  // 未配置密钥时诚实报未配置、不伪造成功；Kokoro 本地 TTS 见上方
  // kokoroBaseUrl / preferredVoiceBackend 参数（默认关闭）。
  voiceProvider: _resolveVoiceProvider(
    kokoroBaseUrl: kokoroBaseUrl,
    kokoroTtsVoice: kokoroTtsVoice,
    kokoroTtsModel: kokoroTtsModel,
    voiceCredentials: voiceCredentials,
    preferredVoiceBackend: preferredVoiceBackend,
  ),
  // Keep the Flai theme unset so FlaiApp resolves it from the active theme mode.
  // 应用显示名：产品名 tangram-agent 的简称，短到 Android 启动器不会截断。
  // 产品全称仍为 tangram-agent（见「关于」区），版本取单一真源 kAppVersion。
  appTitle: 'TGA',
  showSplash: false,
  onboardingConfig: null,
  chatExperienceConfig: ChatExperienceConfig(
    assistantName: '我的 Agent',
    // 设计稿 2026-11-12：居中问候语改为完整一句。
    greeting: '你好，有什么我能帮你的吗？',
    greetingSubtitle: '',
    composerPlaceholder: '输入消息，/ 查看指令',
    enableGhostMode: true,
    enablePerMessageModelSwitch: true,
    availableModels: availableModels,
  ),
  settingsConfig: const SettingsConfig(
    drawerHeightRatio: 0.62,
    appVersion: kAppVersion,
    sections: <SettingsSection>[
      SettingsSection(
        title: '外观',
        rows: <SettingsRow>[
          InfoRow(label: '主题', value: '在「设置 · 语言与主题」中配置'),
          InfoRow(label: '正文', value: '跟随应用主题'),
        ],
      ),
      SettingsSection(
        title: '关于',
        rows: <SettingsRow>[
          InfoRow(label: '产品', value: 'tangram-agent'),
          InfoRow(label: '内核', value: 'agent = model + harness'),
          InfoRow(label: '版本', value: kAppVersion),
          InfoRow(label: '能力', value: '工作蒸馏 · 产出私人模型'),
        ],
      ),
    ],
  ),
  sidebarConfig: SidebarConfig(
    appName: 'TGA',
    appLogo: const BrandMark(size: 36),
    // 精简入口：认知 / 界面创客 / 界面自定义 / UI 插件槽 / 算力调度 /
    // 性能诊断等元功能默认不进侧栏（页面与能力代码保留）。仅当 visibleNavKeys
    // 是「用户显式指定的子集」时才尊重；全量默认集则剔除这些元功能。
    navItems: buildWorkspaceNavItems(visibleKeys: visibleNavKeys)
        .where(
          (NavItem item) =>
              visibleNavKeys != null &&
              visibleNavKeys.isNotEmpty &&
              visibleNavKeys.length < UiCustomizationConfig.knownNavKeys.length
              ? true
              : !UiCustomizationConfig.defaultHiddenNavKeys.contains(
                  item.labelKey,
                ),
        )
        .toList(growable: false),
    enableSearch: true,
    // 设计稿 2026-11-12 主页顶栏：菜单 · 静音 · 新对话加号。
    // 菜单与新对话由 HomeScreen 自身渲染，这里补「静音」开关。
    topNavActions: <Widget>[_MuteAction()],
  ),
);

/// 解析语音后端：默认本地（STT 平台识别 + Edge TTS），行为不变。
/// kokoroBaseUrl 非空时把 Kokoro 后端构造并注册进注册表；是否启用
/// 由 preferredVoiceBackend 决定，未传 Kokoro 地址时传
/// openAiCompatible 也会被忽略、留在本地。
/// 同步构造期不做异步自检：Kokoro 自检只查 baseUrl 在位、无密钥也
/// 通过；服务未起时首次合成/转写如实抛错，不伪装可用。
VoiceProvider _resolveVoiceProvider({
  String? kokoroBaseUrl,
  required String kokoroTtsVoice,
  required String kokoroTtsModel,
  VoiceCredentials? voiceCredentials,
  required VoiceProviderKind preferredVoiceBackend,
}) {
  final VoiceProvider local = LocalVoiceProvider(
    stt: SpeechToTextVoiceProvider(),
  );
  final String kokoroUrl = (kokoroBaseUrl ?? '').trim();
  if (kokoroUrl.isEmpty) return local;
  final VoiceProviderRegistry voiceRegistry = VoiceProviderRegistry();
  voiceRegistry.register(local);
  final OpenAiCompatibleVoiceProvider kokoro =
      voiceRegistry.registerKokoro(
    credentials:
        voiceCredentials ?? VoiceCredentials(const FlutterSecretVault()),
    baseUrl: kokoroUrl,
    ttsModel: kokoroTtsModel,
    ttsVoice: kokoroTtsVoice,
  );
  if (preferredVoiceBackend == VoiceProviderKind.openAiCompatible) {
    return kokoro;
  }
  return local;
}
