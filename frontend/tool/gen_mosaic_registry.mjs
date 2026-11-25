#!/usr/bin/env node
// 扫描 lib/mosaic/panels/**.dart 里的 `const MosaicPanel mosaicPanel = ...`，
// 生成 lib/mosaic/generated_registry.dart。约定优于配置：新增面板零改主入口。
// 用法：node tool/gen_mosaic_registry.mjs [--check]

import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const panelsDir = path.join(root, 'lib/mosaic/panels');
const outFile = path.join(root, 'lib/mosaic/generated_registry.dart');
const check = process.argv.includes('--check');

if (!fs.existsSync(panelsDir)) {
  console.error(`找不到面板目录: ${panelsDir}`);
  process.exit(2);
}

const files = fs.readdirSync(panelsDir)
  .filter((f) => f.endsWith('.dart'))
  .sort();

const entries = [];
for (const f of files) {
  const src = fs.readFileSync(path.join(panelsDir, f), 'utf8');
  if (!/const\s+MosaicPanel\s+mosaicPanel\s*=/.test(src)) {
    console.error(`[skip] ${f}：没有顶层常量 mosaicPanel`);
    continue;
  }
  const prefix = f.replace(/\.dart$/, '').replace(/[^A-Za-z0-9_]/g, '_');
  entries.push({ prefix, rel: `panels/${f}` });
}

const body = `// 自动生成，请勿手改。重新生成：node tool/gen_mosaic_registry.mjs
import 'panel.dart';
${entries.map((e) => `import '${e.rel}' as ${e.prefix};`).join('\n')}

/// 约定加载：每个面板文件导出顶层常量 \`mosaicPanel\`，此处集中登记。
List<MosaicPanel> tgaPanels() => <MosaicPanel>[
${entries.map((e) => `      ${e.prefix}.mosaicPanel,`).join('\n')}
    ];
`;

if (check) {
  const cur = fs.existsSync(outFile) ? fs.readFileSync(outFile, 'utf8') : '';
  if (cur !== body) {
    console.error('注册表过期：请运行 node tool/gen_mosaic_registry.mjs');
    process.exit(1);
  }
  console.log(`注册表已是最新（${entries.length} 个面板）`);
  process.exit(0);
}

fs.writeFileSync(outFile, body);
console.log(`已生成 lib/mosaic/generated_registry.dart：${entries.length} 个面板`);
