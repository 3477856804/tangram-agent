# build123d（vendored）

- 上游：https://github.com/gumyr/build123d
- 版本：0.11.1
- 许可证：Apache-2.0（见同目录 `LICENSE/`）
- 来源：PyPI wheel `build123d-0.11.1-py3-none-any.whl`（含完整 Python 源码）
- 接入：`backend/app/runtime/cad_model.py` 启动时把本目录加入 `sys.path`，
  优先导入仓库内源码。
- 运行依赖：`cadquery-ocp`（OCCT 原生库）仍需在目标环境安装；缺失时
  `available()` 如实返回 `ok:false`，不生成假模型。
- 说明：本目录只 vendor Python 源码，不包含 OCCT 二进制；移动端沙箱需用
  `pip install cadquery-ocp` 才能进行 B-rep 建模。
