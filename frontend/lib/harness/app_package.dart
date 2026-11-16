/// Agent 应用市场（行业工作站模板）。
///
/// 应用包 = 人格预设 + 工作流 + 知识库模板 + 权限建议 + 默认模型组合。
/// 一键安装会真实创建工作流与知识库；人格预设返回给界面，由页面向
/// PersonaStore 写入。权限建议只做展示与记录，**不自动放宽**任何权限。
///
/// 没有支付系统，付费包只标记价格，不收款、不伪造购买状态。

import 'dart:convert';

import 'knowledge_base.dart';
import 'store.dart';
import 'workflow.dart';

class AppPackageService {
  AppPackageService(this.store, this.workflows, this.knowledge);

  final HarnessStore store;
  final WorkflowEngine workflows;
  final KnowledgeBase knowledge;

  static const String format = 'tga-app/1';

  Future<Map<String, dynamic>> handle(
      String action, Map<String, dynamic> p) async {
    switch (action) {
      case 'list':
        return <String, dynamic>{
          'ok': true,
          'installed': await store.readRecords('app_packages'),
          'templates': templates(),
          'payment_enabled': false,
        };
      case 'templates':
        return <String, dynamic>{'ok': true, 'templates': templates()};
      case 'install':
        return await _install(p['package']);
      case 'import':
        return await _install(p['json']);
      case 'export':
        return await _export(p);
      case 'delete':
        return await _delete(p);
      default:
        return <String, dynamic>{'ok': false, 'error': '未知应用市场动作：$action'};
    }
  }

  Future<Map<String, dynamic>> _install(dynamic raw) async {
    Map<String, dynamic>? pkg;
    try {
      if (raw is String) {
        final dynamic decoded = jsonDecode(raw);
        if (decoded is Map) {
          pkg = decoded.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
        }
      } else if (raw is Map) {
        pkg = Map<String, dynamic>.from(raw);
      }
    } on Object {
      return <String, dynamic>{'ok': false, 'error': '应用包 JSON 解析失败'};
    }
    if (pkg == null) {
      return <String, dynamic>{'ok': false, 'error': '缺少应用包'};
    }
    if ((pkg['format'] ?? '').toString() != format) {
      return <String, dynamic>{
        'ok': false,
        'error': '不支持的格式，需要 $format',
      };
    }
    final String name = (pkg['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '应用包名称不能为空'};
    }
    final List<Map<String, dynamic>> installed =
        await store.readRecords('app_packages');
    if (installed.any((Map<String, dynamic> e) => e['name'] == name)) {
      return <String, dynamic>{'ok': false, 'error': '已安装同名应用：$name'};
    }

    final List<String> workflowIds = <String>[];
    final List<String> knowledgeIds = <String>[];
    final List<String> errors = <String>[];
    final dynamic wfs = pkg['workflows'];
    if (wfs is List) {
      for (final dynamic rawWf in wfs) {
        if (rawWf is! Map) continue;
        final Map<String, dynamic> wf =
            Map<String, dynamic>.from(rawWf)..['id'] = '';
        final Map<String, dynamic> r =
            await workflows.handle('save', <String, dynamic>{'workflow': wf});
        if (r['ok'] == true && r['workflow'] is Map) {
          workflowIds.add((r['workflow'] as Map)['id'].toString());
        } else {
          errors.add('工作流「${wf['name']}」：${r['error'] ?? '创建失败'}');
        }
      }
    }
    final dynamic kbs = pkg['knowledge'];
    if (kbs is List) {
      for (final dynamic rawKb in kbs) {
        if (rawKb is! Map) continue;
        final Map<String, dynamic> kb = Map<String, dynamic>.from(rawKb);
        final String kbName = (kb['name'] ?? '知识库模板').toString();
        final Map<String, dynamic> created =
            await knowledge.handle('create', <String, dynamic>{
          'name': '$name · $kbName',
          'description': (kb['description'] ?? '').toString(),
        });
        if (created['ok'] != true) {
          errors.add('知识库「$kbName」：${created['error'] ?? '创建失败'}');
          continue;
        }
        final String kbId = (created['library'] as Map)['id'].toString();
        knowledgeIds.add(kbId);
        final dynamic docs = kb['documents'];
        if (docs is List) {
          for (final dynamic rawDoc in docs) {
            if (rawDoc is! Map) continue;
            final Map<String, dynamic> doc =
                Map<String, dynamic>.from(rawDoc);
            final Map<String, dynamic> ing =
                await knowledge.handle('ingest_text', <String, dynamic>{
              'library_id': kbId,
              'name': (doc['name'] ?? '文档').toString(),
              'text': (doc['text'] ?? '').toString(),
            });
            if (ing['ok'] != true) {
              errors.add('文档「${doc['name']}」：${ing['error'] ?? '入库失败'}');
            }
          }
        }
      }
    }

    final Map<String, dynamic> record = <String, dynamic>{
      'name': name,
      'version': (pkg['version'] ?? '1.0.0').toString(),
      'description': (pkg['description'] ?? '').toString(),
      'author': (pkg['author'] ?? 'unknown').toString(),
      'price': pkg['price'] is num ? pkg['price'] : 0,
      'currency': (pkg['currency'] ?? 'CNY').toString(),
      'tags': pkg['tags'] is List ? pkg['tags'] : <dynamic>[],
      'persona': pkg['persona'] is Map ? pkg['persona'] : <String, dynamic>{},
      'models': pkg['models'] is List ? pkg['models'] : <dynamic>[],
      'permissions': pkg['permissions'] is Map
          ? pkg['permissions']
          : <String, dynamic>{},
      'workflow_ids': workflowIds,
      'knowledge_ids': knowledgeIds,
      'package': pkg,
      'installed_at': DateTime.now().toIso8601String(),
      'errors': errors,
    };
    await store.insert('app_packages', record);
    return <String, dynamic>{
      'ok': errors.isEmpty,
      'installed': record,
      'workflow_ids': workflowIds,
      'knowledge_ids': knowledgeIds,
      'persona': record['persona'],
      'permissions_note': '权限建议仅记录，未自动放宽任何工具/文件权限；'
          '请在插件内核或沙箱策略中逐项确认。',
      'payment_note': '本版本未接入支付；付费标记仅展示，不产生扣款。',
      if (errors.isNotEmpty) 'errors': errors,
    };
  }

  Future<Map<String, dynamic>> _export(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    final List<Map<String, dynamic>> installed =
        await store.readRecords('app_packages');
    for (final Map<String, dynamic> e in installed) {
      if (e['id'].toString() == id) {
        final dynamic pkg = e['package'];
        return <String, dynamic>{
          'ok': true,
          'json': jsonEncode(pkg),
          'package': pkg,
        };
      }
    }
    return <String, dynamic>{'ok': false, 'error': '应用不存在'};
  }

  Future<Map<String, dynamic>> _delete(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    final List<Map<String, dynamic>> installed =
        await store.readRecords('app_packages');
    final int before = installed.length;
    installed.removeWhere((Map<String, dynamic> e) => e['id'].toString() == id);
    if (installed.length == before) {
      return <String, dynamic>{'ok': false, 'error': '应用不存在'};
    }
    await store.writeRecords('app_packages', installed);
    return <String, dynamic>{
      'ok': true,
      'deleted': id,
      'note': '仅移除安装记录；已创建的工作流与知识库保留，可手动删除。',
    };
  }

  /// 内置免费行业模板（可直接安装，不含编造的业务数据）。
  static List<Map<String, dynamic>> templates() => <Map<String, dynamic>>[
        <String, dynamic>{
          'format': format,
          'name': '内容创作工作站',
          'version': '1.0.0',
          'author': 'TGA 官方模板',
          'description': '选题 → 大纲 → 初稿 → 事实核查 → 定稿，内置编辑规范。',
          'price': 0,
          'currency': 'CNY',
          'tags': <String>['内容', '写作', '免费'],
          'persona': <String, dynamic>{
            'name': '内容搭档',
            'identity': '你是一名严谨的内容编辑，擅长把复杂信息讲清楚。',
            'personality': '先问清读者与目标，再动笔；事实与观点分层标注；不编造来源。',
            'audience': '为需要持续产出高质量内容的创作者服务。',
          },
          'models': <String>['按需选择云端或本地模型'],
          'permissions': <String, dynamic>{
            'tools': <String>['chat', 'read_file', 'write_file'],
            'files': <String>['sandbox/**'],
            'note': '默认仅允许工作区内读写；对外发布需人工确认。',
          },
          'workflows': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '内容生产流水线',
              'description': '把素材整理成可发布初稿',
              'steps': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': '选题澄清',
                  'type': 'prompt',
                  'input': '围绕主题「{{input}}」：先列出目标读者、核心观点、'
                      '需要核实的事实缺口，不要直接写稿。',
                  'save_as': 'brief',
                },
                <String, dynamic>{
                  'name': '大纲',
                  'type': 'prompt',
                  'input': '基于以下 brief 输出三级大纲，并标注每节需要的证据：\n{{brief}}',
                  'save_as': 'outline',
                },
                <String, dynamic>{
                  'name': '初稿',
                  'type': 'prompt',
                  'input': '按大纲写出初稿；事实、推测、建议分别标注。\n{{outline}}',
                  'save_as': 'draft',
                },
                <String, dynamic>{
                  'name': '事实核查',
                  'type': 'prompt',
                  'input': '逐条检查初稿中的事实陈述：哪些有依据、哪些需要补充来源、'
                      '哪些应降级为推测。\n{{draft}}',
                },
              ],
            },
          ],
          'knowledge': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '编辑规范',
              'description': '内容工作站的默认写作与核查规范',
              'documents': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': 'TGA 编辑规范',
                  'text': '1. 事实与观点必须分层：已核实事实直接陈述，推测写明前提，'
                      '建议标明是建议。\n'
                      '2. 不编造来源、链接、数据；没有检索结果就如实说明。\n'
                      '3. 复杂主题先给结论，再给必要依据。\n'
                      '4. 对外发布前必须人工确认；涉及版权、隐私、商业机密的内容拒绝生成。\n'
                      '5. 迭代交付：先框架，再初稿，再局部修改，不整体推倒重来。',
                },
              ],
            },
          ],
        },
        <String, dynamic>{
          'format': format,
          'name': '量化研究工作站',
          'version': '1.0.0',
          'author': 'TGA 官方模板',
          'description': '策略假设 → 数据检查 → 回测设计 → 风险审查；不承诺收益。',
          'price': 0,
          'currency': 'CNY',
          'tags': <String>['量化', '研究', '免费'],
          'persona': <String, dynamic>{
            'name': '量化研究员',
            'identity': '你是一名量化研究助手，只基于真实数据与可复现实验给出结论。',
            'personality': '拒绝收益承诺；先检查数据质量与过拟合风险；所有数值标注来源。',
            'audience': '为做策略研究与回测验证的个人研究者服务。',
          },
          'models': <String>['按需选择云端或本地模型'],
          'permissions': <String, dynamic>{
            'tools': <String>['chat', 'read_file', 'write_file'],
            'files': <String>['sandbox/**'],
            'note': '只做研究与模拟回测，不连接实盘下单。',
          },
          'workflows': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '策略研究检查',
              'description': '把策略想法拆成可验证的研究计划',
              'steps': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': '假设拆解',
                  'type': 'prompt',
                  'input': '把策略想法「{{input}}」拆成：市场假设、信号定义、'
                      '数据需求、失效条件。不要承诺收益。',
                  'save_as': 'plan',
                },
                <String, dynamic>{
                  'name': '风险清单',
                  'type': 'prompt',
                  'input': '基于以下研究计划列出过拟合、幸存者偏差、交易成本、'
                      '数据泄漏等风险与检查方法：\n{{plan}}',
                },
              ],
            },
          ],
          'knowledge': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '研究红线',
              'description': '量化研究必须遵守的合规与诚实边界',
              'documents': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': '量化研究红线',
                  'text': '1. 不承诺收益、不保证回测结果可复现到实盘。\n'
                      '2. 所有数值必须来自真实输入数据；数据不足时明确报错。\n'
                      '3. 回测需报告交易成本、滑点、样本外测试与参数敏感性。\n'
                      '4. 默认不接入自动实盘交易；如接入必须人工确认并留审计日志。\n'
                      '5. 风险提示与结论同时展示，不隐藏失败样本。',
                },
              ],
            },
          ],
        },
        <String, dynamic>{
          'format': format,
          'name': '视频剪辑工作站',
          'version': '1.0.0',
          'author': 'TGA 官方模板',
          'description': '素材检查 → 分镜脚本 → 粗剪 → 字幕/配乐 → 成片检查。',
          'price': 0,
          'currency': 'CNY',
          'tags': <String>['视频', '剪辑', '免费'],
          'persona': <String, dynamic>{
            'name': '剪辑搭档',
            'identity': '你是一名视频剪辑助手，熟悉 ffmpeg 与叙事节奏。',
            'personality': '先确认素材与目标时长，再给分镜；不虚构素材内容。',
            'audience': '为需要快速产出成片的创作者服务。',
          },
          'models': <String>['按需选择云端或本地模型'],
          'permissions': <String, dynamic>{
            'tools': <String>['chat', 'shell', 'read_file', 'write_file'],
            'files': <String>['sandbox/**'],
            'note': '仅允许读取工作区素材并写入成片目录。',
          },
          'workflows': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '成片生产流水线',
              'description': '检查 ffmpeg、生成分镜、真实拼接与导出',
              'steps': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': '环境检查',
                  'type': 'shell',
                  'input': 'command -v ffmpeg && ffmpeg -version | head -1',
                  'save_as': 'ffmpeg',
                },
                <String, dynamic>{
                  'name': '分镜脚本',
                  'type': 'prompt',
                  'input': '根据主题「{{input}}」与素材目录情况，给出 5 个镜头的'
                      '时长、画面、字幕与转场建议；不要编造不存在的素材。',
                  'save_as': 'storyboard',
                },
                <String, dynamic>{
                  'name': '导出提示',
                  'type': 'prompt',
                  'input': '基于分镜给出可直接执行的 ffmpeg 粗剪命令（使用真实路径占位），'
                      '并说明每个参数的作用。\n{{storyboard}}',
                },
              ],
            },
          ],
          'knowledge': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '剪辑规范',
              'description': '视频工作站的输出与合规规范',
              'documents': <Map<String, dynamic>>[
                <String, dynamic>{
                  'name': '剪辑输出规范',
                  'text': '1. 成片默认 1080p/30fps，H.264 + AAC，faststart。\n'
                      '2. 字幕必须与音频对齐；无法识别时如实说明，不生成假字幕。\n'
                      '3. 背景音乐需确认授权；未授权素材拒绝使用。\n'
                      '4. 发布前人工确认；不自动发布到账号。\n'
                      '5. 原始素材不删除，成片与工程文件回写工作区。',
                },
              ],
            },
          ],
        },
      ];
}
