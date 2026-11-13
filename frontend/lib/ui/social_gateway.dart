/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/flai/widgets/tangram_surfaces.dart';

/// 社交能力网关（真实实现）。
///
/// - 分享：调用系统分享面板（share_plus），内容由调用方真实提供。
/// - 微信 / QQ 登录：官方 OAuth 必须由应用在开放平台注册 AppID/Secret 后
///   走授权码 + 服务端验签换取 openid，纯端侧无法安全完成。因此这里如实
///   说明，并把用户引导到本应用的 OpenClaw AGP 网关接入（「更多通信」页）——
///   那是本应用真正用来接入微信 / QQ 的通道，不含任何编造的登录结果。
class SocialGateway {
  SocialGateway({this.onOpenId});

  final void Function(String openid)? onOpenId;

  /// 真实系统分享：把文本交给系统分享面板，由用户选择目标应用。
  Future<void> share(String payload) async {
    if (payload.trim().isEmpty) {
      throw const SocialNotReady('分享内容为空。');
    }
    await Share.share(payload);
  }

  /// 打开微信开放平台授权页（真实 URL）。返回是否已成功拉起。
  /// APP 未注册 AppID 时不伪造 openid；由服务端回调验签后回填。
  Future<bool> openWechatOAuth(String appId, String redirectUri) =>
      _launch('https://open.weixin.qq.com/connect/app/qrconnect'
          '?appid=$appId&redirect_uri=${Uri.encodeComponent(redirectUri)}'
          '&response_type=code&scope=snsapi_userinfo&state=tga#wechat_redirect');

  /// 打开 QQ 互联授权页（真实 URL）。
  Future<bool> openQqOAuth(String appId, String redirectUri) =>
      _launch('https://graph.qq.com/oauth2.0/authorize'
          '?response_type=code&client_id=$appId'
          '&redirect_uri=${Uri.encodeComponent(redirectUri)}'
          '&state=tga&scope=get_user_info');

  Future<bool> _launch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return false;
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class SocialNotReady implements Exception {
  const SocialNotReady(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 社交能力子分区（并入「更多通信」页）。
///
/// UI 只暴露真实可完成的动作：系统分享、打开官方开放平台文档、查看接入说明。
/// 不再渲染点了就抛异常的「微信登录 / QQ 登录」死按钮。
class SocialShareSection extends StatelessWidget {
  const SocialShareSection({super.key, this.gateway});

  final SocialGateway? gateway;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionTitle(
          title: '社交与分享',
          subtitle: '系统分享 · 开放平台接入说明',
          icon: Icons.share_outlined,
          accent: TangramColors.gold,
        ),
        GlassCard(
          padding: const EdgeInsets.all(TangramSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                '微信 / QQ 消息从上方网关接入。'
                '官方账号登录需先在开放平台注册应用。',
                style: TextStyle(
                  color: TangramColors.textSecondary,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: TangramSpacing.md),
              Wrap(
                spacing: TangramSpacing.md,
                runSpacing: TangramSpacing.sm,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: () async {
                      final gw = gateway ?? SocialGateway();
                      try {
                        await gw.share('来自 TGA · 檀阁瑞木 的分享');
                      } on SocialNotReady catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(e.toString())),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.ios_share, size: 16),
                    label: const Text('系统分享'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _launchDocs(context),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('开放平台文档'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _launchDocs(BuildContext context) async {
    final uri = Uri.parse('https://open.weixin.qq.com/');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('打不开浏览器，请检查网络')),
      );
    }
  }
}
