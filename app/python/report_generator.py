"""
report_generator.py
Builds the patient-facing PDF report.

1. Sends the ALREADY-DECIDED grade + supporting facts to Gemini and asks
   it ONLY to write plain-language prose - it never re-grades, questions,
   or contradicts the MATLAB output. This is enforced in the prompt.
2. Lays that prose out into a structured, styled PDF with fpdf2: fundus
   image, GradCAM heatmap + lesion overlay (real_full) or just the
   lesion overlay (real_no_cnn), clinical detail, and a disclaimer.

If GEMINI_API_KEY is missing or the Gemini call fails for any reason,
the PDF still generates using a canned, clinically-neutral paragraph -
report generation must never depend on an external API being up.
"""

import os
from datetime import datetime

from fpdf import FPDF

try:
    import google.generativeai as genai

    _GEMINI_OK = bool(os.environ.get("GEMINI_API_KEY"))
    if _GEMINI_OK:
        genai.configure(api_key=os.environ["GEMINI_API_KEY"])
except Exception:
    _GEMINI_OK = False

GRADE_LABELS = {
    0: "No apparent retinopathy",
    1: "Mild non-proliferative DR",
    2: "Moderate non-proliferative DR",
    3: "Severe non-proliferative DR",
    4: "Proliferative DR",
}

BRAND_DARK = (26, 61, 46)      # deep green - matches the app's hero color
BRAND_ACCENT = (79, 140, 109)  # lighter green
BRAND_WARN = (176, 58, 46)     # referable / urgent flag color
TEXT_GREY = (95, 95, 95)


# --------------------------------------------------------------------------- #
# Gemini prose - strictly explanatory, no diagnostic authority
# --------------------------------------------------------------------------- #
def _gemini_prose(report: dict) -> str:
    grade = report["decision"]["grade"]
    label = GRADE_LABELS.get(grade, "Unknown")
    mode = report["mode"]

    system = (
        "You are a medical report writing assistant helping translate an "
        "already-finalized diabetic retinopathy screening result into "
        "plain language for a patient in rural India. The grade below was "
        "produced by a validated clinical algorithm and is FINAL - you "
        "must not question it, change it, re-derive it, suggest a "
        "different grade, or comment on the correctness of the grading "
        "itself. Your only job is to write 3 short paragraphs: what this "
        "grade generally means, why regular screening matters, and general "
        "next steps with a general timeframe appropriate to the grade. "
        "Do not invent patient-specific details you were not given. Keep "
        "it warm, clear, and non-alarming, around an 8th-grade reading level."
    )
    user = (
        f"DR grade: {grade} ({label}). "
        f"Referable (needs specialist follow-up): {report['decision'].get('referable', grade >= 2)}. "
        f"Grading mode: {'AI-assisted (CNN + clinical rules)' if mode == 'real_full' else 'rule-based only'}."
    )

    if not _GEMINI_OK:
        return _fallback_prose(grade, label)

    try:
        model = genai.GenerativeModel("gemini-2.5-flash", system_instruction=system)
        resp = model.generate_content(user)
        text = (resp.text or "").strip()
        return text if text else _fallback_prose(grade, label)
    except Exception:
        return _fallback_prose(grade, label)


def _fallback_prose(grade: int, label: str) -> str:
    if grade == 0:
        return (
            "Your screening did not find signs of diabetic retinopathy today. "
            "This is a good result, but diabetic eye disease can develop over "
            "time, so continue with your regular annual eye screenings.\n\n"
            "Keeping blood sugar, blood pressure, and cholesterol well managed "
            "is the best way to protect your eyes going forward.\n\n"
            "If you notice any sudden change in vision before your next "
            "scheduled screening, see an eye doctor sooner rather than later."
        )
    urgency = {
        1: "at your next routine visit",
        2: "within the next few months",
        3: "within a few weeks",
        4: "as soon as possible",
    }.get(grade, "soon")
    return (
        f"Your screening result is '{label}'. This means the screening tool "
        f"found changes in the blood vessels at the back of your eye that "
        f"are associated with diabetes.\n\n"
        f"This is a screening result, not a final diagnosis. We recommend "
        f"you see an ophthalmologist {urgency} for a full clinical "
        f"examination and, if needed, treatment.\n\n"
        f"Keeping blood sugar, blood pressure, and cholesterol under control "
        f"can slow or prevent further changes. Please don't skip the "
        f"specialist follow-up even if your vision feels normal - diabetic "
        f"retinopathy often has no symptoms until it is advanced."
    )


# --------------------------------------------------------------------------- #
# PDF layout
# --------------------------------------------------------------------------- #
class DRReportPDF(FPDF):
    def header(self):
        self.set_fill_color(*BRAND_DARK)
        self.rect(0, 0, self.w, 22, style="F")
        self.set_xy(10, 6)
        self.set_text_color(255, 255, 255)
        self.set_font("Helvetica", "B", 16)
        self.cell(0, 10, "DRishti - Diabetic Retinopathy Screening Report", new_x="LMARGIN", new_y="NEXT")
        self.set_y(24)
        self.set_text_color(0, 0, 0)

    def footer(self):
        self.set_y(-15)
        self.set_font("Helvetica", "I", 8)
        self.set_text_color(*TEXT_GREY)
        self.cell(
            0, 10,
            f"Page {self.page_no()}  |  Screening report, not a diagnosis  |  Generated {datetime.now():%d %b %Y}",
            align="C",
        )

    def section_title(self, text):
        self.ln(4)
        self.set_font("Helvetica", "B", 13)
        self.set_text_color(*BRAND_DARK)
        self.cell(0, 8, text, new_x="LMARGIN", new_y="NEXT")
        self.set_draw_color(*BRAND_ACCENT)
        self.set_line_width(0.6)
        self.line(10, self.get_y(), self.w - 10, self.get_y())
        self.ln(3)
        self.set_text_color(0, 0, 0)

    def body_text(self, text):
        self.set_font("Helvetica", "", 11)
        self.set_text_color(40, 40, 40)
        for para in text.split("\n\n"):
            self.multi_cell(0, 6, para.strip())
            self.ln(2)


def generate_pdf(report: dict, patient_info: dict, output_path: str) -> str:
    """
    report        - dict loaded from MATLAB's report.json
                     (see runDRPipelineProduction.m for the exact shape)
    patient_info  - {"name", "age", "scan_id", "location"} - missing keys
                     just show as "-"
    output_path   - where to write the .pdf
    """
    grade = report["decision"]["grade"]
    label = GRADE_LABELS.get(grade, "Unknown")
    referable = report["decision"].get("referable", grade >= 2)
    mode = report["mode"]

    pdf = DRReportPDF(format="A4")
    pdf.set_auto_page_break(auto=True, margin=18)
    pdf.add_page()

    # --- Scan info -----------------------------------------------------
    pdf.section_title("Scan Information")
    info_rows = [
        ("Patient", patient_info.get("name", "-")),
        ("Age", str(patient_info.get("age", "-"))),
        ("Scan ID", patient_info.get("scan_id", "-")),
        ("Location", patient_info.get("location", "-")),
        ("Date", datetime.now().strftime("%d %b %Y %H:%M")),
        ("Grading mode", "AI-assisted (CNN + rules)" if mode == "real_full" else "Rule-based"),
    ]
    for k, v in info_rows:
        pdf.set_font("Helvetica", "B", 10.5)
        pdf.cell(45, 6, f"{k}:")
        pdf.set_font("Helvetica", "", 10.5)
        pdf.cell(0, 6, str(v), new_x="LMARGIN", new_y="NEXT")

    # --- Headline result box --------------------------------------------
    pdf.ln(4)
    box_color = BRAND_WARN if referable else BRAND_ACCENT
    pdf.set_fill_color(*box_color)
    pdf.set_text_color(255, 255, 255)
    pdf.set_font("Helvetica", "B", 14)
    pdf.cell(0, 12, f"  Result: Grade {grade} - {label}", fill=True, new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Helvetica", "", 10.5)
    conf = report.get("confidence")
    conf_txt = (
        f"  AI confidence: {conf * 100:.0f}%"
        if isinstance(conf, (int, float))
        else "  Confidence score not available (rule-based mode)"
    )
    pdf.cell(0, 8, conf_txt, fill=True, new_x="LMARGIN", new_y="NEXT")
    pdf.set_text_color(0, 0, 0)
    pdf.ln(4)

    # --- Images -----------------------------------------------------------
    pdf.section_title("Retinal Images")
    img_y = pdf.get_y()
    img_w = 58
    x = 10
    captions = []
    for path, caption in [
        (report.get("imagePath"), "Original scan"),
        (report.get("overlayPath"), "Lesion overlay"),
        (report.get("heatmapPath"), "GradCAM (AI focus)"),
    ]:
        if path and os.path.isfile(path):
            pdf.image(path, x=x, y=img_y, w=img_w)
            captions.append((x, caption))
            x += img_w + 4
    pdf.set_y(img_y + img_w + 2)
    pdf.set_font("Helvetica", "I", 9)
    pdf.set_text_color(*TEXT_GREY)
    for cx, cap in captions:
        pdf.set_xy(cx, pdf.get_y())
        pdf.cell(img_w, 5, cap, align="C")
    pdf.ln(10)
    pdf.set_text_color(0, 0, 0)

    # --- Explanation (Gemini prose) ---------------------------------------
    pdf.section_title("What This Means")
    pdf.body_text(_gemini_prose(report))

    # --- Clinical detail (from MATLAB, not the LLM) ------------------------
    pdf.section_title("Clinical Detail (from screening algorithm)")
    rule_info = report.get("ruleInfo", {})
    pdf.set_font("Helvetica", "", 10.5)
    if isinstance(rule_info, dict) and rule_info:
        for k, v in rule_info.items():
            pdf.multi_cell(0, 5.5, f"- {k}: {v}")
    else:
        pdf.multi_cell(0, 5.5, "Detailed lesion counts are available in the accompanying data export.")

    # --- Disclaimer ---------------------------------------------------------
    pdf.ln(4)
    pdf.set_font("Helvetica", "I", 9)
    pdf.set_text_color(*TEXT_GREY)
    pdf.multi_cell(
        0, 5,
        "This report is generated by an automated screening tool (DRishti) and is "
        "intended to support, not replace, evaluation by a qualified eye care "
        "professional. Please consult an ophthalmologist for diagnosis and treatment.",
    )

    pdf.output(output_path)
    return output_path
