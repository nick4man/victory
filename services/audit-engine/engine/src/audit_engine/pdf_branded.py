#!/usr/bin/env python3
"""
Victory Branded PDF Generator v3.0
===================================
Generates branded PDF reports for «Виктори» real estate agency.

v3.0 changes:
- FIXED: ghost-headers on pages 2+ (was position:fixed, now CSS running())
- FIXED: QR code on EVERY page footer (was only end of body)
- FIXED: _generate_qr_base64 was missing → NameError
- Header with logo + contacts on every page via @page / running()
- Footer with QR + company name on every page via @page / running()
- End-of-report disclaimer is a separate HTML block (appears once)

Uses WeasyPrint + HTML/CSS template matching the official letterhead:
- Logo (SVG cube), company name, contacts
- Green/blue/grey colour scheme
- Dynamic QR-code (Telegram group) on every page
- Professional typography

Usage:
    python3 pdf_branded.py input.md [output.pdf]
    
Or as a library:
    from audit_engine.pdf_branded import md_to_branded_pdf
    md_to_branded_pdf("report.md", "report.pdf")
"""

from __future__ import annotations
import sys
import os
import base64
import io
import markdown
from pathlib import Path
from weasyprint import HTML
import qrcode


def _generate_qr_base64(data: str, box_size: int = 6, border: int = 1) -> str:
    """Generate a QR code and return as base64 data URI (PNG)."""
    qr = qrcode.QRCode(version=1, box_size=box_size, border=border)
    qr.add_data(data)
    qr.make(fit=True)
    img = qr.make_image(fill_color="#006837", back_color="white")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    b64 = base64.b64encode(buf.getvalue()).decode()
    return f"data:image/png;base64,{b64}"


def embed_chart_base64(fig) -> str:
    """Convert matplotlib figure to base64 PNG data URI."""
    import matplotlib.pyplot as plt
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=150, bbox_inches="tight",
                facecolor="white", edgecolor="none")
    plt.close(fig)
    buf.seek(0)
    b64 = base64.b64encode(buf.read()).decode()
    return f"data:image/png;base64,{b64}"


# ─── Brand Constants ───────────────────────────────────────────────
# Victory brand
COMPANY_NAME = "ВИКТОРИ"
COMPANY_SUBTITLE = "агентство недвижимости"
COMPANY_ADDRESS = "г. Рязань, ул. Горького 86, Н28, 1 этаж"
COMPANY_PHONE = "+7 926 978-05-08"
COMPANY_EMAIL = "oks07@yandex.ru"
TELEGRAM_GROUP_ID = "-1002137517834"
TELEGRAM_INVITE_LINK = "https://t.me/+placeholder"  # Replaced by QR gen

# Brand colours (from letterhead)
C_GREEN_DARK = "#006837"    # Main title, accents
C_GREEN_LIGHT = "#92C04E"   # Subtitle, logo face
C_BLUE_LIGHT = "#A7D9ED"    # Logo top face
C_GREY_LIGHT = "#E6E7E8"    # Logo left face
C_BG_GREY = "#F2F2F2"       # Decorative shape
C_BG_GREEN = "#E2EFDA"      # Decorative shape
C_TEXT_DARK = "#1a1a1a"     # Body text
C_TEXT_GREY = "#58595B"     # Secondary text

# SODIX brand
SODIX_NAME = "СОДИКС"
SODIX_SUBTITLE = "Аудит недвижимости"
SODIX_COLOR_PRIMARY = "#1a5276"
SODIX_COLOR_ACCENT = "#2ecc71"
SODIX_COLOR_BACKGROUND = "#f8f9fa"
SODIX_FOOTER_TEXT = "© СОДИКС | Конфиденциально"


def load_sodix_template() -> str:
    """Загрузить HTML-шаблон отчёта СОДИКС из файла."""
    template_path = Path(__file__).parent.parent / "templates" / "audit_report_v2.html"
    if not template_path.exists():
        # Fallback to default template (inline)
        return DEFAULT_SODIX_TEMPLATE
    return template_path.read_text(encoding="utf-8")


def sodix_html_to_pdf(html_content: str, pdf_path: str) -> str:
    """Сгенерировать PDF из HTML-контента с использованием стилей СОДИКС."""
    HTML(string=html_content).write_pdf(pdf_path)
    size_kb = os.path.getsize(pdf_path) / 1024
    print(f"✅ SODIX PDF создан: {pdf_path} ({size_kb:.0f} KB)")
    return pdf_path


# Встроенный шаблон по умолчанию (на случай отсутствия файла)
DEFAULT_SODIX_TEMPLATE = """<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="utf-8"/>
    <title>СОДИКС | Аудит недвижимости</title>
    <style>
        /* CSS для брендирования СОДИКС */
        @page {
            size: A4;
            margin: 30mm 20mm 25mm 20mm;
            @top-left { content: element(page-header); }
            @bottom-center { content: element(page-footer); }
            @bottom-right { content: "Страница " counter(page) " из " counter(pages);
                font-size: 9pt; color: #666; }
        }
        body {
            font-family: 'DejaVu Sans', Arial, sans-serif;
            font-size: 11pt;
            line-height: 1.6;
            color: #1a1a1a;
            background: #f8f9fa;
        }
        .running-header {
            position: running(page-header);
            width: 100%;
            padding-bottom: 5mm;
            border-bottom: 1px solid #2ecc71;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .header-left {
            font-size: 14pt;
            font-weight: 700;
            color: #1a5276;
        }
        .running-footer {
            position: running(page-footer);
            width: 100%;
            padding-top: 3mm;
            border-top: 1px solid #2ecc71;
            font-size: 9pt;
            color: #666;
            text-align: center;
        }
    </style>
</head>
<body>
    <div class="running-header">
        <div class="header-left">СОДИКС | Аудит недвижимости</div>
        <div class="header-right">{{ report_date }}</div>
    </div>
    <div class="running-footer">
        © СОДИКС | Конфиденциально
    </div>
    {{ content }}
</body>
</html>"""


def _maybe_upload_to_nextcloud(
    pdf_path: str,
    complex_name: str | None,
    audit_date: str | None,
    auto_upload: bool | None,
) -> None:
    """Upload PDF to Nextcloud if configured and parameters provided."""
    from audit_engine.config import settings
    should_upload = auto_upload if auto_upload is not None else settings.nextcloud_auto_upload
    if not should_upload or not complex_name:
        return
    try:
        from audit_engine.nextcloud_uploader import upload_file
        upload_file(pdf_path, complex_name, audit_date)
    except Exception as e:
        print(f"⚠️ Nextcloud upload failed (non-fatal): {e}")


def _get_logo_svg_b64() -> str:
    """Return SVG logo as base64 data URI."""
    svg = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 60 60" width="60" height="60">
  <polygon points="30,5 55,20 30,35 5,20" fill="#A7D9ED"/>
  <polygon points="5,20 30,35 30,58 5,43" fill="#E6E7E8"/>
  <polygon points="30,35 55,20 55,43 30,58" fill="#92C04E"/>
</svg>'''
    b64 = base64.b64encode(svg.encode()).decode()
    return f"data:image/svg+xml;base64,{b64}"


# ─── CSS Builder (dynamic — QR URI injected at runtime) ─────────────
def _build_css(qr_data_uri: str) -> str:
    """Build complete CSS with running header + QR footer on EVERY page.
    
    Uses CSS Paged Media 'running()' / 'element()' supported by WeasyPrint
    to place branded header and QR footer on every page.
    """
    return f"""
@page {{
    size: A4;
    margin: 40mm 20mm 28mm 20mm;

    @top-left {{
        content: element(page-header);
    }}

    @bottom-left {{
        content: element(page-footer);
    }}

    @bottom-center {{
        content: "Стр. " counter(page) " из " counter(pages);
        font-size: 8pt;
        color: {C_TEXT_GREY};
        font-family: 'DejaVu Sans', 'Noto Sans', Arial, sans-serif;
        vertical-align: bottom;
        padding-bottom: 2mm;
    }}
}}

body {{
    font-family: 'DejaVu Sans', 'Noto Sans', 'Liberation Sans', Arial, sans-serif;
    font-size: 10.5pt;
    line-height: 1.5;
    color: {C_TEXT_DARK};
    background: #fff;
}}

/* ─── Running Header (every page) ─── */
.running-header {{
    position: running(page-header);
    width: 170mm;
    padding: 0 0 3mm 0;
    border-bottom: 0.5pt solid {C_BG_GREY};
    display: flex;
    align-items: center;
    gap: 10px;
}}

.running-header .brand-logo {{
    width: 36px;
    height: 36px;
    flex-shrink: 0;
}}

.running-header .brand-text {{
    display: flex;
    flex-direction: column;
}}

.running-header .brand-subtitle {{
    font-size: 7pt;
    color: {C_GREEN_LIGHT};
    letter-spacing: 0.5px;
    margin: 0;
    line-height: 1.2;
}}

.running-header .brand-title {{
    font-size: 16pt;
    font-weight: 700;
    color: {C_GREEN_DARK};
    margin: 0;
    line-height: 1.1;
    letter-spacing: 1px;
}}

.running-header .brand-contacts {{
    font-size: 7pt;
    color: {C_TEXT_GREY};
    line-height: 1.3;
    margin-top: 1px;
}}

/* ─── Running Footer with QR (every page) ─── */
.running-footer {{
    position: running(page-footer);
    width: 170mm;
    padding-top: 2mm;
    border-top: 0.5pt solid {C_GREEN_LIGHT};
    display: flex;
    justify-content: space-between;
    align-items: center;
}}

.running-footer .footer-left {{
    font-size: 7pt;
    color: {C_TEXT_GREY};
    line-height: 1.4;
}}

.running-footer .footer-qr {{
    text-align: center;
}}

.running-footer .footer-qr img {{
    width: 48px;
    height: 48px;
}}

.running-footer .footer-qr .qr-label {{
    font-size: 6pt;
    color: {C_TEXT_GREY};
    margin-top: 1px;
}}

/* ─── Typography ─── */
h1 {{
    font-size: 18pt;
    color: {C_GREEN_DARK};
    margin-top: 20px;
    margin-bottom: 6px;
    padding-bottom: 4px;
    border-bottom: 2.5px solid {C_GREEN_LIGHT};
}}

h2 {{
    font-size: 14pt;
    color: {C_GREEN_DARK};
    margin-top: 18px;
    margin-bottom: 4px;
}}

h3 {{
    font-size: 11.5pt;
    color: {C_TEXT_DARK};
    margin-top: 14px;
    margin-bottom: 4px;
    font-weight: 600;
}}

/* ─── Tables ─── */
table {{
    width: 100%;
    border-collapse: collapse;
    margin: 10px 0;
    font-size: 9.5pt;
}}

th {{
    background: {C_GREEN_DARK};
    color: #fff;
    padding: 7px 9px;
    text-align: left;
    font-weight: 600;
    font-size: 9pt;
}}

td {{
    padding: 6px 9px;
    border-bottom: 1px solid #e0e0e0;
}}

tr:nth-child(even) td {{
    background: #f7faf4;
}}

/* ─── Verdict Boxes ─── */
.verdict-positive {{
    background: #edf7ed;
    border-left: 4px solid {C_GREEN_LIGHT};
    padding: 10px 14px;
    margin: 12px 0;
    border-radius: 3px;
}}

.verdict-negative {{
    background: #fdf0f0;
    border-left: 4px solid #dc3545;
    padding: 10px 14px;
    margin: 12px 0;
    border-radius: 3px;
}}

.verdict-neutral {{
    background: #fff8e6;
    border-left: 4px solid #f0ad4e;
    padding: 10px 14px;
    margin: 12px 0;
    border-radius: 3px;
}}

.highlight-box {{
    background: #f0f7f0;
    border: 1px solid {C_GREEN_LIGHT};
    padding: 10px 14px;
    margin: 12px 0;
    border-radius: 3px;
}}

/* ─── Block quotes ─── */
blockquote {{
    border-left: 3px solid {C_GREEN_LIGHT};
    margin: 12px 0;
    padding: 6px 14px;
    background: #f9fcf7;
    color: #333;
    font-size: 10pt;
}}

/* ─── Misc ─── */
strong {{ color: {C_GREEN_DARK}; }}
em {{ color: {C_TEXT_GREY}; }}
hr {{ border: none; border-top: 1px solid #ddd; margin: 16px 0; }}

code {{
    font-family: 'DejaVu Sans Mono', monospace;
    font-size: 9pt;
    background: #f4f4f4;
    padding: 1px 4px;
    border-radius: 3px;
}}

/* ─── End-of-report disclaimer ─── */
.report-disclaimer {{
    margin-top: 30px;
    padding-top: 10px;
    border-top: 1px solid {C_GREEN_LIGHT};
    font-size: 8.5pt;
    color: {C_TEXT_GREY};
    line-height: 1.6;
}}

/* ─── Chart containers ─── */
.chart-section {{
    margin: 16px 0;
    page-break-inside: avoid;
}}

.chart-section h4 {{
    margin-bottom: 8px;
}}

.chart-img {{
    display: block;
    margin: 8px auto;
    max-width: 100%;
    height: auto;
}}

.chart-row {{
    display: flex;
    justify-content: center;
    gap: 12px;
    flex-wrap: wrap;
    margin: 12px 0;
}}

.chart-row .chart-img {{
    max-width: 48%;
    flex: 0 1 48%;
}}

.chart-full {{
    text-align: center;
    margin: 16px 0;
    page-break-inside: avoid;
}}

.chart-full .chart-img {{
    max-width: 85%;
}}
"""


# ─── HTML Builders ──────────────────────────────────────────────────

def _build_running_header_html() -> str:
    """Build the running header HTML (appears on EVERY page via CSS running())."""
    logo_uri = _get_logo_svg_b64()
    return f'''
    <div class="running-header">
        <img class="brand-logo" src="{logo_uri}" alt="Logo"/>
        <div class="brand-text">
            <div class="brand-subtitle">{COMPANY_SUBTITLE}</div>
            <div class="brand-title">{COMPANY_NAME}</div>
            <div class="brand-contacts">
                {COMPANY_ADDRESS} · тел.: {COMPANY_PHONE} · {COMPANY_EMAIL}
            </div>
        </div>
    </div>
    '''


def _build_running_footer_html(qr_uri: str) -> str:
    """Build the running footer with QR (appears on EVERY page via CSS running())."""
    return f'''
    <div class="running-footer">
        <div class="footer-left">
            АН «Виктори» · {COMPANY_PHONE}
        </div>
        <div class="footer-qr">
            <img src="{qr_uri}" alt="QR"/>
            <div class="qr-label">Telegram</div>
        </div>
    </div>
    '''


def _build_disclaimer_html(report_date: str) -> str:
    """Build end-of-report disclaimer (appears once at the end of body content)."""
    return f'''
    <div class="report-disclaimer">
        <strong>Примечание:</strong> Расчёт носит информационный характер.
        Не является инвестиционной рекомендацией.<br/>
        <em>Отчёт сформирован агентством недвижимости «Виктори» · {report_date}</em>
    </div>
    '''


# ─── Main PDF Generator ────────────────────────────────────────────

def md_to_branded_pdf(
    md_path: str,
    pdf_path: str | None = None,
    report_date: str | None = None,
    charts_html: str | None = None,
    complex_name: str | None = None,
    audit_date: str | None = None,
    auto_upload: bool | None = None,
) -> str:
    """
    Convert Markdown report to branded Victory PDF.
    
    Args:
        md_path: Path to input Markdown file.
        pdf_path: Path for output PDF (default: same name .pdf).
        report_date: Date string for footer (default: extracted or today).
        charts_html: Optional pre-built HTML with chart images to inject before footer.
        complex_name: Название ЖК для автовыгрузки на Nextcloud.
        audit_date: Дата аудита (YYYY-MM-DD) для пути выгрузки.
        auto_upload: Выгружать ли на Nextcloud (None = использовать config).
    
    Returns:
        Path to generated PDF file.
    """
    if pdf_path is None:
        pdf_path = os.path.splitext(md_path)[0] + ".pdf"
    
    with open(md_path, "r", encoding="utf-8") as f:
        md_text = f.read()
    
    # Auto-detect date from content if not provided
    if report_date is None:
        import re
        date_match = re.search(r"(\d{1,2}\s+\w+\s+\d{4}\s*г?\.?)", md_text)
        if date_match:
            report_date = date_match.group(1)
        else:
            from datetime import date
            months_ru = {1:"января",2:"февраля",3:"марта",4:"апреля",
                        5:"мая",6:"июня",7:"июля",8:"августа",
                        9:"сентября",10:"октября",11:"ноября",12:"декабря"}
            d = date.today()
            report_date = f"{d.day} {months_ru[d.month]} {d.year} г."
    
    # Generate QR code for Telegram group
    tg_link = f"https://t.me/c/{TELEGRAM_GROUP_ID.replace('-100', '')}"
    qr_uri = _generate_qr_base64(tg_link)
    
    # Build CSS with QR embedded
    css = _build_css(qr_uri)
    
    # Pre-process: add markdown="1" to div blocks so md_in_html processes inner content
    import re as _re
    md_text = _re.sub(
        r'<div\s+(class="(?:verdict-positive|verdict-negative|verdict-neutral|highlight-box)[^"]*")\s*>',
        r'<div \1 markdown="1">',
        md_text,
    )
    # Also strip the ghost header-band div that hides content
    md_text = _re.sub(r'<div[^>]*class="header-band"[^>]*>.*?</div>', '', md_text, flags=_re.DOTALL)
    
    # Convert MD → HTML
    extensions = ["tables", "fenced_code", "attr_list", "md_in_html", "toc"]
    html_body = markdown.markdown(md_text, extensions=extensions)
    
    # Build running elements
    header = _build_running_header_html()
    footer_running = _build_running_footer_html(qr_uri)
    disclaimer = _build_disclaimer_html(report_date)
    
    # Inject charts HTML before disclaimer if provided
    charts_block = charts_html or ""
    
    # NOTE: Running elements MUST be placed in <body> before other content.
    # WeasyPrint removes them from flow and places them in @page margins.
    full_html = f"""<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="utf-8"/>
    <style>{css}</style>
</head>
<body>
{header}
{footer_running}
{html_body}
{charts_block}
{disclaimer}
</body>
</html>"""
    
    HTML(string=full_html).write_pdf(pdf_path)
    size_kb = os.path.getsize(pdf_path) / 1024
    print(f"✅ Branded PDF created: {pdf_path} ({size_kb:.0f} KB)")

    # Автовыгрузка на Nextcloud
    _maybe_upload_to_nextcloud(pdf_path, complex_name, audit_date, auto_upload)

    return pdf_path


def md_string_to_branded_pdf(
    md_text: str,
    pdf_path: str,
    report_date: str | None = None,
    charts_html: str | None = None,
    complex_name: str | None = None,
    audit_date: str | None = None,
    auto_upload: bool | None = None,
) -> str:
    """
    Convert Markdown string (not file) to branded Victory PDF.
    
    Args:
        md_text: Markdown content as string.
        pdf_path: Path for output PDF.
        report_date: Date string for footer.
        charts_html: Optional pre-built HTML with chart images to inject before footer.
        complex_name: Название ЖК для автовыгрузки на Nextcloud.
        audit_date: Дата аудита (YYYY-MM-DD) для пути выгрузки.
        auto_upload: Выгружать ли на Nextcloud (None = использовать config).
    
    Returns:
        Path to generated PDF file.
    """
    import tempfile
    with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False, encoding="utf-8") as tmp:
        tmp.write(md_text)
        tmp_path = tmp.name
    try:
        return md_to_branded_pdf(
            tmp_path, pdf_path, report_date,
            charts_html=charts_html,
            complex_name=complex_name,
            audit_date=audit_date,
            auto_upload=auto_upload,
        )
    finally:
        os.unlink(tmp_path)


# ─── CLI Entry Point ──────────────────────────────────────────────
if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 pdf_branded.py input.md [output.pdf]")
        print("       Generates Victory-branded PDF from Markdown.")
        sys.exit(1)
    
    in_file = sys.argv[1]
    out_file = sys.argv[2] if len(sys.argv) > 2 else None
    md_to_branded_pdf(in_file, out_file)
