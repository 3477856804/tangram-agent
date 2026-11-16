"""知识入库真实解析管线：文件识别 → 文本提取 → 切块。

必需路径（文本 / HTML / ZIP）只用 Python 标准库；重依赖全部惰性导入，缺失时
抛出 [IngestError] 并说明安装方式，绝不返回空文本冒充成功。

支持格式：
  * 文本：txt / md / json / csv / yaml / yml / xml / log / srt / vtt
    （UTF-8 / UTF-8-SIG / GBK 自动回退）
  * HTML：html / htm / xhtml（真实去 script / style / 标签）
  * PDF：优先 pypdf，其次 PyMuPDF（逐页提取）
  * DOCX：python-docx（段落 + 表格）
  * XLSX / XLSM：openpyxl（逐 sheet 行转 TSV）
  * 图片：Pillow + pytesseract OCR（需要系统 tesseract 可执行文件）
  * 压缩包：zip（拒绝绝对路径 / ``..`` / 符号链接，递归解析受支持文件）

所有读取都受 ``max_bytes`` 约束；压缩包另外限制解压总大小、文件数与嵌套层数，
且只在内存中遍历，不落盘、不执行压缩包内任何文件。
"""

from __future__ import annotations

import io
import os
import re
import stat
import zipfile
from html.parser import HTMLParser
from pathlib import Path, PurePosixPath
from typing import Any

__all__ = [
    "DEFAULT_MAX_BYTES",
    "DEFAULT_MAX_ARCHIVE_FILES",
    "IngestError",
    "chunk",
    "extract",
    "extract_and_chunk",
]

DEFAULT_MAX_BYTES = 64 * 1024 * 1024
DEFAULT_MAX_ARCHIVE_FILES = 200
MAX_ARCHIVE_DEPTH = 2

_TEXT_SUFFIXES = frozenset(
    {".txt", ".md", ".json", ".csv", ".yaml", ".yml", ".xml", ".log", ".srt", ".vtt"}
)
_HTML_SUFFIXES = frozenset({".html", ".htm", ".xhtml"})
_IMAGE_SUFFIXES = frozenset(
    {".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tif", ".tiff"}
)
_ARCHIVE_SUFFIXES = frozenset({".zip"})

_SUPPORTED = (
    _TEXT_SUFFIXES
    | _HTML_SUFFIXES
    | _IMAGE_SUFFIXES
    | _ARCHIVE_SUFFIXES
    | {".pdf", ".docx", ".xlsx", ".xlsm"}
)


class IngestError(RuntimeError):
    """输入无效、超限、格式不支持或缺依赖（信息可直接展示给用户）。"""


def _kind_for(suffix: str) -> str:
    if suffix in _TEXT_SUFFIXES:
        return "text"
    if suffix in _HTML_SUFFIXES:
        return "html"
    if suffix in _IMAGE_SUFFIXES:
        return "image"
    if suffix in _ARCHIVE_SUFFIXES:
        return "archive"
    if suffix == ".pdf":
        return "pdf"
    if suffix == ".docx":
        return "docx"
    if suffix in {".xlsx", ".xlsm"}:
        return "xlsx"
    supported = ", ".join(sorted(_SUPPORTED))
    raise IngestError(f"不支持的文件类型 {suffix or '(无扩展名)'}；支持：{supported}")


def _count_paragraphs(text: str) -> int:
    return sum(1 for line in text.splitlines() if line.strip())


def _result(
    kind: str,
    text: str,
    *,
    pages: int | None = None,
    paragraphs: int | None = None,
    metadata: dict[str, Any] | None = None,
    warnings: list[str] | None = None,
    files: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    data: dict[str, Any] = {
        "ok": True,
        "kind": kind,
        "text": text,
        "pages": pages,
        "paragraphs": _count_paragraphs(text) if paragraphs is None else paragraphs,
        "metadata": metadata or {},
        "warnings": list(warnings or []),
    }
    if files is not None:
        data["files"] = files
    return data


def _normalize_newlines(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


def _decode(data: bytes) -> tuple[str, str]:
    """按 BOM / UTF-8 / GBK 顺序真实解码，返回 (文本, 命中编码)。"""
    encodings = ("utf-8-sig", "utf-8", "gbk", "gb18030") if data[:3] == b"\xef\xbb\xbf" else (
        "utf-8",
        "gbk",
        "gb18030",
    )
    for encoding in encodings:
        try:
            return data.decode(encoding), encoding
        except UnicodeDecodeError:
            continue
    raise IngestError("无法识别文本编码（已尝试 UTF-8 / GBK）")


class _HTMLTextExtractor(HTMLParser):
    """把 HTML 转成可读文本：丢弃脚本/样式/头部，块级标签转换行。"""

    _SKIP_TAGS = {"script", "style", "noscript", "template", "svg", "math"}
    _BLOCK_TAGS = {
        "p", "div", "section", "article", "header", "footer", "main", "aside",
        "nav", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table",
        "thead", "tbody", "tfoot", "tr", "td", "th", "pre", "blockquote",
        "figure", "figcaption", "dl", "dt", "dd", "form", "fieldset", "hr",
    }
    _VOID_TAGS = {"br", "hr", "img", "meta", "link", "input", "source"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._parts: list[str] = []
        self._title: list[str] = []
        self._skip = 0
        self._in_head = 0
        self._in_title = 0

    def _newline(self) -> None:
        if self._parts and not self._parts[-1].endswith("\n"):
            self._parts.append("\n")

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        tag = tag.lower()
        if tag in self._SKIP_TAGS:
            self._skip += 1
            return
        if self._skip:
            return
        if tag == "head":
            self._in_head += 1
            return
        if tag == "title":
            self._in_title += 1
            return
        if tag == "br":
            self._newline()
            return
        if tag in self._BLOCK_TAGS:
            self._newline()
        if tag == "li":
            self._parts.append("- ")

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        if tag.lower() not in self._VOID_TAGS:
            self.handle_endtag(tag)

    def handle_endtag(self, tag: str) -> None:
        tag = tag.lower()
        if tag in self._SKIP_TAGS:
            self._skip = max(0, self._skip - 1)
            return
        if self._skip:
            return
        if tag == "title":
            self._in_title = max(0, self._in_title - 1)
            self._newline()
            return
        if tag == "head":
            self._in_head = max(0, self._in_head - 1)
            self._newline()
            return
        if tag in self._BLOCK_TAGS:
            self._newline()

    def handle_data(self, data: str) -> None:
        if self._skip:
            return
        if self._in_title:
            self._title.append(data)
            return
        if self._in_head:
            return
        self._parts.append(data)

    def handle_comment(self, data: str) -> None:
        return

    @property
    def text(self) -> str:
        return "".join(self._parts)

    @property
    def title(self) -> str:
        return "".join(self._title)


def _clean_html_lines(raw: str) -> str:
    lines: list[str] = []
    for line in _normalize_newlines(raw).split("\n"):
        line = re.sub(r"[ \t\f\v\u00a0]+", " ", line).strip()
        if line:
            lines.append(line)
    return "\n".join(lines)


def _extract_text_bytes(data: bytes, meta: dict[str, Any]) -> dict[str, Any]:
    text, encoding = _decode(data)
    warnings: list[str] = []
    if not data:
        warnings.append("文件为空")
    return _result(
        "text",
        _normalize_newlines(text).strip(),
        metadata={**meta, "encoding": encoding},
        warnings=warnings,
    )


def _extract_html_bytes(data: bytes, meta: dict[str, Any]) -> dict[str, Any]:
    raw, encoding = _decode(data)
    parser = _HTMLTextExtractor()
    parser.feed(raw)
    parser.close()
    text = _clean_html_lines(parser.text)
    metadata = {**meta, "encoding": encoding}
    title = parser.title.strip()
    if title:
        metadata["title"] = title
    warnings: list[str] = []
    if not text:
        warnings.append("HTML 未提取到可见文本")
    return _result("html", text, metadata=metadata, warnings=warnings)


def _extract_pdf_bytes(data: bytes, meta: dict[str, Any]) -> dict[str, Any]:
    warnings: list[str] = []
    try:
        import pypdf
    except ImportError:
        pypdf = None  # type: ignore[assignment]

    if pypdf is not None:
        try:
            reader = pypdf.PdfReader(io.BytesIO(data))
            if reader.is_encrypted:
                reader.decrypt("")
            page_texts = []
            for page in reader.pages:
                try:
                    page_texts.append(page.extract_text() or "")
                except Exception as exc:  # 单页损坏不阻断其余页
                    page_texts.append("")
                    warnings.append(f"PDF 某页提取失败：{type(exc).__name__}: {exc}")
            page_count = len(reader.pages)
        except IngestError:
            raise
        except Exception as exc:
            raise IngestError(f"PDF 解析失败（pypdf）：{type(exc).__name__}: {exc}") from exc
        backend = "pypdf"
    else:
        try:
            import fitz  # PyMuPDF
        except ImportError as exc:
            raise IngestError(
                "PDF 解析需要 pypdf 或 PyMuPDF（pip install pypdf）"
            ) from exc
        try:
            document = fitz.open(stream=data, filetype="pdf")
            page_texts = [page.get_text("text") or "" for page in document]
            page_count = document.page_count
            document.close()
        except Exception as exc:
            raise IngestError(f"PDF 解析失败（PyMuPDF）：{type(exc).__name__}: {exc}") from exc
        backend = "pymupdf"

    text = "\n\n".join(part.strip() for part in page_texts if part.strip())
    if not text:
        raise IngestError(
            f"PDF 未提取到文本（共 {page_count} 页，可能是扫描件，需先 OCR）"
        )
    paragraphs = sum(_count_paragraphs(part) for part in page_texts)
    return _result(
        "pdf",
        text,
        pages=page_count,
        paragraphs=paragraphs,
        metadata={**meta, "pages": page_count, "backend": backend},
        warnings=warnings,
    )


def _extract_docx_bytes(data: bytes, meta: dict[str, Any]) -> dict[str, Any]:
    try:
        from docx import Document
    except ImportError as exc:
        raise IngestError(
            "DOCX 解析需要 python-docx（pip install python-docx）"
        ) from exc

    try:
        document = Document(io.BytesIO(data))
    except Exception as exc:
        raise IngestError(f"DOCX 解析失败：{type(exc).__name__}: {exc}") from exc

    parts: list[str] = []
    paragraph_count = 0
    for paragraph in document.paragraphs:
        paragraph_count += 1
        value = paragraph.text.strip()
        if value:
            parts.append(value)

    table_count = 0
    for table in document.tables:
        table_count += 1
        rows: list[str] = []
        for row in table.rows:
            cells = [cell.text.strip() for cell in row.cells]
            if any(cells):
                rows.append(" | ".join(cells))
        if rows:
            parts.append("\n".join(rows))

    text = "\n\n".join(parts)
    warnings: list[str] = []
    if not text:
        warnings.append("DOCX 未提取到文本")
    return _result(
        "docx",
        text,
        paragraphs=paragraph_count,
        metadata={**meta, "paragraphs": paragraph_count, "tables": table_count},
        warnings=warnings,
    )


def _format_cell(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value).replace("\t", " ").replace("\r", " ").replace("\n", " ")


def _extract_xlsx_bytes(data: bytes, meta: dict[str, Any]) -> dict[str, Any]:
    try:
        import openpyxl
    except ImportError as exc:
        raise IngestError(
            "XLSX 解析需要 openpyxl（pip install openpyxl）"
        ) from exc

    try:
        workbook = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    except Exception as exc:
        raise IngestError(f"XLSX 解析失败：{type(exc).__name__}: {exc}") from exc

    try:
        sections: list[str] = []
        sheet_meta: list[dict[str, Any]] = []
        row_total = 0
        for sheet in workbook.worksheets:
            lines: list[str] = []
            columns = 0
            for row in sheet.iter_rows(values_only=True):
                values = [_format_cell(value) for value in row]
                while values and values[-1] == "":
                    values.pop()
                if not values:
                    continue
                columns = max(columns, len(values))
                lines.append("\t".join(values))
            row_total += len(lines)
            sheet_meta.append(
                {"name": sheet.title, "rows": len(lines), "columns": columns}
            )
            if lines:
                sections.append(f"=== Sheet: {sheet.title} ===\n" + "\n".join(lines))
        sheet_count = len(workbook.worksheets)
    finally:
        workbook.close()

    text = "\n\n".join(sections)
    warnings: list[str] = []
    if not text:
        warnings.append("XLSX 未提取到单元格文本")
    return _result(
        "xlsx",
        text,
        pages=sheet_count,
        paragraphs=row_total,
        metadata={**meta, "sheets": sheet_meta},
        warnings=warnings,
    )


def _extract_image_bytes(data: bytes, meta: dict[str, Any]) -> dict[str, Any]:
    try:
        import pytesseract
        from PIL import Image
    except ImportError as exc:
        raise IngestError(
            "图片 OCR 需要 Pillow 与 pytesseract"
            "（pip install pillow pytesseract，并安装 tesseract 可执行文件）"
        ) from exc

    try:
        image = Image.open(io.BytesIO(data))
        image.load()
    except Exception as exc:
        raise IngestError(f"图片解码失败：{type(exc).__name__}: {exc}") from exc

    width, height = image.size
    mode = image.mode
    if mode not in {"RGB", "L"}:
        image = image.convert("RGB")

    lang = os.environ.get("TANGRAM_OCR_LANG", "chi_sim+eng")
    warnings: list[str] = []
    try:
        text = pytesseract.image_to_string(image, lang=lang)
    except Exception as exc:
        message = str(exc)
        if "tesseract is not installed" in message or "TesseractNotFound" in type(exc).__name__:
            raise IngestError(
                "未找到 tesseract 可执行文件，无法 OCR 图片"
                "（如 Alpine: apk add tesseract-ocr tesseract-ocr-data-chi_sim）"
            ) from exc
        language_missing = any(
            marker in message
            for marker in ("Failed loading language", "data file", "tessdata")
        )
        if lang != "eng" and language_missing:
            try:
                text = pytesseract.image_to_string(image, lang="eng")
            except Exception as retry_exc:
                raise IngestError(
                    f"OCR 失败：{type(retry_exc).__name__}: {retry_exc}"
                ) from retry_exc
            warnings.append(f"缺少 OCR 语言包 {lang}，已回退 eng")
            lang = "eng"
        else:
            raise IngestError(f"OCR 失败：{type(exc).__name__}: {message}") from exc

    text = (text or "").strip()
    if not text:
        warnings.append("OCR 未识别到文字")
    return _result(
        "image",
        text,
        metadata={
            **meta,
            "width": width,
            "height": height,
            "mode": mode,
            "ocr_lang": lang,
        },
        warnings=warnings,
    )


def _safe_member_name(name: str) -> str:
    """校验 zip 内路径：拒绝绝对路径、盘符、``..``、NUL。"""
    normalized = name.replace("\\", "/")
    if not normalized or "\x00" in normalized:
        raise IngestError(f"压缩包包含非法路径：{name!r}")
    if normalized.startswith("/") or re.match(r"^[A-Za-z]:", normalized):
        raise IngestError(f"压缩包包含绝对路径：{name}")
    parts = [part for part in normalized.split("/") if part not in {"", "."}]
    if not parts:
        raise IngestError(f"压缩包包含非法路径：{name!r}")
    if ".." in parts:
        raise IngestError(f"压缩包路径越界：{name}")
    return "/".join(parts)


def _is_symlink(info: zipfile.ZipInfo) -> bool:
    return stat.S_ISLNK(info.external_attr >> 16)


def _is_directory(info: zipfile.ZipInfo) -> bool:
    return info.is_dir() or info.filename.endswith("/")


def _spend_bytes(budget: dict[str, int], amount: int) -> None:
    if amount > budget["bytes"]:
        raise IngestError(
            f"压缩包解压总大小超过上限 {budget['limit']} 字节"
        )
    budget["bytes"] -= amount


def _extract_zip_bytes(
    data: bytes,
    meta: dict[str, Any],
    budget: dict[str, int],
    depth: int,
    prefix: str = "",
) -> dict[str, Any]:
    if depth > MAX_ARCHIVE_DEPTH:
        raise IngestError(f"压缩包嵌套超过 {MAX_ARCHIVE_DEPTH} 层")
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as exc:
        raise IngestError(f"不是有效的 ZIP 压缩包：{exc}") from exc

    warnings: list[str] = []
    manifest: list[dict[str, Any]] = []
    segments: list[str] = []
    consumed = 0
    entries = 0
    try:
        infos = archive.infolist()
        for info in infos:
            _safe_member_name(info.filename)
        files = [info for info in infos if not _is_directory(info)]
        for info in files:
            if budget["files"] <= 0:
                raise IngestError(f"压缩包文件数超过上限 {budget['max_files']}")
            budget["files"] -= 1
            name = _safe_member_name(info.filename)
            display = f"{prefix}{name}"
            entries += 1

            if _is_symlink(info):
                raise IngestError(f"压缩包包含符号链接：{display}")
            if info.flag_bits & 0x1:
                warnings.append(f"跳过加密文件：{display}")
                manifest.append(
                    {"name": display, "ok": False, "error": "加密文件"}
                )
                continue

            remaining = budget["bytes"]
            try:
                with archive.open(info) as handle:
                    raw = handle.read(remaining + 1)
            except Exception as exc:
                warnings.append(f"{display}: 读取失败 {type(exc).__name__}")
                manifest.append(
                    {"name": display, "ok": False, "error": f"读取失败：{exc}"}
                )
                continue
            if len(raw) > remaining:
                raise IngestError(
                    f"压缩包解压总大小超过上限 {budget['limit']} 字节"
                )
            _spend_bytes(budget, len(raw))
            consumed += len(raw)

            suffix = PurePosixPath(name).suffix.lower()
            kind: str
            try:
                kind = _kind_for(suffix)
            except IngestError as exc:
                warnings.append(f"{display}: {exc}")
                manifest.append(
                    {
                        "name": display,
                        "size": len(raw),
                        "ok": False,
                        "error": str(exc),
                    }
                )
                continue

            if kind == "archive":
                try:
                    nested = _extract_zip_bytes(
                        raw,
                        {"name": display, "size": len(raw)},
                        budget,
                        depth + 1,
                        prefix=f"{display}!",
                    )
                except IngestError as exc:
                    warnings.append(f"{display}: {exc}")
                    manifest.append(
                        {
                            "name": display,
                            "kind": "archive",
                            "size": len(raw),
                            "ok": False,
                            "error": str(exc),
                        }
                    )
                    continue
                manifest.extend(nested.get("files", []))
                segments.append(nested["text"])
                warnings.extend(nested["warnings"])
                continue

            try:
                result = _dispatch_bytes(
                    raw, suffix, {"name": display, "size": len(raw)}
                )
            except IngestError as exc:
                warnings.append(f"{display}: {exc}")
                manifest.append(
                    {
                        "name": display,
                        "kind": kind,
                        "size": len(raw),
                        "ok": False,
                        "error": str(exc),
                    }
                )
                continue

            result["metadata"]["name"] = display
            manifest.append(
                {
                    "name": display,
                    "kind": result["kind"],
                    "size": len(raw),
                    "ok": True,
                    "chars": len(result["text"]),
                }
            )
            segments.append(f"### {display}\n{result['text']}")
            warnings.extend(f"{display}: {warning}" for warning in result["warnings"])
    finally:
        archive.close()

    if not segments:
        reason = "；".join(warnings[:3]) or "没有受支持的文件"
        raise IngestError(f"压缩包内没有可解析的文件（{reason}）")

    text = "\n\n".join(segments)
    metadata = {
        **meta,
        "files": manifest,
        "entry_count": entries,
        "total_uncompressed_bytes": consumed,
    }
    return _result(
        "archive",
        text,
        metadata=metadata,
        warnings=warnings,
        files=manifest,
    )


def _dispatch_bytes(
    data: bytes, suffix: str, meta: dict[str, Any]
) -> dict[str, Any]:
    kind = _kind_for(suffix)
    if kind == "text":
        return _extract_text_bytes(data, meta)
    if kind == "html":
        return _extract_html_bytes(data, meta)
    if kind == "pdf":
        return _extract_pdf_bytes(data, meta)
    if kind == "docx":
        return _extract_docx_bytes(data, meta)
    if kind == "xlsx":
        return _extract_xlsx_bytes(data, meta)
    if kind == "image":
        return _extract_image_bytes(data, meta)
    raise IngestError("ZIP 压缩包必须通过 extract() 处理")  # pragma: no cover


def extract(
    path: str | Path,
    *,
    max_bytes: int = DEFAULT_MAX_BYTES,
    max_files: int = DEFAULT_MAX_ARCHIVE_FILES,
) -> dict[str, Any]:
    """识别并提取单个文件的真实文本；失败抛 [IngestError]。"""
    if max_bytes <= 0:
        raise ValueError("max_bytes 必须大于 0")
    if max_files <= 0:
        raise ValueError("max_files 必须大于 0")

    source = Path(path)
    try:
        if not source.exists():
            raise IngestError(f"文件不存在：{source}")
        if not source.is_file():
            raise IngestError(f"不是普通文件：{source}")
        size = source.stat().st_size
    except OSError as exc:
        raise IngestError(f"无法访问文件 {source}：{exc}") from exc

    if size > max_bytes:
        raise IngestError(f"文件大小 {size} 超过上限 {max_bytes} 字节")

    suffix = source.suffix.lower()
    kind = _kind_for(suffix)
    meta: dict[str, Any] = {
        "path": str(source.resolve()),
        "size": size,
        "suffix": suffix,
    }

    try:
        with source.open("rb") as handle:
            data = handle.read(max_bytes + 1)
    except OSError as exc:
        raise IngestError(f"读取失败 {source}：{exc}") from exc
    if len(data) > max_bytes:
        raise IngestError(f"文件大小超过上限 {max_bytes} 字节")

    if kind == "archive":
        budget = {
            "bytes": max_bytes,
            "files": max_files,
            "limit": max_bytes,
            "max_files": max_files,
        }
        return _extract_zip_bytes(data, meta, budget, depth=0)
    return _dispatch_bytes(data, suffix, meta)


def _split_long_unit(unit: str, max_chars: int) -> list[str]:
    """长段落先按句末标点切，再按字符硬切，保证每片不超限。"""
    sentences = re.split(r"(?<=[。！？；!?])", unit)
    pieces: list[str] = []
    current = ""
    for sentence in sentences:
        sentence = sentence.strip()
        if not sentence:
            continue
        while len(sentence) > max_chars:
            if current:
                pieces.append(current)
                current = ""
            pieces.append(sentence[:max_chars])
            sentence = sentence[max_chars:]
        if current and len(current) + len(sentence) > max_chars:
            pieces.append(current)
            current = sentence
        else:
            current += sentence
    if current:
        pieces.append(current)
    return pieces


def _tail_units(units: list[str], overlap: int) -> list[str]:
    if overlap <= 0 or not units:
        return []
    if len(units) == 1:
        unit = units[0]
        return [unit[-overlap:]] if len(unit) > overlap else []
    tail: list[str] = []
    total = 0
    for unit in reversed(units):
        addition = len(unit) + (1 if tail else 0)
        if total + addition > overlap:
            break
        tail.insert(0, unit)
        total += addition
    return tail


def chunk(text: str, max_chars: int = 600, overlap: int = 80) -> list[str]:
    """真实切块：段落优先、长段按句/字符切分，块间保留尾部重叠。"""
    if max_chars <= 0:
        raise ValueError("max_chars 必须大于 0")
    if overlap < 0 or overlap >= max_chars:
        raise ValueError("overlap 需满足 0 <= overlap < max_chars")
    if not text or not text.strip():
        return []

    units: list[str] = []
    for line in _normalize_newlines(text).split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        if len(stripped) <= max_chars:
            units.append(stripped)
        else:
            units.extend(_split_long_unit(stripped, max_chars))

    chunks: list[str] = []
    current: list[str] = []
    for unit in units:
        if current and len("\n".join(current + [unit])) > max_chars:
            chunks.append("\n".join(current))
            current = _tail_units(current, overlap)
            while current and len("\n".join(current + [unit])) > max_chars:
                current.pop(0)
        current.append(unit)
    if current:
        chunks.append("\n".join(current))
    return [piece for piece in chunks if piece.strip()]


def extract_and_chunk(
    path: str | Path,
    *,
    max_chars: int = 600,
    overlap: int = 80,
    max_bytes: int = DEFAULT_MAX_BYTES,
    max_files: int = DEFAULT_MAX_ARCHIVE_FILES,
) -> dict[str, Any]:
    """提取后立即切块，返回值在 extract() 基础上增加 chunks / chunk_count。"""
    result = extract(path, max_bytes=max_bytes, max_files=max_files)
    pieces = chunk(result["text"], max_chars=max_chars, overlap=overlap)
    result["chunks"] = pieces
    result["chunk_count"] = len(pieces)
    return result
