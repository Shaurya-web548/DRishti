# DRishti - Setup Steps (Windows)

## 0. What you're getting

```
DRishti_app/
  matlab/
    runDRPipelineProduction.m   <- the integration script that runs everything
  python/
    matlab_bridge.py            <- talks to MATLAB from Flask
    report_generator.py         <- Gemini prose + PDF report
    app.py                      <- Flask server
    templates/index.html        <- the scan UI
    static/style.css            <- styling (matches the eyehealth reference look)
    static/app.js                <- upload/result/download logic
    requirements.txt
```

## 1. Verify the `%%ASSUME` lines in runDRPipelineProduction.m

I don't have your actual Module 1/2/4 source in this session, so I wrote the
integration script the same way your team already tags uncertain signatures:
search the file for `%%ASSUME` (7 spots) and check each one against your real
`assessImageQuality.m`, `calibrateConfidence.m`, `gradCAMHeatmap.m`,
`explainGrading.m`, and `compileReportData.m`. The two most likely to need a
tweak:
- `threshold = model.referableThreshold;` - change this to whatever field
  name you actually save the `tuneReferableThreshold.m` output under.
- `report.reportData = compileReportData(model, decision, seg, heatmap, overlay, explanation, options.OutputDir);`
  - confirm the argument order matches your real function.

Everything else (mode selection, JSON export, fallback to `real_no_cnn`) does
not depend on those unknowns and should work as-is.

Copy `runDRPipelineProduction.m` next to your other Module 1-5 `.m` files so
MATLAB can see all of them on one path.

## 2. Install the MATLAB Engine for Python (one time)

Open a terminal (cmd or PowerShell), then:

```
cd "C:\Program Files\MATLAB\R2026a\extern\engines\python"
python -m pip install .
```

Make sure this is run from the same conda environment Flask will use.

## 3. Install Python dependencies

```
cd path\to\DRishti_app\python
python -m pip install -r requirements.txt
```

## 4. Set environment variables

In the same terminal, before starting Flask:

```
set MATLAB_SRC_DIR=C:\path\to\your\matlab\folder
set DR_MODEL_PATH=C:\path\to\drClassifier.mat
set GEMINI_API_KEY=your_key_here
```

Notes:
- `DR_MODEL_PATH` doesn't need to exist yet. If it's missing, every scan
  will just run in `real_no_cnn` mode automatically — the app still works,
  it just won't show GradCAM or a confidence percentage until the CNN is
  trained.
- `GEMINI_API_KEY` is optional too — if it's not set, PDF reports still
  generate, using a built-in fallback paragraph instead of Gemini prose.

## 5. Run it

```
python app.py
```

Open **http://localhost:5000** in a browser. Upload a fundus image, click
"Analyze Image", then "Download PDF Report".

## 6. What happens on each scan (matches your fixed two-mode constraint)

1. Flask saves the upload and calls `runDRPipelineProduction.m` through
   `matlab_bridge.py`.
2. MATLAB runs Module 1 (quality) → Module 2 (segmentation) → checks
   whether a trained CNN (`drClassifier.mat`) is loadable.
   - **Found and trained** → `real_full`: CNN + rules combined, GradCAM,
     lesion overlay, calibrated confidence.
   - **Missing / not trained / fails to load** → `real_no_cnn`: rule-based
     ICDR grading only, lesion overlay, no GradCAM, no confidence score.
     This is automatic — nothing crashes, nothing needs a flag flipped.
3. MATLAB writes `report.json` + PNGs to a per-scan results folder.
4. Flask reads that JSON and returns grade/mode/image URLs to the browser.
5. "Download PDF Report" calls `report_generator.py`, which asks Gemini
   for plain-language prose (grade is fixed input — Gemini cannot change
   it) and lays everything out into a styled PDF.

## 7. Once the CNN is trained

Nothing in the app needs to change. As soon as a valid `drClassifier.mat`
exists at `DR_MODEL_PATH`, the very next scan automatically switches to
`real_full` mode.
