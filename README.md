# DRishti — Diabetic Retinopathy Screening

An end-to-end diabetic retinopathy (DR) screening pipeline: a fundus photograph
goes in, and an ICDR grade (0–4), a referral decision, an annotated lesion
overlay, a Grad-CAM attention map and a patient-facing PDF report come out.

Built for screening settings where an ophthalmologist isn't down the hall — a
technician captures a fundus image, the tool says whether this person needs to
see a specialist, and how soon.

**Image analysis and grading run in MATLAB. A Flask app wraps them for the browser.**

> ⚠️ **Not a medical device.** This is a research and educational project. Its
> output is a screening signal, not a diagnosis, and it has not been clinically
> validated. Always consult a qualified eye care professional.

---

## What it actually does

```
fundus image
     |
     v
+-------------------------------------------------------------+
| 1. QUALITY GATE       assessImageQuality.m                  |
|    Hough-circle field of view - Laplacian-variance blur -   |
|    histogram exposure -> pass / enhanced (CLAHE) / reject   |
+-------------------------------------------------------------+
     |  (rejected images stop here - no grade is guessed)
     v
+-------------------------------------------------------------+
| 2. SEGMENTATION       segmentRetina.m                       |
|    Optic disc - fovea - vessels (matched filter) -          |
|    microaneurysms - exudates - haemorrhages - NV proxy      |
+-------------------------------------------------------------+
     |
     v
+--------------------------+   +------------------------------+
| 3a. RULE GRADING         |   | 3b. CNN GRADING              |
|  gradeByRules.m          |   |  trainDRClassifier.m         |
|  ICDR scale + 4-2-1 rule |   |  predictDRGrade.m            |
|  (fully inspectable)     |   |  calibrateConfidence.m       |
+--------------------------+   +------------------------------+
     |                                    |
     +-----------> combineGrades.m <------+
                   agree    -> grade
                   disagree -> flag for human review
     |
     v
+-------------------------------------------------------------+
| 4. EXPLANATION        gradCAMHeatmap - drawLesionOverlay -   |
|                       explainGrading - compileReportData     |
+-------------------------------------------------------------+
     |
     v
+-------------------------------------------------------------+
| 5. DELIVERY           Flask UI + PDF report                 |
+-------------------------------------------------------------+
```

### Two runtime modes, chosen automatically

| Mode | When | What you get |
|------|------|--------------|
| `real_full` | A trained `drClassifier.mat` loads successfully | CNN + rules combined, Grad-CAM, calibrated confidence, lesion overlay |
| `real_no_cnn` | Model missing, unreadable, or untrained | Rule-based ICDR grade + lesion overlay. No Grad-CAM, no confidence score |

The fallback is automatic. Nothing crashes and no flag needs flipping when the
model isn't there — the pipeline degrades to the rule-based path and says so in
`report.mode`.

---

## Design decisions worth calling out

**Segmentation is classical, not learned.** `segmentRetina.m` uses matched
filters, top-hat transforms and background subtraction rather than a trained
segmentation network. Every decision it makes is inspectable — the orientation,
the scale, the threshold — which matters more than raw accuracy when a clinician
asks *why* a pixel was called a haemorrhage. All thresholds are expressed as
fractions of the field-of-view radius, so the same settings transfer across
image sizes and cameras. An optional U-Net path (`dlSegmentVessels.m`) can be
dropped in for vessels; it never throws, and falls back to the classical result
if the model is missing.

**Confidence is calibrated, not raw softmax.** Neural networks are
systematically overconfident. `calibrateConfidence.m` fits Platt scaling on the
validation split so a reported "80%" means *this prediction is correct about 80%
of the time*, and it reports expected calibration error before and after.

**The referral threshold is tuned for sensitivity, not accuracy.** In screening,
a missed referable case costs far more than a false alarm.
`tuneReferableThreshold.m` picks the operating point with the best specificity
*among the cut-offs that hit 90% sensitivity*, rather than maximising overall
accuracy.

**CNN and rules must agree.** `combineGrades.m` returns `agree` only when both
paths give the same grade *and* the same referral decision. Otherwise it returns
`review` with `grade = NaN`, and marks the case referable if *either* method says
so — the safe default for screening.

**The LLM never grades.** Gemini writes the plain-language paragraphs in the PDF
report and nothing else. The grade is passed to it as a fixed input, and the
system prompt forbids re-deriving, questioning or contradicting it. If
`GEMINI_API_KEY` is absent or the call fails, a canned clinically-neutral
paragraph is used and the report still generates.

**Honest labelling of what's weak.** Neovascularization detection
(`segmentRetina.m`, section 6) is an experimental classical proxy that flags
vessel clusters that are both denser and more tortuous than the peripheral
baseline. It will also fire on dense normal arcades and poor crops. It is
documented as a soft flag, not a detector. Haemorrhage detection likewise
localises haemorrhages but does not sub-type them into dot / blot / flame.

---

## Repository layout

```
matlab/
  assessImageQuality.m         Module 1 - quality gate + CLAHE enhancement
  segmentRetina.m              Module 2 - all lesion/anatomy segmentation
  dlSegmentVessels.m           Module 2 - optional U-Net vessel path (never throws)
  gradeByRules.m               Module 3 - ICDR grading incl. the 4-2-1 rule
  trainDRClassifier.m          Module 3 - transfer-learning fine-tune
  predictDRGrade.m             Module 3 - inference
  calibrateConfidence.m        Module 3 - Platt scaling + reliability diagram
  tuneReferableThreshold.m     Module 3 - ROC / operating point selection
  combineGrades.m              Module 3 - CNN + rules consensus
  gradCAMHeatmap.m             Module 4 - Grad-CAM attention map
  drawLesionOverlay.m          Module 4 - colour-coded lesion overlay
  explainGrading.m             Module 4 - heatmap + overlay + calibrated confidence
  compileReportData.m          Module 4 - JSON + PNG export for the web layer
  sortIntoGradeFolders.m       Utility - build data/0..4 from a labels CSV
  runDRPipeline.m              Script  - end-to-end training/eval walkthrough
  runDRPipelineProduction.m    Module 5 - the script Flask actually calls
  demoExplainGrading.m         Script  - smoke test with synthetic data

app/python/
  app.py                       Flask server (/, /api/scan, /api/report/<id>)
  matlab_bridge.py             Singleton MATLAB Engine wrapper
  report_generator.py          Gemini prose + fpdf2 PDF layout
  templates/ static/           The scan UI

models/
  drClassifier.mat             Demo checkpoint (see "About the checkpoint")

docs/
  index.html                   Project page (GitHub Pages)
```

---

## Requirements

**MATLAB** R2021a or newer (Grad-CAM needs R2021a+; `trainnet` needs R2024a+), with:

- Image Processing Toolbox — *required*
- Deep Learning Toolbox — required for the CNN path
- Statistics and Machine Learning Toolbox — for `fitglm` / `perfcurve`
- Computer Vision Toolbox — optional; without it the labelled overlay silently
  drops its text annotations rather than failing

**Python** 3.9+ with `flask`, `fpdf2`, `google-generativeai`, `Pillow`, `numpy`,
plus the MATLAB Engine for Python.

---

## Setup

### 1. MATLAB Engine for Python (one time)

```bash
cd "C:\Program Files\MATLAB\R2026a\extern\engines\python"
python -m pip install .
```

Run this from the same environment Flask will use.

### 2. Python dependencies

```bash
cd app/python
python -m pip install -r requirements.txt
```

### 3. Environment variables

Copy `.env.example` and fill it in, or export directly:

```bash
set MATLAB_SRC_DIR=C:\path\to\drishti\matlab
set DR_MODEL_PATH=C:\path\to\drishti\models\drClassifier.mat
set GEMINI_API_KEY=your_key_here
```

Both `DR_MODEL_PATH` and `GEMINI_API_KEY` are optional — a missing model drops
you to `real_no_cnn` mode, and a missing key falls back to canned report prose.

### 4. Run

```bash
cd app/python
python app.py
```

Open <http://localhost:5000>, upload a fundus image, then download the PDF.

---

## Using the MATLAB pipeline directly

Grade a single image without the web layer:

```matlab
addpath('matlab');
report = runDRPipelineProduction("fundus.jpg", ...
    OutputDir = "out", ...
    ModelPath = "models/drClassifier.mat");

disp(report.mode)              % "real_full" or "real_no_cnn"
disp(report.decision.grade)    % 0-4
```

Inspect the segmentation on its own:

```matlab
r = segmentRetina('fundus.jpg');
figure, imshow(r.overlay)      % labelled overlay with leader lines
fprintf('%d microaneurysms\n', r.microaneurysms.count);
```

Run the smoke test — it works with no trained model and no fundus image, using an
untrained SqueezeNet head and a synthetic retina:

```matlab
demoExplainGrading
```

---

## Training your own classifier

Sort a labelled dataset into `data/0` … `data/4`:

```matlab
% APTOS 2019
sortIntoGradeFolders('train.csv', 'train_images', 'data', 'id_code', 'diagnosis')

% IDRiD
sortIntoGradeFolders('IDRiD_Disease Grading_Training Labels.csv', ...
    'Training Set', 'data', 'Image name', 'Retinopathy grade')

% Messidor-2
sortIntoGradeFolders('messidor_data.csv', 'IMAGES', 'data', ...
    'image_id', 'adjudicated_dr_grade')
```

They all merge into the same 0–4 folders. Then:

```matlab
model = trainDRClassifier('data', Backbone="efficientnetb0", MaxEpochs=10);
```

`trainDRClassifier.m` subsamples to `maxPerClass = 200` images per grade by
default to fit a ~6 GB GPU. **Raise that for a real training run** — it exists so
the pipeline can be exercised end to end on modest hardware.

Then tune the operating point and calibrate:

```matlab
pRefVal  = sum(model.valScores(:, model.grades >= 2), 2);
opPoint  = tuneReferableThreshold(pRefVal, model.valGrades >= 2, 0.90, 0.85);
model.referableThreshold = opPoint.threshold;

[rawVal, i] = max(model.valScores, [], 2);
model.calibration = calibrateConfidence(rawVal, model.grades(i)' == model.valGrades, Plot=true);

save('models/drClassifier.mat', '-struct', 'model');
```

`runDRPipelineProduction.m` reads `model.referableThreshold`, so setting it is
what moves the app off the placeholder `grade >= 2` cut-off.

## About the checkpoint in `models/`

`drClassifier.mat` is a **demo checkpoint**, not a validated model. It comes from
a short fine-tune — 3 epochs, 525 iterations, Adam at 1e-4, best-validation
checkpointing, on a 200-image-per-class subsample of APTOS 2019, about two and a
half minutes on a single GPU. It is there so the app boots into `real_full` mode
and the Grad-CAM and confidence paths are exercisable out of the box. It is not
accurate enough to screen anyone. Retrain on the full dataset for anything real.

The datasets themselves are not redistributed here. Get them from their sources:
[APTOS 2019](https://www.kaggle.com/c/aptos2019-blindness-detection),
[IDRiD](https://idrid.grand-challenge.org/),
[Messidor-2](https://www.adcis.net/en/third-party/messidor2/).

## Known limitations

- The neovascularization flag is a heuristic proxy and fires on dense normal arcades.
- Haemorrhages are localised but not sub-typed (dot / blot / flame).
- Venous beading and IRMA are accepted as inputs to `gradeByRules.m` but are not
  detected by `segmentRetina.m` — two of the three severe-NPDR triggers therefore
  depend on external input.
- Scan state is kept in memory in `app.py`; it does not survive a restart.
- The MATLAB Engine is a process-wide singleton with a call lock, so scans are
  serialised — fine for a kiosk, not for concurrent load.

## License

MIT — see [LICENSE](LICENSE).
