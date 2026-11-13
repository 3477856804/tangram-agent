"""tangram-agent —— agent = model + harness。

用户在这里训练出自己的模型。产品把「模型」与「脚手架」拆成两个一等公民：

  * **Model**：基底模型（本地下载的 GGUF/HF 权重，或远端 API 模型）充当教师；
    蒸馏产出的私人权重（adapter / 合并 GGUF / torch 权重）是学生，也是最终交付物。
  * **Harness**：把用户真实完成的「工作」采集为轨迹，交给教师生成监督信号，
    再驱动真实训练、合并、晋升、登记，产出高度契合本人的私人模型。

两条等价入口（见 harness.distiller.WorkDistiller）：
  1. from_local_base()  —— 本地下载基底模型 → 本地推理教师 → 工作蒸馏 → 私人 model
  2. from_api()         —— 调用 OpenAI 兼容 API → 远端教师 → 工作蒸馏 → 私人 model

装配完成后 TangramAgent = Model + Harness，可继续工作、对话、再蒸馏。
所有 I/O 与训练都是真实的：HTTP 下载 / HTTP 推理 / torch 梯度下降 / 文件落盘，
不伪造模型输出，也不把占位文件冒充训练产物。

版本策略：产品版本唯一真源是仓库根 VERSION，定版前恒为 0.0.1（见 version.py）。
"""

from __future__ import annotations

from .version import PRODUCT_NAME, PRODUCT_VERSION, assert_version_frozen

__all__ = [
    "PRODUCT_NAME",
    "PRODUCT_VERSION",
    "assert_version_frozen",
]
