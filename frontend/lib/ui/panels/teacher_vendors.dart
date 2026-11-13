/// 旧版面板:当前 App 无入口引用,保留备查。

library;

/// API 教师厂商预设。
///
/// 与 harness/teachers.py 的 ApiTeacher 契约一致：base_url / api_key / model
/// 三个参数决定一次真实调用。这里只提供国内常用大模型的预设值，
/// 新增厂商只需往 [kTeacherVendors] 追加一项，不需要改面板代码。
class TeacherVendor {
  const TeacherVendor({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.defaultModel,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String defaultModel;
}

const List<TeacherVendor> kTeacherVendors = <TeacherVendor>[
  TeacherVendor(
    id: 'deepseek',
    name: 'DeepSeek 深度求索',
    baseUrl: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-chat',
  ),
  TeacherVendor(
    id: 'qwen',
    name: '通义千问（阿里云）',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen-plus',
  ),
  TeacherVendor(
    id: 'glm',
    name: '智谱 GLM',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    defaultModel: 'glm-4-flash',
  ),
  TeacherVendor(
    id: 'moonshot',
    name: '月之暗面 Kimi',
    baseUrl: 'https://api.moonshot.cn/v1',
    defaultModel: 'moonshot-v1-8k',
  ),
  TeacherVendor(
    id: 'doubao',
    name: '字节豆包',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    defaultModel: 'doubao-pro-32k',
  ),
  TeacherVendor(
    id: 'ernie',
    name: '百度文心',
    baseUrl: 'https://qianfan.baisu.com/v2',
    defaultModel: 'ernie-4.0-8k',
  ),
  TeacherVendor(
    id: 'minimax',
    name: 'MiniMax',
    baseUrl: 'https://api.minimax.chat/v1',
    defaultModel: 'abab6.5s-chat',
  ),
  TeacherVendor(
    id: 'hunyuan',
    name: '腾讯混元',
    baseUrl: 'https://api.hunyuan.cloud.tencent.com/v1',
    defaultModel: 'hunyuan',
  ),
  TeacherVendor(
    id: 'custom',
    name: '自定义（OpenAI 兼容）',
    baseUrl: '',
    defaultModel: '',
  ),
];

TeacherVendor vendorById(String id) => kTeacherVendors.firstWhere(
      (TeacherVendor v) => v.id == id,
      orElse: () => kTeacherVendors.first,
    );
