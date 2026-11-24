#!/usr/bin/env node
// 0.0.41 一致性关卡（静态）：验证「设计里的执行点」确实在源码里。
// 这不是 flutter test 的替代品——它只回答一个问题：
// 每条能力声明，是否有一个能被 grep 到的执行点（防止「声明了但没接线」再次出现）。
// 运行：node tests/conformance_0_0_41.mjs

import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const kernel = read('frontend/lib/harness/plugin_kernel.dart');
const guard = read('frontend/lib/harness/kernel_guard.dart');
const tier = read('frontend/lib/harness/plugin_tier.dart');
const creator = read('frontend/lib/harness/creator_runtime.dart');
const backend = read('frontend/lib/harness/embedded_backend.dart');
const wasm = read('frontend/lib/harness/wasm_module.dart');
const runtimePy = read(
  ['backend', 'app', 'runtime', 'plugin' + '_runtime.py'].join('/'),
);

let pass = 0;
let fail = 0;
const check = (name, cond) => {
  if (cond) { pass++; console.log(`  ok   ${name}`); }
  else { fail++; console.error(`  FAIL ${name}`); }
};

console.log('G1 分级有执行点');
check('mount 拒绝 T3 无 caps', /plugin\.tier == PluginTier\.thirdParty && plugin\.caps\.isEmpty/.test(kernel));
check('creator 插件标 T2', /PluginTier get tier => PluginTier\.user/.test(creator));
check('python 清单 T3 fail-closed', /tier == "T3" and not caps/.test(runtimePy));
check('tier 解析与兜底', /static PluginTier parse\(/.test(tier));

console.log('G2 仲裁有执行点');
check('invoke 接收 caller/caps', /invoke\(String seamName, String method,[\s\S]{0,200}\{String caller = kRootCaller, List<String> caps/.test(kernel));
check('缺令牌即拒绝并发事件', /missing_caps/.test(kernel) && /seam\.denied/.test(kernel));
check('守卫可拒绝', /invokeGuard/.test(kernel) && /guard_rejected/.test(kernel));
check('默认高权限接缝要令牌', /core\/sandbox/.test(guard) && /sandbox:exec/.test(guard));
check('handle 透传 caller', /caller: \(p\['caller'\] \?\? kRootCaller\)/.test(kernel));

console.log('G3 拦截点');
check('InvokeGuard 类型存在', /typedef InvokeGuard/.test(guard));

console.log('G4 地址函数被真实调用');
check('mount 校验声明地址', /parsePluginAddress\(declaredAddress\)/.test(kernel));
check('地址非法即拒绝挂载', /地址非法/.test(kernel));

console.log('G5 内核态快照与回退');
check('captureSnapshot 存在', /captureSnapshot\(String label\)/.test(kernel));
check('restoreSnapshot 存在', /restoreSnapshot\(String id\)/.test(kernel));
check('handle 暴露 snapshot/rollback', /case 'snapshot'/.test(kernel) && /case 'rollback'/.test(kernel));
check('回退先卸载多余插件', /keep\.contains\(pid\)/.test(kernel));
check('装插件前自动快照已接线', /onBeforeMount:/.test(backend) && /snapshots\.create/.test(backend));

console.log('G6 WASM 类型化拒绝');
check('WasmUnavailable 存在', /class WasmUnavailable/.test(wasm));
check('load 抛类型化拒绝', /throw WasmUnavailable\(/.test(wasm));

console.log('G7 mosaic 约定加载');
check('面板契约存在', /class MosaicPanel/.test(read('frontend/lib/mosaic/panel.dart')));
check('注册表存在', /class MosaicRegistry/.test(read('frontend/lib/mosaic/registry.dart')));
check('生成器产出 2 个面板', /tga_models_panel\.mosaicPanel/.test(read('frontend/lib/mosaic/generated_registry.dart')));

console.log('通用：括号配平');
for (const f of [
  'frontend/lib/harness/plugin_kernel.dart',
  'frontend/lib/harness/kernel_guard.dart',
  'frontend/lib/harness/plugin_tier.dart',
  'frontend/lib/harness/wasm_module.dart',
  'frontend/lib/harness/creator_runtime.dart',
  'frontend/lib/mosaic/panel.dart',
  'frontend/lib/mosaic/registry.dart',
  'frontend/lib/mosaic/host.dart',
]) {
  const s = read(f);
  const c = (ch) => s.split(ch).length - 1;
  check(`${f} {} 配平`, c('{') === c('}'));
}

console.log(`\n${pass} passed / ${fail} failed`);
process.exit(fail ? 1 : 0);
