"""
app.py - DRishti Flask backend.

Routes:
  GET  /                              the scan UI (templates/index.html)
  POST /api/scan                      upload an image, run the pipeline, return JSON
  GET  /api/report/<scan_id>          generate + download the PDF report
  GET  /results/<scan_id>/<filename>  serve generated images (overlay/gradcam/original)

Run:
    cd python
    python app.py
Then open http://localhost:5000
"""

import os
import uuid

from flask import Flask, jsonify, render_template, request, send_file, url_for

from matlab_bridge import get_bridge
from report_generator import generate_pdf

BASE_DIR = os.path.abspath(os.path.dirname(__file__))
RESULTS_DIR = os.path.join(BASE_DIR, "results")
ALLOWED_EXT = {"png", "jpg", "jpeg"}

os.makedirs(RESULTS_DIR, exist_ok=True)

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 20 * 1024 * 1024  # 20MB uploads

# In-memory scan store - fine for a hackathon demo / single-machine kiosk.
# Swap for a DB if this needs to survive restarts or run multi-worker.
SCANS = {}


def _allowed(filename):
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXT


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/scan", methods=["POST"])
def scan():
    if "image" not in request.files:
        return jsonify({"error": "No image uploaded."}), 400
    f = request.files["image"]
    if f.filename == "" or not _allowed(f.filename):
        return jsonify({"error": "Please upload a PNG or JPG fundus image."}), 400

    scan_id = uuid.uuid4().hex[:12]
    scan_dir = os.path.join(RESULTS_DIR, scan_id)
    os.makedirs(scan_dir, exist_ok=True)

    ext = f.filename.rsplit(".", 1)[1].lower()
    image_filename = f"original.{ext}"
    image_path = os.path.join(scan_dir, image_filename)
    f.save(image_path)

    try:
        bridge = get_bridge()
        report = bridge.run_pipeline(image_path, scan_dir)
    except Exception as exc:
        return jsonify({"error": f"Pipeline failed: {exc}"}), 500

    if report.get("mode") == "rejected":
        return jsonify({
            "scan_id": scan_id,
            "mode": "rejected",
            "message": report.get("error", "Image quality too low for grading."),
        }), 200

    SCANS[scan_id] = report

    grade = report["decision"]["grade"]
    response = {
        "scan_id": scan_id,
        "mode": report["mode"],
        "grade": grade,
        "grade_label": _grade_label(grade),
        "referable": report["decision"].get("referable", grade >= 2),
        "confidence": report.get("confidence"),
        "overlay_url": url_for("serve_result", scan_id=scan_id, filename="lesion_overlay.png") if report.get("overlayPath") else None,
        "gradcam_url": url_for("serve_result", scan_id=scan_id, filename="gradcam.png") if report.get("heatmapPath") else None,
        "original_url": url_for("serve_result", scan_id=scan_id, filename=image_filename),
    }
    return jsonify(response)


@app.route("/results/<scan_id>/<path:filename>")
def serve_result(scan_id, filename):
    return send_file(os.path.join(RESULTS_DIR, scan_id, filename))


@app.route("/api/report/<scan_id>")
def report(scan_id):
    if scan_id not in SCANS:
        return jsonify({"error": "Unknown scan_id."}), 404
    report_data = SCANS[scan_id]
    patient_info = {
        "name": request.args.get("name", "-"),
        "age": request.args.get("age", "-"),
        "scan_id": scan_id,
        "location": request.args.get("location", "-"),
    }
    pdf_path = os.path.join(RESULTS_DIR, scan_id, "report.pdf")
    generate_pdf(report_data, patient_info, pdf_path)
    return send_file(pdf_path, as_attachment=True, download_name=f"DRishti_report_{scan_id}.pdf")


def _grade_label(grade):
    return {
        0: "No apparent retinopathy",
        1: "Mild non-proliferative DR",
        2: "Moderate non-proliferative DR",
        3: "Severe non-proliferative DR",
        4: "Proliferative DR",
    }.get(grade, "Unknown")


if __name__ == "__main__":
    app.run(debug=True, port=5000)
