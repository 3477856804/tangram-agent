"""知识入库解析真实管线回归：真实文件、真实切块、真实错误。"""

from __future__ import annotations

import stat
import sys
import zipfile
from pathlib import Path

import pytest

from backend.app.runtime.knowledge_ingest import (
    IngestError,
    chunk,
    extract,
    extract_and_chunk,
)


def _write_pdf(path: Path, text: str = "Hello PDF") -> None:
    """不依赖第三方生成器的最小 PDF（Helvetica + 单页文本）。"""
    content = f"BT /F1 24 Tf 72 720 Td ({text}) Tj ET".encode("latin-1")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n"
        + content
        + b"\nendstream",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for index, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += f"{index} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n".encode()
    out += b"0000000000 65535 f \n"
    for offset in offsets[1:]:
        out += f"{offset:010d} 00000 n \n".encode()
    out += (
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
        f"startxref\n{xref}\n%%EOF\n"
    ).encode()
    path.write_bytes(out)


def test_text_formats_and_encodings(tmp_path: Path) -> None:
    txt = tmp_path / "note.txt"
    txt.write_text("第一段\n第二段\n", encoding="utf-8")
    result = extract(txt)
    assert result["ok"] is True
    assert result["kind"] == "text"
    assert result["text"] == "第一段\n第二段"
    assert result["paragraphs"] == 2
    assert result["pages"] is None
    assert result["metadata"]["encoding"] == "utf-8"
    assert result["warnings"] == []

    md = tmp_path / "doc.md"
    md.write_text("# 标题\n\n中文内容 UTF-8", encoding="utf-8-sig")
    result = extract(md)
    assert result["kind"] == "text"
    assert "\ufeff" not in result["text"]
    assert result["text"].startswith("# 标题")
    assert result["metadata"]["encoding"] == "utf-8-sig"

    gbk = tmp_path / "gbk.txt"
    gbk.write_bytes("中文GBK编码".encode("gbk"))
    result = extract(gbk)
    assert result["text"] == "中文GBK编码"
    assert result["metadata"]["encoding"] in {"gbk", "gb18030"}

    payload = tmp_path / "data.json"
    payload.write_text('{"名称": "探针"}', encoding="utf-8")
    result = extract(payload)
    assert result["kind"] == "text"
    assert "探针" in result["text"]


def test_chunk_prefers_paragraphs_and_keeps_overlap() -> None:
    paragraphs = [f"第{i}段内容" + "字" * 34 for i in range(1, 11)]
    text = "\n".join(paragraphs)
    pieces = chunk(text, max_chars=100, overlap=45)
    assert len(pieces) >= 3
    assert all(0 < len(piece) <= 100 for piece in pieces)
    assert pieces[0].startswith("第1段")
    # 下一块以上一块最后一段开头（块间真重叠）
    first_lines = pieces[0].splitlines()
    assert pieces[1].startswith(first_lines[-1])

    long_single = "句子。" * 200
    hard = chunk(long_single, max_chars=60, overlap=10)
    assert len(hard) > 1
    assert all(len(piece) <= 60 for piece in hard)

    assert chunk("", max_chars=100) == []
    assert chunk("   \n\n  ", max_chars=100) == []

    with pytest.raises(ValueError):
        chunk("abc", max_chars=0)
    with pytest.raises(ValueError):
        chunk("abc", max_chars=10, overlap=10)


def test_extract_and_chunk_combines_pipeline(tmp_path: Path) -> None:
    path = tmp_path / "long.md"
    path.write_text(
        "\n".join(f"### 第{i}节\n这是第{i}节的中文内容。" + "说明" * 20 for i in range(1, 8)),
        encoding="utf-8",
    )
    result = extract_and_chunk(path, max_chars=120, overlap=20)
    assert result["kind"] == "text"
    assert result["chunk_count"] == len(result["chunks"])
    assert result["chunk_count"] > 1
    assert all(len(piece) <= 120 for piece in result["chunks"])
    assert "第1节" in result["chunks"][0]


def test_html_strips_markup_and_scripts(tmp_path: Path) -> None:
    page = tmp_path / "page.html"
    page.write_text(
        "<!doctype html><html><head><title>页面标题XYZ</title>"
        "<style>.hidden{color:red}</style>"
        "<script>console.log('secret-script')</script></head>"
        "<body><h1>正文标题</h1><p>正文 &amp; 内容</p>"
        "<ul><li>甲</li><li>乙</li></ul>"
        "<noscript>隐藏脚本文本</noscript></body></html>",
        encoding="utf-8",
    )
    result = extract(page)
    assert result["kind"] == "html"
    assert result["metadata"]["title"] == "页面标题XYZ"
    assert "secret-script" not in result["text"]
    assert "console.log" not in result["text"]
    assert "color:red" not in result["text"]
    assert "隐藏脚本文本" not in result["text"]
    assert "<h1>" not in result["text"]
    assert "正文标题" in result["text"]
    assert "正文 & 内容" in result["text"]
    assert "- 甲" in result["text"]
    assert "- 乙" in result["text"]


def test_zip_archive_merges_supported_members(tmp_path: Path) -> None:
    archive_path = tmp_path / "bundle.zip"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr("docs/a.txt", "第一条")
        archive.writestr("b.md", "# 第二条")
        archive.writestr("note.xyz", "未知格式")
    result = extract(archive_path)

    assert result["kind"] == "archive"
    assert "第一条" in result["text"]
    assert "# 第二条" in result["text"]
    assert "### docs/a.txt" in result["text"]
    assert result["metadata"]["entry_count"] == 3
    names = {item["name"] for item in result["files"]}
    assert names == {"docs/a.txt", "b.md", "note.xyz"}
    assert any(item["ok"] is False for item in result["files"] if item["name"] == "note.xyz")
    assert any("note.xyz" in warning for warning in result["warnings"])
    # 只在内存中遍历，不会把成员解压到磁盘
    assert {entry.name for entry in tmp_path.iterdir()} == {"bundle.zip"}


def test_missing_oversize_and_unsupported(tmp_path: Path) -> None:
    with pytest.raises(IngestError, match="不存在"):
        extract(tmp_path / "nope.txt")
    with pytest.raises(IngestError, match="不是普通文件"):
        extract(tmp_path)

    big = tmp_path / "big.txt"
    big.write_text("x" * 200, encoding="utf-8")
    with pytest.raises(IngestError, match="上限"):
        extract(big, max_bytes=50)

    binary = tmp_path / "sample.bin"
    binary.write_bytes(b"\x00\x01\x02")
    with pytest.raises(IngestError, match="不支持"):
        extract(binary)


def test_zip_rejects_traversal_symlink_and_limits(tmp_path: Path) -> None:
    traversal = tmp_path / "traversal.zip"
    with zipfile.ZipFile(traversal, "w") as archive:
        archive.writestr("../evil.txt", "越界内容")
    with pytest.raises(IngestError, match="越界"):
        extract(traversal)

    symlink = tmp_path / "symlink.zip"
    info = zipfile.ZipInfo("link.txt")
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    with zipfile.ZipFile(symlink, "w") as archive:
        archive.writestr(info, "/etc/passwd")
    with pytest.raises(IngestError, match="符号链接"):
        extract(symlink)

    many = tmp_path / "many.zip"
    with zipfile.ZipFile(many, "w") as archive:
        for index in range(3):
            archive.writestr(f"f{index}.txt", f"内容 {index}")
    with pytest.raises(IngestError, match="文件数"):
        extract(many, max_files=2)

    bomb = tmp_path / "bomb.zip"
    with zipfile.ZipFile(bomb, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("big.txt", "abc\n" * 2000)
    with pytest.raises(IngestError, match="上限"):
        extract(bomb, max_bytes=bomb.stat().st_size + 10)


def test_pdf_real_extraction_and_missing_dependency(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    pytest.importorskip("pypdf")
    pdf = tmp_path / "sample.pdf"
    _write_pdf(pdf, "Hello PDF 123")

    result = extract(pdf)
    assert result["kind"] == "pdf"
    assert result["pages"] == 1
    assert "Hello PDF" in result["text"]
    assert result["metadata"]["backend"] == "pypdf"

    monkeypatch.setitem(sys.modules, "pypdf", None)
    monkeypatch.setitem(sys.modules, "fitz", None)
    with pytest.raises(IngestError, match="pypdf"):
        extract(pdf)


def test_docx_real_extraction_and_missing_dependency(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    pytest.importorskip("docx")
    from docx import Document

    path = tmp_path / "sample.docx"
    document = Document()
    document.add_heading("标题DOCX", level=1)
    document.add_paragraph("正文段落")
    table = document.add_table(rows=1, cols=2)
    table.rows[0].cells[0].text = "单元格A"
    table.rows[0].cells[1].text = "单元格B"
    document.save(path)

    result = extract(path)
    assert result["kind"] == "docx"
    assert "标题DOCX" in result["text"]
    assert "正文段落" in result["text"]
    assert "单元格A | 单元格B" in result["text"]
    assert result["metadata"]["tables"] == 1
    assert result["metadata"]["paragraphs"] == 2

    monkeypatch.setitem(sys.modules, "docx", None)
    with pytest.raises(IngestError, match="python-docx"):
        extract(path)


def test_xlsx_real_extraction_and_missing_dependency(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    pytest.importorskip("openpyxl")
    from openpyxl import Workbook

    path = tmp_path / "sample.xlsx"
    workbook = Workbook()
    sheet = workbook.active
    sheet.title = "数据"
    sheet.append(["名称", "数量"])
    sheet.append(["苹果", 3])
    workbook.create_sheet("空白")
    workbook.save(path)

    result = extract(path)
    assert result["kind"] == "xlsx"
    assert result["pages"] == 2
    assert "=== Sheet: 数据 ===" in result["text"]
    assert "名称\t数量" in result["text"]
    assert "苹果\t3" in result["text"]
    assert result["metadata"]["sheets"][0]["rows"] == 2

    monkeypatch.setitem(sys.modules, "openpyxl", None)
    with pytest.raises(IngestError, match="openpyxl"):
        extract(path)


def _make_ocr_image(path: Path) -> None:
    from PIL import Image, ImageDraw, ImageFont

    image = Image.new("RGB", (640, 160), "white")
    try:
        font = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 60
        )
    except OSError:
        try:
            font = ImageFont.load_default(size=60)
        except TypeError:  # 旧版 Pillow 不支持 size 参数
            font = ImageFont.load_default()
    ImageDraw.Draw(image).text((30, 40), "HELLO OCR", font=font, fill="black")
    image.save(path)


def test_image_ocr_and_missing_dependency(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    pytest.importorskip("PIL")
    pytest.importorskip("pytesseract")

    path = tmp_path / "ocr.png"
    _make_ocr_image(path)

    result = extract(path)
    assert result["kind"] == "image"
    assert result["metadata"]["width"] == 640
    assert result["metadata"]["height"] == 160
    assert isinstance(result["text"], str)
    if result["text"]:
        assert "HELLO" in result["text"].upper()
    else:
        assert any("未识别" in warning for warning in result["warnings"])

    import pytesseract

    monkeypatch.setattr(
        pytesseract, "image_to_string", lambda image, lang=None: "识别出的文字"
    )
    wired = extract(path)
    assert wired["text"] == "识别出的文字"

    monkeypatch.setitem(sys.modules, "pytesseract", None)
    with pytest.raises(IngestError, match="OCR"):
        extract(path)
