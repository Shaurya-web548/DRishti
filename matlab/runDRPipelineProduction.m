function report = runDRPipelineProduction(imagePath, options)
%RUNDRPIPELINEPRODUCTION End-to-end DRishti pipeline for one fundus image.
%
%   report = runDRPipelineProduction(imagePath) runs the full pipeline on
%   one image: quality check -> segmentation -> grading -> (if a trained
%   CNN is available) GradCAM + confidence, and writes report.json plus
%   any generated PNGs into OutputDir. The Python/Flask layer reads
%   report.json rather than parsing the MATLAB struct directly.
%
%   report = runDRPipelineProduction(imagePath, Name=Value):
%       OutputDir  - folder for generated PNGs/JSON
%                    (default: fullfile(tempdir,'drishti_reports'))
%       ModelPath  - path to the trained classifier .mat file
%                    (default: 'drClassifier.mat')
%       ForceMode  - "real_full" | "real_no_cnn" | "" (auto, default).
%                    Forcing "real_full" without a trained model errors
%                    on purpose (mirrors compileReportData:noCnn).
%
%   MODE SELECTION - these are the ONLY two valid runtime modes:
%       real_full    CNN + rule-based grading, GradCAM, lesion overlay,
%                    confidence calibration. Chosen automatically when a
%                    trained model file loads successfully.
%       real_no_cnn  Rule-based grading only, no GradCAM. This is the
%                    automatic, safe fallback for every other case
%                    (missing file, load error, or an untrained model
%                    struct) - the pipeline never hard-fails because the
%                    CNN isn't ready.
%
%   report.mode tells the caller which path was taken.

arguments
    imagePath (1,1) string
    options.OutputDir (1,1) string = fullfile(string(tempdir), "drishti_reports")
    options.ModelPath (1,1) string = "drClassifier.mat"
    options.ForceMode (1,1) string = ""
end

if ~isfile(imagePath)
    error('runDRPipelineProduction:badImage', 'Image not found: %s', imagePath);
end
if ~isfolder(options.OutputDir)
    mkdir(options.OutputDir);
end

report = struct();
report.imagePath = char(imagePath);
report.timestamp = char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss'));

%% ---- Step 1: Image quality (Module 1) ---------------------------------
qc = assessImageQuality(imagePath);
% %%ASSUME assessImageQuality(path) -> struct with:
%   .status  'pass' | 'enhanced' | 'reject'
%   .image   enhanced in-memory image array (only when status=='enhanced')
%   .metrics blur/exposure/FOV diagnostics
report.quality = qc;

if isfield(qc, 'status') && strcmpi(qc.status, 'reject')
    report.mode = "rejected";
    report.error = 'Image quality too low for grading (blur/exposure/field-of-view failure).';
    jsonPath = fullfile(options.OutputDir, 'report.json');
    fid = fopen(jsonPath, 'w');
    fwrite(fid, jsonencode(report, PrettyPrint = true));
    fclose(fid);
    report.jsonPath = jsonPath;
    return
end

if isfield(qc, 'status') && strcmpi(qc.status, 'enhanced') && isfield(qc, 'image') && ~isempty(qc.image)
    workingImage = qc.image;   % use the CLAHE+denoise output for grading
else
    workingImage = imagePath;
end

%% ---- Step 2: Segmentation (Module 2) ----------------------------------
seg = segmentRetina(workingImage);
% seg preserves the existing struct shape (quadrant lesion counts,
% opticDisc.center, etc.) whether classical-only or hybrid DL.

%% ---- Step 3: Decide whether a trained CNN is available ----------------
cnnAvailable = false;
model = [];
if options.ForceMode ~= "real_no_cnn" && isfile(options.ModelPath)
    try
        loaded = load(options.ModelPath);
        fn = fieldnames(loaded);
        model = loaded.(fn{1});
        % A trained model must have real score/grade data - this mirrors
        % the check compileReportData.m uses to throw compileReportData:noCnn.
        if isfield(model, 'grades') && isfield(model, 'valScores') && ~isempty(model.valScores)
            cnnAvailable = true;
        end
    catch
        cnnAvailable = false;   % never hard-fail - fall back to rules only
    end
end

if options.ForceMode == "real_full" && ~cnnAvailable
    error('runDRPipelineProduction:noCnn', ...
        'ForceMode="real_full" requested but no trained model was found/loadable at %s.', options.ModelPath);
end

%% ---- Step 4: Grading ---------------------------------------------------
[ruleGrade, ruleInfo] = gradeByRules(seg, seg.opticDisc.center);
report.ruleGrade = ruleGrade;
report.ruleInfo  = ruleInfo;

if cnnAvailable
    report.mode = "real_full";

    [cnnGrade, probs] = predictDRGrade(model, workingImage);
    report.cnnGrade = cnnGrade;

    calProbs = calibrateConfidence(probs, model);
    % %%ASSUME calibrateConfidence(probs, model) -> calibrated probability
    % vector in the SAME ORDER as model.grades (not positional grade index).
    report.classProbabilities = calProbs;

    % %%ASSUME the tuned cut-off from tuneReferableThreshold.m is stored on
    % the model as .referableThreshold. If trainDRClassifier/your save
    % step uses a different field name, fix this line (do not hardcode
    % grade>=2 here - that's the placeholder this project explicitly
    % wants replaced by the tuned threshold).
    threshold = model.referableThreshold;

    decision = combineGrades(calProbs, ruleGrade, threshold, model.grades);
    if ~isfield(decision, 'referable')
        decision.referable = decision.grade >= 2;   % display-only fallback if combineGrades doesn't already set this
    end
    report.decision = decision;
    report.confidence = max(calProbs);

    heatmap = gradCAMHeatmap(model, workingImage, decision.grade);
    % %%ASSUME gradCAMHeatmap(model, image, grade) -> RGB heatmap array
    overlay = drawLesionOverlay(workingImage, seg);
    explanation = explainGrading(decision, ruleInfo, seg);
    % %%ASSUME explainGrading(decision, ruleInfo, seg) -> plain-language
    % struct/string produced by MATLAB (NOT the LLM) - this is separate
    % from the Gemini prose the Python layer generates for the PDF.

    heatmapPath = fullfile(options.OutputDir, 'gradcam.png');
    overlayPath = fullfile(options.OutputDir, 'lesion_overlay.png');
    imwrite(heatmap, heatmapPath);
    imwrite(overlay, overlayPath);

    report.heatmapPath = heatmapPath;
    report.overlayPath = overlayPath;
    report.explanation = explanation;

    % compileReportData hard-errors (compileReportData:noCnn) on an
    % untrained model - safe here because this branch only runs when
    % cnnAvailable is true.
    report.reportData = compileReportData(model, decision, seg, ...
        heatmap, overlay, explanation, options.OutputDir);
    % %%ASSUME compileReportData signature - confirm arg order against
    % your actual Module 4 file; adjust this call if it differs.

else
    report.mode = "real_no_cnn";
    report.decision = struct('grade', ruleGrade, 'referable', ruleGrade >= 2, 'source', 'rules');
    report.confidence = [];   % no calibrated confidence without a trained CNN

    overlay = drawLesionOverlay(workingImage, seg);
    overlayPath = fullfile(options.OutputDir, 'lesion_overlay.png');
    imwrite(overlay, overlayPath);
    report.overlayPath = overlayPath;
    report.heatmapPath = "";   % no GradCAM in real_no_cnn mode

    % No trained CNN -> compileReportData would hard-error, so the
    % report data is assembled here directly instead of calling it.
    report.reportData = struct( ...
        'mode', 'real_no_cnn', ...
        'grade', ruleGrade, ...
        'referable', ruleGrade >= 2, ...
        'ruleInfo', ruleInfo, ...
        'lesionCounts', seg.lesionCounts, ...
        'overlayPath', overlayPath);
    % %%ASSUME seg.lesionCounts is the quadrant lesion-count struct that
    % Module 3's rule path and CNN path both rely on.
end

%% ---- Step 5: Persist JSON for the Python/Flask layer -------------------
jsonPath = fullfile(options.OutputDir, 'report.json');
fid = fopen(jsonPath, 'w');
fwrite(fid, jsonencode(report, PrettyPrint = true));
fclose(fid);
report.jsonPath = jsonPath;

end
